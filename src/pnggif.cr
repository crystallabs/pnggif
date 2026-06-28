require "compress/zlib"
require "./encode"

# Pure-Crystal PNG / APNG / GIF reader.
#
# Decodes an image file (or in-memory buffer) into RGBA bitmaps and
# terminal-cell maps. Ported from Blessed's bundled `vendor/tng.js`
# (https://github.com/chjj/tng, MIT). Extracted from Crysterm into a standalone
# shard so it can be reused independently of the TUI toolkit.
#
# PNG decompression uses Crystal's stdlib `Compress::Zlib`; GIF uses a ported
# LZW decoder. JPEG and other formats are converted to PNG via ImageMagick's
# `convert` if it is available.
module PNGGIF
  VERSION = "0.1.0"

  # A single RGBA pixel. Channels are 0..255; `a` is opacity (255 = opaque).
  #
  # Channels are stored as `UInt8` (4 bytes/pixel instead of 4×`Int32` = 16) so
  # that megapixel `Bitmap`s and the cellmap downscale / animation composite
  # loops touch 4× less memory and stay cache-resident. The accessors keep the
  # public `Int32` (0..255) contract: `px.r # => Int32` and `Pixel.new` still
  # takes `Int32` args. Out-of-range values wrap (`to_u8!`); all internal
  # producers already emit 0..255.
  struct Pixel
    @r : UInt8
    @g : UInt8
    @b : UInt8
    @a : UInt8

    def initialize(r : Int32, g : Int32, b : Int32, a : Int32 = 255)
      @r = r.to_u8!
      @g = g.to_u8!
      @b = b.to_u8!
      @a = a.to_u8!
    end

    def r : Int32
      @r.to_i
    end

    def g : Int32
      @g.to_i
    end

    def b : Int32
      @b.to_i
    end

    def a : Int32
      @a.to_i
    end

    def r=(v : Int32)
      @r = v.to_u8!
    end

    def g=(v : Int32)
      @g = v.to_u8!
    end

    def b=(v : Int32)
      @b = v.to_u8!
    end

    def a=(v : Int32)
      @a = v.to_u8!
    end
  end

  # A bitmap: rows of pixels, `bmp[y][x]`.
  alias Bitmap = Array(Array(Pixel))

  # One animation frame (APNG `fcTL`/`fdAT` or a GIF image), already decoded to
  # a bitmap. `bmp` is the *sub-image* for the frame; `x_offset`/`y_offset`,
  # `dispose_op` and `blend_op` describe how it composites onto the canvas.
  class Frame
    property bmp : Bitmap
    property delay : Int32 # milliseconds
    property width : Int32
    property height : Int32
    property x_offset : Int32
    property y_offset : Int32
    property dispose_op : Int32
    property blend_op : Int32
    # Lazily-built cellmap for this frame (filled in by the widget/animator).
    property cellmap : Bitmap?

    def initialize(@bmp, @delay, @width, @height, @x_offset, @y_offset, @dispose_op, @blend_op)
    end
  end

  # Decodes a PNG / APNG / GIF (or, via ImageMagick, JPEG/other) image into:
  #
  # * `#bmp`     — the full-resolution RGBA bitmap of the first frame
  # * `#cellmap` — `bmp` downscaled to terminal-cell resolution
  # * `#frames`  — animation frames (APNG / animated GIF), or `nil` if static
  #
  # The cellmap is intended for solid-block terminal rendering (one cell per
  # sampled pixel, the cell's background = the pixel color). Because a character
  # cell is typically about twice as tall as it is wide, the missing cellmap
  # dimension is derived using `cell_aspect` (default `2.0`) so the image keeps
  # its visual proportions instead of looking vertically stretched. Output is
  # full 24-bit RGB; consumers pick their own color-reduction if needed.
  class PNG
    getter width : Int32 = 0
    getter height : Int32 = 0
    getter bit_depth : Int32 = 8
    getter color_type : Int32 = 6
    getter! bmp : Bitmap
    getter cellmap : Bitmap = Bitmap.new
    getter frames : Array(Frame)?
    getter num_plays : Int32 = 0
    # Full canvas dimensions (IHDR / GIF logical screen), which stay fixed even
    # while individual frames declare smaller sub-rectangles.
    getter canvas_width : Int32 = 0
    getter canvas_height : Int32 = 0

    @compression = 0
    @filter = 0
    @interlace = 0
    @palette = [] of Pixel
    # Color-key transparency from a `tRNS` chunk on a grayscale (type 0) or
    # truecolor (type 2) image: the (scaled, 8-bit) RGB whose pixels are
    # transparent. `nil` when absent; palette transparency (type 3) is folded
    # into `@palette` instead.
    @trns : Tuple(Int32, Int32, Int32)? = nil
    @sample_depth = 1
    @bits_per_pixel = 8
    @bytes_per_pixel = 1
    @byte_width = 0
    @idat = [] of Bytes
    @raw_frames = [] of NamedTuple(fctl: Hash(String, Int32), fdat: Array(Bytes), idat: Bool)
    @actl : Hash(String, Int32)? = nil

    # Rendering knobs forwarded from the consumer.
    property scale : Float64
    property cell_width : Int32?
    property cell_height : Int32?
    property? ascii : Bool
    property speed : Float64
    # Terminal cell height-to-width ratio, used to correct aspect when only one
    # of `cell_width`/`cell_height` is fixed (or when scaling). ~2.0 for typical
    # monospace cells. Set to `1.0` to disable the correction (square cells).
    property cell_aspect : Float64

    # Decodes *file* (a path) or a raw `Bytes` buffer. `cell_width`/`cell_height`
    # constrain the cellmap to a terminal box; `scale` is used when neither is
    # given. `cell_aspect` corrects for non-square cells (see `#cell_aspect`).
    # `ascii` renders glyphs by luminance; `speed` scales frame delays.
    def initialize(file : String | Bytes,
                   @scale : Float64 = 1.0,
                   @cell_width : Int32? = nil,
                   @cell_height : Int32? = nil,
                   @ascii : Bool = false,
                   @speed : Float64 = 1.0,
                   @cell_aspect : Float64 = 2.0)
      buf = file.is_a?(String) ? File.read(file).to_slice : file

      case detect_format(buf)
      when "png"
        decode_png(buf)
      when "gif"
        decode_gif(buf)
      else
        decode_png(to_png(buf))
      end
    end

    # Builds an animated `PNG` directly from already-decoded, full-canvas
    # *frames* (`{bitmap, delay_ms}`) — e.g. video frames produced by an
    # external decoder — bypassing all file parsing. Each frame is treated as a
    # full, independent canvas image (`blend_op = source`, no disposal), so
    # `#animation_cellmaps` and the usual playback path work unchanged.
    # *num_plays* is the loop count (`0` = loop forever).
    def self.from_frames(frames : Array(Tuple(Bitmap, Int32)),
                         canvas_width : Int32, canvas_height : Int32,
                         num_plays : Int32 = 0) : PNG
      new frames, canvas_width, canvas_height, num_plays
    end

    # :nodoc:
    # Frame-backed constructor used by `.from_frames`. The rendering knobs mirror
    # the file constructor's so a consumer can tune the cellmap sampling.
    def initialize(frames : Array(Tuple(Bitmap, Int32)),
                   canvas_width : Int32, canvas_height : Int32,
                   num_plays : Int32 = 0,
                   @scale : Float64 = 1.0,
                   @cell_width : Int32? = nil,
                   @cell_height : Int32? = nil,
                   @ascii : Bool = false,
                   @speed : Float64 = 1.0,
                   @cell_aspect : Float64 = 2.0)
      raise "PNGGIF::PNG.from_frames: empty frame list" if frames.empty?
      raise "PNGGIF::PNG.from_frames: non-positive canvas size" if canvas_width <= 0 || canvas_height <= 0
      @width = @canvas_width = canvas_width
      @height = @canvas_height = canvas_height
      @num_plays = num_plays
      fr = frames.map do |(bmp, delay)|
        Frame.new(bmp, delay, canvas_width, canvas_height, 0, 0, 0, 0)
      end
      @bmp = fr.first.bmp
      @frames = fr
      @cellmap = create_cellmap bmp
    end

    private def detect_format(buf : Bytes) : String
      return "png" if buf.size >= 4 && u32(buf, 0) == 0x89504e47
      return "gif" if buf.size >= 3 && buf[0] == 'G'.ord && buf[1] == 'I'.ord && buf[2] == 'F'.ord
      "other"
    end

    # ------------------------------------------------------------------ PNG

    private def decode_png(buf : Bytes)
      raise "bad png header" unless buf.size >= 8 && u32(buf, 0) == 0x89504e47 && u32(buf, 4) == 0x0d0a1a0a

      parse_chunks buf
      idat = inflate(@idat)
      raise "no image data" if idat.empty?

      # Parse the default image (IDAT) at the IHDR dimensions first; this is the
      # static representation used when animation is disabled.
      @bmp = decode_image idat
      @canvas_width = @width
      @canvas_height = @height

      # Building APNG frames mutates @width/@height per sub-frame; restore the
      # canvas dimensions afterwards so `#bmp`/`#canvas_*` describe the image.
      @frames = build_apng_frames
      @width = @canvas_width
      @height = @canvas_height

      @cellmap = create_cellmap bmp
    end

    private def parse_chunks(buf : Bytes)
      i = 8
      while i + 8 <= buf.size
        len = u32(buf, i)
        i += 4
        name = String.new(buf[i, 4])
        i += 4
        # Stop (don't crash) on a truncated/corrupt chunk whose length overruns
        # the buffer. Comparing as UInt32 also avoids `to_i` overflowing on a
        # length with the high bit set, which would otherwise raise before this
        # guard could fire.
        break if len > (buf.size - i).to_u32
        n = len.to_i
        data = buf[i, n]
        i += n
        i += 4 # skip CRC

        case name
        when "IHDR"
          # IHDR carries 13 fixed bytes (w/h/depth/colour/compression/filter/
          # interlace). The chunk-length guard above only proves `data` fits in
          # the buffer, not that it is long enough for these reads, so a corrupt
          # short IHDR would otherwise raise a raw IndexError. Stop cleanly
          # (downstream then raises "no image data") like the truncation break.
          break if data.size < 13
          # Width/height are 4-byte fields but valid PNG values are 1..2^31-1, so
          # a corrupt dimension with bit 31 set is out of spec. The length guard
          # above only proves the field is present, not sane: such a value makes
          # the very next `.to_i` (UInt32 -> Int32) raise a raw OverflowError mid-
          # parse. Reject it up front like the invalid-bit-depth guard below so a
          # malformed header fails as a clean decode error instead.
          w = u32(data, 0)
          h = u32(data, 4)
          raise "bad png: invalid dimensions #{w}x#{h}" if w > Int32::MAX.to_u32 || h > Int32::MAX.to_u32
          @width = w.to_i
          @height = h.to_i
          @bit_depth = data[8].to_i
          # Only {1,2,4,8,16} are valid PNG bit depths. The length guard above
          # proves the field is present, not that its value is sane: a corrupt
          # depth of 0 makes `compute_metrics` derive a zero `@byte_width` (empty
          # scanline buffer) and a zero `sample_to_8bit` divisor `(1<<0)-1`, so
          # decoding would raise a raw IndexError / DivisionByZeroError mid-row
          # instead of a clean decode error. Reject it up front like "bad png
          # header" does for a malformed signature.
          raise "bad png: invalid bit depth #{@bit_depth}" unless {1, 2, 4, 8, 16}.includes?(@bit_depth)
          @color_type = data[9].to_i
          @compression = data[10].to_i
          @filter = data[11].to_i
          @interlace = data[12].to_i
        when "PLTE"
          p = 0
          while p + 2 < data.size
            @palette << Pixel.new(data[p].to_i, data[p + 1].to_i, data[p + 2].to_i, 255)
            p += 3
          end
        when "tRNS"
          # IHDR (and PLTE) always precede tRNS, so `@color_type`/`@bit_depth`
          # and the palette are already set here.
          case @color_type
          when 3
            # Palette transparency: assign alpha to existing palette entries.
            data.each_with_index do |alpha, idx|
              break if idx >= @palette.size
              old = @palette[idx]
              @palette[idx] = Pixel.new(old.r, old.g, old.b, alpha.to_i)
            end
          when 0
            # Grayscale color key: a single 2-byte gray sample (bit-depth range).
            if data.size >= 2
              g = sample_to_8bit(u16(data, 0).to_i)
              @trns = {g, g, g}
            end
          when 2
            # Truecolor color key: three 2-byte R/G/B samples (bit-depth range).
            if data.size >= 6
              @trns = {sample_to_8bit(u16(data, 0).to_i),
                       sample_to_8bit(u16(data, 2).to_i),
                       sample_to_8bit(u16(data, 4).to_i)}
            end
          end
        when "IDAT"
          # `data` is a zero-copy view into `buf`, which stays alive for the whole
          # decode; `inflate` copies it out, so no defensive dup is needed.
          @idat << data
        when "acTL"
          # numFrames(4) + numPlays(4) = 8 fixed bytes; skip a corrupt short
          # acTL rather than letting the u32 reads run off the slice.
          next if data.size < 8
          @actl = {"numFrames" => u32(data, 0).to_i, "numPlays" => u32(data, 4).to_i}
          @num_plays = u32(data, 4).to_i
        when "fcTL"
          # parse_fctl reads through byte 25 (seq#(4) + w/h/x/y(16) + delay(4) +
          # dispose/blend(2) = 26 bytes); skip a corrupt short fcTL so those
          # fixed reads can't index past the slice.
          next if data.size < 26
          fctl = parse_fctl(data)
          if @idat.empty?
            # IDAT is itself the first frame: acTL->fcTL->IDAT
            @raw_frames << {fctl: fctl, fdat: @idat, idat: true}
          else
            @raw_frames << {fctl: fctl, fdat: [] of Bytes, idat: false}
          end
        when "fdAT"
          # First 4 bytes are a sequence number; the rest is zlib data. Skip
          # (don't crash on) a corrupt/misordered stream: an fdAT before any
          # fcTL would index an empty `@raw_frames`, and one shorter than its
          # 4-byte sequence number would slice with a negative count — both
          # mirror the chunk-length truncation guard above.
          if !@raw_frames.empty? && n >= 4
            @raw_frames[-1][:fdat] << data[4, n - 4]
          end
        when "IEND"
          break
        end
      end
    end

    private def parse_fctl(data : Bytes) : Hash(String, Int32)
      {
        "width"     => u32(data, 4).to_i,
        "height"    => u32(data, 8).to_i,
        "xOffset"   => u32(data, 12).to_i,
        "yOffset"   => u32(data, 16).to_i,
        "delayNum"  => u16(data, 20).to_i,
        "delayDen"  => u16(data, 22).to_i,
        "disposeOp" => data[24].to_i,
        "blendOp"   => data[25].to_i,
      }
    end

    private def build_apng_frames : Array(Frame)?
      return nil if @raw_frames.empty? || @actl.nil?

      frames = [] of Frame
      @raw_frames.each do |rf|
        fc = rf[:fctl]
        @width = fc["width"]
        @height = fc["height"]
        idat = inflate(rf[:fdat])
        next if idat.empty?
        bmp = decode_image idat
        den = fc["delayDen"] == 0 ? 100 : fc["delayDen"]
        # Integer math: the delay is delayNum/delayDen seconds in milliseconds.
        # The old `(delayNum / den * 1000).to_i` did float division then
        # truncated, so spec-correct values such as 1001/1000 s read back as
        # 1000 ms instead of 1001 (floor of 1000.999…). delayNum ≤ 65535, so
        # delayNum*1000 stays well within Int32.
        delay = (fc["delayNum"].to_i64 * 1000 // den).to_i32
        frames << Frame.new(bmp, delay, fc["width"], fc["height"],
          fc["xOffset"], fc["yOffset"], fc["disposeOp"], fc["blendOp"])
      end
      frames.empty? ? nil : frames
    end

    # --------------------------------------------------------------- scanlines

    # Reads one filtered scanline out of *data* at *pos* into the caller's
    # fixed-size `line` buffer and unfilters it in place against *prior*,
    # returning the position just past the consumed `1 + line.size` bytes.
    # `pos` must be a valid index (`< data.size`); the copy is clamped with
    # `Math.min` so a truncated final line can't read past the buffer, and any
    # short tail is zero-filled to match fresh-buffer semantics (a no-op for the
    # interlace path's already-zeroed line). Shared by the non-interlaced
    # `decode_image` loop and `sample_interlaced_lines`, whose per-row read +
    # unfilter step is otherwise byte-for-byte identical.
    private def read_scanline(data : Bytes, pos : Int32, line : Bytes, prior : Bytes) : Int32
      filter = data[pos].to_i
      pos += 1
      width = line.size
      n = Math.min(width, data.size - pos)
      data[pos, n].copy_to(line) if n > 0
      if n < width
        k = n < 0 ? 0 : n
        while k < width
          line[k] = 0u8
          k += 1
        end
      end
      pos += width
      unfilter_line filter, line, prior
      pos
    end

    private def compute_metrics
      @sample_depth = case @color_type
                      when 0 then 1
                      when 2 then 3
                      when 3 then 1
                      when 4 then 2
                      when 6 then 4
                      else        1
                      end
      @bits_per_pixel = @bit_depth * @sample_depth
      @bytes_per_pixel = (@bits_per_pixel / 8.0).ceil.to_i
      @byte_width = (@width * (@bits_per_pixel / 8.0)).ceil.to_i
    end

    # Decodes the IDAT/fdAT byte stream straight into a `Bitmap`. The
    # non-interlaced path is fully fused: each unfiltered scanline is converted
    # directly into a row of `Pixel`s, so the full-image `Array(Int32)` samples
    # buffer (16 MB for a megapixel RGBA image) and the separate
    # `parse_lines`+`create_bitmap` read pass are both gone. Adam7 interlacing
    # genuinely needs random-access reassembly, so it keeps the
    # `sample_interlaced_lines` → `create_bitmap` route.
    private def decode_image(data : Bytes) : Bitmap
      compute_metrics
      if @interlace == 1
        bmp = create_bitmap(sample_interlaced_lines(data))
        apply_color_trns bmp if @trns
        return bmp
      end

      rows = Bitmap.new(@height > 0 ? @height : 0)
      return rows if @width <= 0

      # Two reusable buffers swapped each scanline (this line / previous line)
      # instead of allocating a fresh Bytes per row.
      buf_a = Bytes.new(@byte_width, 0u8)
      buf_b = Bytes.new(@byte_width, 0u8)
      prior = buf_a
      line = buf_b
      p = 0
      while p < data.size
        # `read_scanline` copies the (clamped) line out of `data` and unfilters
        # it in place; a short final line has its stale tail cleared so the
        # reused buffer matches fresh-buffer semantics.
        p = read_scanline(data, p, line, prior)
        rows << build_pixel_row(line)
        prior, line = line, prior
      end
      apply_color_trns rows if @trns
      rows
    end

    # Applies grayscale/truecolor `tRNS` color-key transparency: every pixel
    # whose (8-bit) RGB equals the keyed color has its alpha cleared to 0. Runs
    # only when `@trns` is set (rare), so the per-pixel decode hot paths stay
    # untouched.
    private def apply_color_trns(bmp : Bitmap)
      t = @trns
      return unless t
      tr, tg, tb = t
      bmp.each do |row|
        x = 0
        while x < row.size
          px = row[x]
          row[x] = Pixel.new(px.r, px.g, px.b, 0) if px.r == tr && px.g == tg && px.b == tb
          x += 1
        end
      end
    end

    # Reads one raw (unscaled) sample at logical sample-index *idx* from a
    # decoded scanline, handling 8-bit, 16-bit (big-endian) and packed sub-byte
    # (1/2/4-bit, MSB-first) depths. Callers apply `#sample_to_8bit` for colour
    # channels; palette indices use the raw value directly.
    private def raw_sample(line : Bytes, idx : Int32) : Int32
      case @bit_depth
      when 8
        line[idx].to_i
      when 16
        (line[idx << 1].to_i << 8) | line[(idx << 1) + 1].to_i
      else
        b = @bit_depth
        pos = idx * b
        byte = line[pos >> 3].to_i
        (byte >> (8 - b - (pos & 7))) & ((1 << b) - 1)
      end
    end

    # Converts one unfiltered scanline into a row of `Pixel`s. Colour type and
    # bit depth are constant for the image, so the common 8-bit case gets a
    # tight branch reading bytes straight out of `line`; other depths fall back
    # to `raw_sample` + `sample_to_8bit`. Palette indices (type 3) are used raw.
    private def build_pixel_row(line : Bytes) : Array(Pixel)
      w = @width
      eight = @bit_depth == 8
      # `line` is exactly `@byte_width` bytes (the caller's reused scanline
      # buffer), so every 8-bit indexed read below stays in bounds and can skip
      # the per-byte bounds check via the raw pointer.
      src = line.to_unsafe

      case @color_type
      when 0 # grayscale
        if eight
          Array(Pixel).new(w) do |x|
            v = src[x].to_i
            Pixel.new(v, v, v, 255)
          end
        else
          Array(Pixel).new(w) do |x|
            v = sample_to_8bit(raw_sample(line, x))
            Pixel.new(v, v, v, 255)
          end
        end
      when 2 # RGB
        if eight
          Array(Pixel).new(w) do |x|
            o = x * 3
            Pixel.new(src[o].to_i, src[o + 1].to_i, src[o + 2].to_i, 255)
          end
        else
          Array(Pixel).new(w) do |x|
            b = x * 3
            Pixel.new(sample_to_8bit(raw_sample(line, b)), sample_to_8bit(raw_sample(line, b + 1)), sample_to_8bit(raw_sample(line, b + 2)), 255)
          end
        end
      when 3 # palette index (raw sample, never scaled)
        if eight
          Array(Pixel).new(w) { |x| @palette[src[x].to_i]? || Pixel.new(0, 0, 0, 0) }
        else
          Array(Pixel).new(w) { |x| @palette[raw_sample(line, x)]? || Pixel.new(0, 0, 0, 0) }
        end
      when 4 # grayscale + alpha
        if eight
          Array(Pixel).new(w) do |x|
            o = x * 2
            v = src[o].to_i
            Pixel.new(v, v, v, src[o + 1].to_i)
          end
        else
          Array(Pixel).new(w) do |x|
            b = x * 2
            v = sample_to_8bit(raw_sample(line, b))
            Pixel.new(v, v, v, sample_to_8bit(raw_sample(line, b + 1)))
          end
        end
      when 6 # RGBA
        if eight
          # `Pixel` is four consecutive `UInt8`s in r,g,b,a order, which is byte
          # for byte the layout of an 8-bit RGBA scanline. So copy the whole line
          # straight into the row's pixel buffer instead of constructing each
          # pixel channel-by-channel (one `memcpy` vs. 4·w byte loads + stores).
          Array(Pixel).build(w) do |pbuf|
            src.copy_to(pbuf.as(UInt8*), w * 4)
            w
          end
        else
          Array(Pixel).new(w) do |x|
            b = x * 4
            Pixel.new(sample_to_8bit(raw_sample(line, b)), sample_to_8bit(raw_sample(line, b + 1)), sample_to_8bit(raw_sample(line, b + 2)), sample_to_8bit(raw_sample(line, b + 3)))
          end
        end
      else
        # Unknown/invalid color type: preserve the old empty-row result.
        Array(Pixel).new(w)
      end
    end

    # Reverses a PNG scanline filter in place. The filter type is constant for
    # the whole line, so it is dispatched once here rather than per byte; each
    # branch reads only the neighbours it needs. `prior` is always the same size
    # as `line` (the caller allocates both at `@byte_width` / the interlace pass's
    # row size), so the previous per-byte `< prior.size` guards were dead and are
    # gone. Filter `a` (left) and `c` (upper-left) are zero for the first pixel.
    private def unfilter_line(filter : Int32, line : Bytes, prior : Bytes)
      return if filter == 0
      bpp = @bytes_per_pixel
      size = line.size
      case filter
      when 1 # Sub: predictor = a. First `bpp` bytes predict against 0 (unchanged).
        x = bpp
        while x < size
          line[x] = ((line[x].to_i + line[x - bpp].to_i) & 0xff).to_u8
          x += 1
        end
      when 2 # Up: predictor = b
        x = 0
        while x < size
          line[x] = ((line[x].to_i + prior[x].to_i) & 0xff).to_u8
          x += 1
        end
      when 3 # Average: predictor = (a + b) // 2
        x = 0
        while x < size
          a = x >= bpp ? line[x - bpp].to_i : 0
          line[x] = ((line[x].to_i + ((a + prior[x].to_i) // 2)) & 0xff).to_u8
          x += 1
        end
      when 4 # Paeth
        x = 0
        while x < size
          a = x >= bpp ? line[x - bpp].to_i : 0
          c = x >= bpp ? prior[x - bpp].to_i : 0
          line[x] = ((line[x].to_i + paeth(a, prior[x].to_i, c)) & 0xff).to_u8
          x += 1
        end
      end
    end

    private def paeth(a : Int32, b : Int32, c : Int32) : Int32
      p = a + b - c
      pa = (p - a).abs
      pb = (p - b).abs
      pc = (p - c).abs
      return a if pa <= pb && pa <= pc
      return b if pb <= pc
      c
    end

    # Unpacks one scanline into integer samples (one per channel), appending to
    # *out*. Values stay in their bit-depth's native range; `#sample_to_8bit`
    # scales them later.
    private def sample_line_into(dest : Array(Int32), line : Bytes, width : Int32)
      total = width * @sample_depth
      case @bit_depth
      when 16
        i = 0
        cnt = 0
        while cnt < total && i + 1 < line.size
          dest << ((line[i].to_i << 8) | line[i + 1].to_i)
          i += 2
          cnt += 1
        end
      when 8
        cnt = 0
        while cnt < total && cnt < line.size
          dest << line[cnt].to_i
          cnt += 1
        end
      else
        bits = @bit_depth
        mask = (1 << bits) - 1
        cnt = 0
        line.each do |byte|
          shift = 8 - bits
          while shift >= 0 && cnt < total
            dest << ((byte.to_i >> shift) & mask)
            shift -= bits
            cnt += 1
          end
          break if cnt >= total
        end
      end
    end

    # Scales a raw sample to 0..255 (no-op for palette indices, handled by caller).
    private def sample_to_8bit(v : Int32) : Int32
      case @bit_depth
      when 16 then v >> 8
      when  8 then v
      else
        mask = (1 << @bit_depth) - 1
        (v * 255) // mask
      end
    end

    # Color type is constant for the image, so it is dispatched once here rather
    # than per pixel. Each branch unpacks `@sample_depth` samples into one Pixel
    # and flushes a row every `w` pixels; a trailing partial row (if any) is
    # appended at the end, matching the original behaviour.
    private def create_bitmap(samples : Array(Int32)) : Bitmap
      rows = Bitmap.new
      w = @width
      return rows if w <= 0

      sd = @sample_depth
      n = samples.size
      row = Array(Pixel).new(w)
      i = 0
      case @color_type
      when 0 # grayscale
        while i < n
          v = sample_to_8bit samples[i]
          row << Pixel.new(v, v, v, 255)
          i += sd
          if row.size == w
            rows << row; row = Array(Pixel).new(w)
          end
        end
      when 2 # RGB
        while i < n
          row << Pixel.new(sample_to_8bit(samples[i]), sample_to_8bit(samples[i + 1]), sample_to_8bit(samples[i + 2]), 255)
          i += sd
          if row.size == w
            rows << row; row = Array(Pixel).new(w)
          end
        end
      when 3 # palette index
        while i < n
          row << (@palette[samples[i]]? || Pixel.new(0, 0, 0, 0))
          i += sd
          if row.size == w
            rows << row; row = Array(Pixel).new(w)
          end
        end
      when 4 # grayscale + alpha
        while i < n
          v = sample_to_8bit samples[i]
          row << Pixel.new(v, v, v, sample_to_8bit(samples[i + 1]))
          i += sd
          if row.size == w
            rows << row; row = Array(Pixel).new(w)
          end
        end
      when 6 # RGBA
        while i < n
          row << Pixel.new(sample_to_8bit(samples[i]), sample_to_8bit(samples[i + 1]), sample_to_8bit(samples[i + 2]), sample_to_8bit(samples[i + 3]))
          i += sd
          if row.size == w
            rows << row; row = Array(Pixel).new(w)
          end
        end
      end
      rows << row unless row.empty?
      rows
    end

    # Adam7 deinterlacing, ported from tng.js (originally from PyPNG, MIT).
    private def sample_interlaced_lines(raw : Bytes) : Array(Int32)
      adam7 = [{0, 0, 8, 8}, {4, 0, 8, 8}, {0, 4, 4, 8}, {2, 0, 4, 4}, {0, 2, 2, 4}, {1, 0, 2, 2}, {0, 1, 1, 2}]
      psize = (@bit_depth / 8.0) * @sample_depth
      # `vpr` (samples per row) and the flat `vpr * @height` sample buffer are
      # Int32 products. The IHDR guard only bounds @width/@height individually to
      # <= Int32::MAX, so for a large interlaced image their product (times the
      # 1..4 @sample_depth) can exceed Int32 and make these very multiplications
      # raise a raw OverflowError mid-decode. The non-interlaced path streams
      # row-by-row and never allocates this whole-image buffer, so it is immune;
      # reject the oversized interlaced case up front via an Int64 product like
      # the GIF dimension guard, so it fails as a clean decode error instead.
      raise "bad png: interlaced image too large" if @width.to_i64 * @sample_depth * @height > Int32::MAX
      vpr = @width * @sample_depth
      samples = Array(Int32).new(vpr * @height, 0)
      source = 0

      adam7.each do |(xstart, ystart, xstep, ystep)|
        next if xstart >= @width
        ppr = ((@width - xstart) / xstep).ceil.to_i
        next if ppr <= 0
        row_size = (psize * ppr).ceil.to_i
        recon = Bytes.new(row_size, 0u8)
        y = ystart
        while y < @height
          break if source >= raw.size
          line = Bytes.new(row_size, 0u8)
          source = read_scanline(raw, source, line, recon)
          recon = line
          flat = [] of Int32
          sample_line_into flat, line, ppr
          if xstep == 1
            offset = y * vpr
            (0...vpr).each { |f| samples[offset + f] = flat[f]? || 0 }
          else
            offset = y * vpr + xstart * @sample_depth
            endo = (y + 1) * vpr
            skip = @sample_depth * xstep
            (0...@sample_depth).each do |jj|
              k = offset + jj
              f = jj
              while k < endo
                samples[k] = flat[f]? || 0
                k += skip
                f += @sample_depth
              end
            end
          end
          y += ystep
        end
      end
      samples
    end

    # ---------------------------------------------------------------- cellmap

    # Downscales *bmp* to terminal-cell resolution by nearest-neighbour
    # sampling. Honours `cmwidth`/`cmheight` if given, else `scale` (all
    # defaulting to the values supplied at construction).
    #
    # When only one dimension is fixed (or neither), the other is derived from
    # the image's pixel aspect ratio and then corrected by `cell_aspect` so the
    # result isn't vertically stretched on non-square cells: terminal cells are
    # ~2× taller than wide, so a square image needs ~half as many rows as
    # columns. When both `cmwidth` and `cmheight` are given, they are used
    # verbatim (the caller takes responsibility for proportions).
    def create_cellmap(bmp : Bitmap, cmwidth : Int32? = @cell_width, cmheight : Int32? = @cell_height, scale : Float64 = @scale, cell_aspect : Float64 = @cell_aspect) : Bitmap
      return Bitmap.new if bmp.empty? || bmp[0].empty?
      height = bmp.size
      width = bmp[0].size

      if cmwidth && cmheight
        # Both fixed: honour them exactly.
      elsif cmwidth
        scale = cmwidth / width
        cmheight = (height * scale / cell_aspect).round.to_i
      elsif cmheight
        scale = cmheight / height
        cmwidth = (width * scale * cell_aspect).round.to_i
      else
        cmwidth = (width * scale).round.to_i
        cmheight = (height * scale / cell_aspect).round.to_i
      end
      return Bitmap.new if cmwidth <= 0 || cmheight <= 0

      ys = height / cmheight
      xs = width / cmwidth

      cellmap = Bitmap.new(cmheight)
      y = 0.0
      # Emit exactly cmheight × cmwidth cells. The sample positions still step by
      # `ys`/`xs`, but the index is clamped to the last valid row/column instead
      # of breaking: when upscaling (cm* larger than the source), the final step
      # rounds to `height`/`width`, which previously dropped the last row/column.
      cmheight.times do
        yy = y.round.to_i
        yy = height - 1 if yy >= height
        row = bmp[yy]? || break
        line = Array(Pixel).new(cmwidth)
        x = 0.0
        cmwidth.times do
          xx = x.round.to_i
          xx = width - 1 if xx >= width
          line << (row[xx]? || Pixel.new(0, 0, 0, 0))
          x += xs
        end
        cellmap << line
        y += ys
      end
      cellmap
    end

    # ---------------------------------------------------------------- animation

    # Composites every animation frame onto a full-size canvas (honouring APNG /
    # GIF dispose + blend semantics) and returns the per-frame `{cellmap, delay}`
    # ready for playback. Returns `nil` for a static image. Ported from tng.js's
    # `renderFrame` / `compileFrames`.
    def animation_cellmaps(cmwidth : Int32? = @cell_width, cmheight : Int32? = @cell_height, scale : Float64 = @scale) : Array(Tuple(Bitmap, Int32))?
      fr = @frames
      return nil if fr.nil? || fr.empty?

      canvas = Array.new(@canvas_height) { Array.new(@canvas_width) { Pixel.new(0, 0, 0, 0) } }
      result = [] of Tuple(Bitmap, Int32)
      prev : Frame? = nil
      prev_snapshot : Bitmap? = nil

      fr.each do |frame|
        # Apply the *previous* frame's disposal before drawing this one.
        if pf = prev
          case pf.dispose_op
          when 1 # background: clear the previous frame's rect to transparent
            each_rect(pf) { |x, y| canvas[y][x] = Pixel.new(0, 0, 0, 0) }
          when 2 # previous: restore the snapshot taken before that frame
            if snap = prev_snapshot
              each_rect(pf) { |x, y| canvas[y][x] = snap[y - pf.y_offset][x - pf.x_offset] }
            end
          end
        end

        # Snapshot this frame's region if it will need restoring afterwards.
        # Frames may extend past the canvas (common in real-world GIFs), so
        # clamp like the blit loop below; out-of-bounds cells store transparent
        # and are never read back (the restore via `each_rect` is also clamped).
        snapshot = nil
        if frame.dispose_op == 2
          snapshot = Bitmap.new
          frame.height.times do |sy|
            cy = frame.y_offset + sy
            crow = (cy >= 0 && cy < @canvas_height) ? canvas[cy] : nil
            row = Array(Pixel).new(frame.width)
            frame.width.times do |sx|
              cx = frame.x_offset + sx
              row << ((crow && cx >= 0 && cx < @canvas_width) ? crow[cx] : Pixel.new(0, 0, 0, 0))
            end
            snapshot << row
          end
        end

        # Blit the frame onto the canvas (blend_op 0 = source, 1 = over).
        blit_frame frame, canvas, blend: frame.blend_op != 0

        prev_snapshot = snapshot
        prev = frame
        result << {create_cellmap(canvas, cmwidth, cmheight, scale), frame.delay}
      end

      result
    end

    # Blits *frame*'s sub-image onto *canvas* at its offset, clamping to the
    # canvas bounds (frames may legitimately extend past it). With `blend: true`
    # (APNG/GIF "over") the source is composited onto the canvas so a partially
    # transparent pixel lets the canvas show through proportionally; with
    # `blend: false` ("source", and the GIF first-frame paste onto a transparent
    # canvas) every in-bounds pixel is written verbatim.
    private def blit_frame(frame : Frame, canvas : Bitmap, blend : Bool)
      frame.height.times do |sy|
        fy = frame.y_offset + sy
        next unless fy >= 0 && fy < @canvas_height
        frow = frame.bmp[sy]?
        next unless frow
        crow = canvas[fy]
        frame.width.times do |sx|
          fx = frame.x_offset + sx
          next unless fx >= 0 && fx < @canvas_width
          px = frow[sx]?
          next unless px
          if blend
            sa = px.a
            # Fully transparent: leave the canvas untouched (it shows through).
            next if sa == 0
            # Partially transparent APNG BLEND_OP_OVER source: alpha-composite
            # over the existing canvas pixel rather than replacing it. (GIF and
            # opaque/transparent APNG pixels have alpha 0 or 255 and skip this,
            # so their result is byte-identical to a verbatim copy.)
            px = composite_over(px, crow[fx]) if sa < 255
          end
          crow[fx] = px
        end
      end
    end

    # Porter-Duff "source over destination" for straight (non-premultiplied)
    # alpha, all channels in 0..255 with rounding. Only the partially
    # transparent APNG BLEND_OP_OVER case reaches here; fully opaque/transparent
    # pixels are short-circuited by the caller, so the GIF (binary-alpha) path is
    # unaffected. Previously such pixels were written verbatim, which *replaced*
    # the canvas (BLEND_OP_SOURCE) instead of compositing over it.
    private def composite_over(src : Pixel, dst : Pixel) : Pixel
      sa = src.a
      # Destination's surviving weight: da * (1 - sa), rounded.
      ia = (dst.a * (255 - sa) + 127) // 255
      oa = sa + ia
      return Pixel.new(0, 0, 0, 0) if oa <= 0
      half = oa // 2
      r = (src.r * sa + dst.r * ia + half) // oa
      g = (src.g * sa + dst.g * ia + half) // oa
      b = (src.b * sa + dst.b * ia + half) // oa
      Pixel.new(r, g, b, oa)
    end

    private def each_rect(frame : Frame, &)
      frame.height.times do |sy|
        y = frame.y_offset + sy
        next unless y >= 0 && y < @canvas_height
        frame.width.times do |sx|
          x = frame.x_offset + sx
          next unless x >= 0 && x < @canvas_width
          yield x, y
        end
      end
    end

    # ------------------------------------------------------------------ GIF

    private def decode_gif(buf : Bytes)
      gif = GIF.new buf
      @width = gif.width
      @height = gif.height
      @canvas_width = gif.width
      @canvas_height = gif.height

      frames = [] of Frame
      gif.images.each do |img|
        # Convert GIF disposal to PNG-style disposal.
        dispose = Math.max(0, (img.dispose_method) - 1)
        dispose = 0 if dispose > 2
        delay = img.delay * 10 # GIF delay is in 1/100s; store ms
        frames << Frame.new(img.bmp, delay, img.width, img.height, img.left, img.top, dispose, 1)
      end

      # The first GIF image may be smaller than (or offset within) the logical
      # screen, so blit it onto a full-canvas transparent bitmap rather than
      # exposing the bare sub-image. This keeps `#bmp` sized `width`×`height`
      # (== `canvas_width`×`canvas_height`), matching the PNG/IHDR path and the
      # dimensions consumers expect. The common full-screen first frame takes
      # the alias fast path with no extra allocation.
      first = frames[0]
      if first.x_offset == 0 && first.y_offset == 0 &&
         first.width == @canvas_width && first.height == @canvas_height
        @bmp = first.bmp
      else
        canvas = Array.new(@canvas_height) { Array.new(@canvas_width) { Pixel.new(0, 0, 0, 0) } }
        # Paste the sub-image onto the transparent canvas, writing every pixel
        # (including transparent ones, which keep their GIF RGB) verbatim.
        blit_frame first, canvas, blend: false
        @bmp = canvas
      end
      if frames.size > 1
        @actl = {"numFrames" => frames.size, "numPlays" => gif.num_plays}
        @num_plays = gif.num_plays
        @frames = frames
      end
      @cellmap = create_cellmap bmp
    end

    # ------------------------------------------------------- foreign formats

    # Converts a non-PNG/GIF buffer (JPEG, BMP, ...) to PNG via ImageMagick.
    private def to_png(input : Bytes) : Bytes
      stdout = IO::Memory.new
      status = Process.run("convert", ["-", "png:-"], input: IO::Memory.new(input), output: stdout, error: Process::Redirect::Close)
      raise "cannot decode image: ImageMagick `convert` failed or is not installed" unless status.success?
      stdout.to_slice
    rescue ex : File::NotFoundError | RuntimeError
      raise "cannot decode image: install ImageMagick (`convert`) for non-PNG/GIF formats"
    end

    # ------------------------------------------------------------- decompress

    private def inflate(buffers : Array(Bytes)) : Bytes
      return Bytes.empty if buffers.empty?
      # Single chunk (small PNGs, per-frame fdAT): `IO::Memory` wraps the slice
      # without copying, so skip allocating + filling the `combined` buffer.
      if buffers.size == 1
        io = IO::Memory.new(buffers[0])
        return Compress::Zlib::Reader.open(io, &.getb_to_end)
      end
      total = buffers.sum(&.size)
      combined = Bytes.new(total)
      off = 0
      buffers.each do |b|
        b.copy_to(combined + off)
        off += b.size
      end
      io = IO::Memory.new combined
      Compress::Zlib::Reader.open(io, &.getb_to_end)
    end

    # ------------------------------------------------------------- byte utils

    private def u32(b : Bytes, i : Int32) : UInt32
      (b[i].to_u32 << 24) | (b[i + 1].to_u32 << 16) | (b[i + 2].to_u32 << 8) | b[i + 3].to_u32
    end

    private def u16(b : Bytes, i : Int32) : UInt16
      ((b[i].to_u16 << 8) | b[i + 1].to_u16)
    end
  end

  # GIF (87a/89a) decoder ported from tng.js, which in turn adapted the LZW
  # reader from ka-cs-programs/gif-reader.js (MIT). Produces one `Image` per
  # frame with an RGBA bitmap.
  class GIF
    # A decoded GIF frame.
    class Image
      property left = 0
      property top = 0
      property width = 0
      property height = 0
      property? interlaced = false
      property delay = 0
      property dispose_method = 0
      property bmp : Bitmap = Bitmap.new

      def initialize
      end
    end

    getter width : Int32 = 0
    getter height : Int32 = 0
    getter num_plays : Int32 = 0
    getter images = [] of Image

    @colors = [] of Pixel
    @bg_index = 0
    # Current graphic-control extension state, applied to the next image.
    @gc_delay = 0
    @gc_dispose = 0
    @gc_transparent = -1

    def initialize(buf : Bytes)
      # The 6-byte signature + 7-byte logical screen descriptor must be present
      # before any of them is read; guard up front (like the PNG header check)
      # so a truncated buffer raises a clean error instead of an IndexError.
      raise "bad gif header: truncated" unless buf.size >= 13
      sig = String.new(buf[0, 6])
      raise "bad gif header: #{sig}" unless sig == "GIF87a" || sig == "GIF89a"

      @width = u16(buf, 6).to_i
      @height = u16(buf, 8).to_i
      flags = buf[10].to_i
      gct = (flags & 0x80) != 0
      gctsize = (flags & 0x07) + 1
      @bg_index = buf[11].to_i
      p = 13

      if gct
        total = 1 << gctsize
        # A truncated file may declare a global color table (up to 256×3 bytes)
        # that runs past the buffer. Guard it like the 13-byte header check
        # above so a short file raises a clean error instead of the IndexError
        # that the unbounded `buf[p]` reads below would otherwise produce.
        raise "bad gif header: truncated global color table" unless p + total * 3 <= buf.size
        p = read_color_table(buf, p, total, @colors)
      end

      p = parse_blocks(buf, p)
      raise "no image data or bad decompress" if @images.empty?
    end

    # Reads *total* RGB color-table entries (3 bytes each) starting at *p* into
    # *into* (opaque), returning the position just past the table. The caller is
    # responsible for the truncation guard, so the in-bounds reads here can't run
    # off the buffer. Shared by the global (constructor) and local (`parse_image`)
    # color-table parsers.
    private def read_color_table(buf : Bytes, p : Int32, total : Int32, into : Array(Pixel)) : Int32
      total.times do
        into << Pixel.new(buf[p].to_i, buf[p + 1].to_i, buf[p + 2].to_i, 255)
        p += 3
      end
      p
    end

    private def parse_blocks(buf : Bytes, p : Int32) : Int32
      while p < buf.size
        desc = buf[p]
        p += 1
        case desc
        when 0x2c # image descriptor
          p = parse_image(buf, p)
        when 0x21 # extension
          p = parse_extension(buf, p)
        when 0x3b # trailer
          break
        else
          break
        end
      end
      p
    end

    private def parse_extension(buf : Bytes, p : Int32) : Int32
      # The extension label and each fixed-size header below are read
      # unconditionally; guard them like the image-descriptor / color-table
      # checks elsewhere so a file truncated inside an extension raises a clean
      # decode error instead of a raw IndexError. (`skip_subblocks` /
      # `gather_subblocks` already self-guard their variable-length tails.)
      raise "bad gif: truncated extension" unless p < buf.size
      label = buf[p]
      p += 1
      if label == 0xf9 # graphic control
        # block-size(1) + fields(1) + delay(2) + transparent-index(1) = 5 bytes.
        raise "bad gif: truncated graphic-control extension" unless p + 5 <= buf.size
        p += 1         # block size (always 4)
        fields = buf[p].to_i
        @gc_dispose = (fields >> 2) & 0x07
        use_transparent = (fields & 0x01) != 0
        p += 1
        @gc_delay = u16(buf, p).to_i
        p += 2
        tc = buf[p].to_i
        p += 1
        @gc_transparent = use_transparent ? tc : -1
        p = skip_subblocks(buf, p)
      elsif label == 0xff # application extension (NETSCAPE loop count)
        # block-size(1) + 8-byte id + 3-byte auth code = 12 bytes.
        raise "bad gif: truncated application extension" unless p + 12 <= buf.size
        p += 1            # block size (always 11)
        id = String.new(buf[p, 8])
        auth = String.new(buf[p + 8, 3])
        p += 11
        data, p = gather_subblocks(buf, p)
        # NETSCAPE2.0 / ANIMEXTS1.0 sub-block 1 carries the loop count.
        netscape = (id == "NETSCAPE" && auth == "2.0") || (id == "ANIMEXTS" && auth == "1.0")
        if netscape && data.size >= 3 && data[0] == 0x01
          @num_plays = data[1].to_i | (data[2].to_i << 8)
        end
      else
        p = skip_subblocks(buf, p)
      end
      p
    end

    private def skip_subblocks(buf : Bytes, p : Int32) : Int32
      while p < buf.size && buf[p] != 0x00
        size = buf[p].to_i
        p += 1
        p += size
      end
      p + 1
    end

    # Concatenates a chain of GIF sub-blocks (each a length byte followed by that
    # many data bytes, terminated by a zero length) into a single `Bytes`.
    # Returns the gathered data and the position just past the terminator. Two
    # passes avoid the per-sub-block `Array(UInt8)#concat` growth and the
    # `to_unsafe` round-trip the previous inline loops used.
    private def gather_subblocks(buf : Bytes, p : Int32) : Tuple(Bytes, Int32)
      total = 0
      q = p
      while q < buf.size && buf[q] != 0x00
        size = buf[q].to_i
        # A truncated trailing sub-block may claim more bytes than remain; count
        # (and below, copy) only what is actually present so `buf[...]` can't run
        # off the end, mirroring the PNG parser's truncation guard.
        total += Math.min(size, buf.size - q - 1)
        q += 1 + size
      end
      data = Bytes.new(total)
      off = 0
      while p < buf.size && buf[p] != 0x00
        size = buf[p].to_i
        p += 1
        n = Math.min(size, buf.size - p)
        if n > 0
          buf[p, n].copy_to(data + off)
          off += n
        end
        p += size
      end
      {data, p + 1}
    end

    private def parse_image(buf : Bytes, p : Int32) : Int32
      img = Image.new
      # The 9-byte image descriptor (offsets, size, flags) is read
      # unconditionally below; guard it like the global/local color-table checks
      # so a file truncated at/after the `0x2c` separator raises a clean decode
      # error instead of a raw IndexError from the `u16`/`buf[p]` reads.
      raise "bad gif image: truncated image descriptor" unless p + 9 <= buf.size
      img.left = u16(buf, p).to_i; p += 2
      img.top = u16(buf, p).to_i; p += 2
      img.width = u16(buf, p).to_i; p += 2
      img.height = u16(buf, p).to_i; p += 2
      # width/height are each u16 (0..65535), so their product (the pixel count
      # used below as `lzw_decompress`'s `expected` capacity and the interlaced
      # sample-buffer size) can reach 65535² ≈ 4.29e9 and overflow Int32 for any
      # frame with width*height > Int32::MAX (~46341²). Crystal's default
      # overflow checking then makes `img.width * img.height` raise a raw
      # OverflowError mid-decode. Reject it up front via an Int64 product like
      # the IHDR-dimension guard on the PNG side, so an oversized frame fails as
      # a clean decode error instead.
      raise "bad gif image: dimensions #{img.width}x#{img.height} too large" if img.width.to_i64 * img.height.to_i64 > Int32::MAX
      flags = buf[p].to_i; p += 1
      lct = (flags & 0x80) != 0
      img.interlaced = (flags & 0x40) != 0
      lctsize = (flags & 0x07) + 1

      table = @colors
      if lct
        table = [] of Pixel
        total = 1 << lctsize
        # A truncated file may declare a local color table (up to 256×3 bytes)
        # that runs past the buffer, mirroring the global color table guard in
        # the constructor; without this the `buf[p]` reads below raise a raw
        # IndexError instead of a clean decode error.
        raise "bad gif image: truncated local color table" unless p + total * 3 <= buf.size
        p = read_color_table(buf, p, total, table)
      end

      # The LZW minimum-code-size byte follows the (optional) local color table;
      # guard it too, since a file truncated exactly here would otherwise read
      # one byte past the end.
      raise "bad gif image: truncated image data" unless p < buf.size
      code_size = buf[p].to_i; p += 1
      # The GIF LZW minimum code size is 2..8 (the color-table bit depth). A
      # corrupt value drives `lzw_decompress`'s `cc = 1 << code_size`: e.g. ~30
      # makes `cc` a billion and `cc.times { table << ... }` allocates until the
      # process is OOM-killed, while >=31 wraps `cc` negative and corrupts the
      # decode. Reject it up front like the other GIF header guards instead of
      # letting one corrupt byte trigger unbounded allocation.
      raise "bad gif image: invalid LZW minimum code size #{code_size}" unless 2 <= code_size <= 8
      lzw, p = gather_subblocks(buf, p)

      img.delay = @gc_delay
      img.dispose_method = @gc_dispose
      indices = lzw_decompress(lzw, code_size, img.width * img.height)
      build_gif_bitmap img, indices, table, @gc_transparent
      @images << img

      # Reset transient graphic-control state after consuming it.
      @gc_delay = 0
      @gc_dispose = 0
      @gc_transparent = -1
      p
    end

    # Maps one GIF color index to its `Pixel`: looks the index up in the active
    # (global or local) palette, falling back to transparent for an out-of-range
    # index, and clears alpha to 0 when the index is the graphic-control
    # transparent color. Shared by the interlaced and non-interlaced bitmap
    # builders so the lookup + color-key rule stays in one place.
    private def gif_color(table : Array(Pixel), b : Int32, transparent : Int32) : Pixel
      color = table[b]? || Pixel.new(0, 0, 0, 0)
      return Pixel.new(color.r, color.g, color.b, 0) if transparent >= 0 && b == transparent
      color
    end

    private def build_gif_bitmap(img, indices, table, transparent)
      w = img.width
      h = img.height

      unless img.interlaced?
        # Non-interlaced indices arrive in row-major order, so write straight
        # into the bitmap rows — no intermediate flat buffer or second pass.
        bmp = Bitmap.new(h)
        n = indices.size
        k = 0
        h.times do
          line = Array(Pixel).new(w)
          w.times do
            if k < n
              line << gif_color(table, indices[k], transparent)
            else
              line << Pixel.new(0, 0, 0, 0)
            end
            k += 1
          end
          bmp << line
        end
        img.bmp = bmp
        return
      end

      # Interlaced: indices fill rows out of order, so reassemble via a flat
      # sample buffer first, then pack into rows.
      interlacing = [{0, 8}, {4, 8}, {2, 4}, {1, 2}, {0, 0}]
      samples = Array(Pixel).new(w * h, Pixel.new(0, 0, 0, 0))
      row = 0
      col = 0
      ilp = 0
      indices.each do |b|
        pos = row * w + col
        if pos < samples.size
          samples[pos] = gif_color(table, b, transparent)
        end
        col += 1
        if col >= w
          col = 0
          row += interlacing[ilp][1]
          # Skip *every* pass whose starting row is already past the image, not
          # just one. The four Adam7 passes start at rows 0, 4, 2, 1; for a short
          # image several of those starts can exceed `h` at once (e.g. h<=4 makes
          # pass 2's start of 4 empty). Advancing a single pass per row-overflow
          # left `row` on an out-of-range pass, so that pass's whole row of
          # indices was dropped (`pos >= samples.size`) and every later row landed
          # in the wrong pass — scrambling/blanking short interlaced GIFs. Loop
          # until `row` lands inside the image (or passes are exhausted).
          while row >= h && ilp < interlacing.size - 1
            ilp += 1
            row = interlacing[ilp][0]
          end
        end
      end

      bmp = Bitmap.new(h)
      idx = 0
      h.times do
        line = Array(Pixel).new(w)
        w.times do
          line << (samples[idx]? || Pixel.new(0, 0, 0, 0))
          idx += 1
        end
        bmp << line
      end
      img.bmp = bmp
    end

    # Builds the LZW dictionary in its initial / post-Clear state: `cc` literal
    # entries (each `{value, prev = -1, first = value}`) followed by two reserved
    # slots for the Clear (cc) and EOI (cc+1) codes, so the array index stays in
    # lockstep with `ntable` (which starts at cc+2) as new entries are appended.
    # Shared by `lzw_decompress`'s up-front initialisation and its Clear-code
    # handler, which must reset to byte-identical state.
    private def lzw_init_table(cc : Int32) : Array(Tuple(Int32, Int32, Int32))
      table = [] of Tuple(Int32, Int32, Int32)
      cc.times { |i| table << {i, -1, i} }
      table << {0, -1, 0}
      table << {0, -1, 0}
      table
    end

    # Pushes the byte string for dictionary entry *code* onto *stack* by walking
    # the entry's prev-pointer chain back to its root literal. The chain yields
    # the bytes in reverse, so the caller pops them off `stack` to emit forward
    # order. Shared by `lzw_decompress`'s two emit branches (the in-table code
    # and the KwKwK case), whose walk is otherwise byte-for-byte identical.
    private def lzw_push_string(stack : Array(Int32), table : Array(Tuple(Int32, Int32, Int32)), code : Int32)
      i = code
      while i >= 0
        stack << table[i][0]
        i = table[i][1]
      end
    end

    # LZW decompression ported from tng.js / ka-cs-programs gif-reader (MIT).
    # *expected* is the final index count (image `width*height`); presizing the
    # output array avoids ~log2(N) reallocations + full copies as it fills.
    private def lzw_decompress(input : Bytes, code_size : Int32, expected : Int32 = 0) : Array(Int32)
      bit_depth = code_size + 1
      cc = 1 << code_size
      eoi = cc + 1
      stack = [] of Int32
      # Initialise the dictionary to its post-Clear state up front. A
      # spec-conformant stream opens with a Clear code, whose handler below
      # reinitialises `table`/`ntable`/`max_elem` identically, so valid input is
      # unaffected. But a corrupt stream that omits that leading Clear would
      # otherwise reach the `old_code == -1` literal path (or the code lookups
      # below) with `table` still empty and raise a raw IndexError instead of
      # decoding as gracefully as the rest of the decoder handles bad input.
      table = lzw_init_table(cc)
      ntable = cc + 2
      old_code = -1
      buffer = 0
      nbuffer = 0
      p = 0
      buf = expected > 0 ? Array(Int32).new(expected) : [] of Int32
      max_elem = 1 << bit_depth

      loop do
        if stack.empty?
          bits = bit_depth
          read = 0
          ans = 0
          while read < bits
            if nbuffer == 0
              return buf if p >= input.size
              buffer = input[p].to_i
              p += 1
              nbuffer = 8
            end
            n = Math.min(bits - read, nbuffer)
            ans |= (buffer & ((1 << n) - 1)) << read
            read += n
            nbuffer -= n
            buffer >>= n
          end
          code = ans

          break if code == eoi

          if code == cc
            table = lzw_init_table(cc)
            bit_depth = code_size + 1
            max_elem = 1 << bit_depth
            ntable = cc + 2
            old_code = -1
            next
          end

          if old_code == -1
            # The first data code must reference an existing dictionary entry
            # (a literal, < cc). A corrupt stream whose first code lands in the
            # not-yet-defined range [cc+2, max_elem) would index `table` (size
            # cc+2) past its end; stop cleanly like the truncation return above.
            break if code >= ntable
            old_code = code
            buf << table[code][0]
            next
          end

          if code < ntable
            lzw_push_string(stack, table, code)
            table << {table[code][2], old_code, table[old_code][2]}
            ntable += 1
          else
            # `code >= ntable`: only `code == ntable` is valid (the KwKwK case,
            # resolved by the entry appended just below). A corrupt `code >
            # ntable` references an entry that still won't exist after the
            # append, so the `table[code]` walk would raise IndexError — bail
            # out gracefully instead, matching the decoder's bad-input handling.
            break if code > ntable
            k = table[old_code][2]
            table << {k, old_code, k}
            ntable += 1
            lzw_push_string(stack, table, code)
          end

          old_code = code
          if ntable == max_elem
            bit_depth += 1
            bit_depth = 12 if bit_depth > 12
            max_elem = 1 << bit_depth
          end
        end

        break if stack.empty?
        buf << stack.pop
      end

      buf
    end

    private def u16(b : Bytes, i : Int32) : UInt16
      ((b[i + 1].to_u16 << 8) | b[i].to_u16) # GIF is little-endian
    end
  end
end
