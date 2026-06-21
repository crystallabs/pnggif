require "compress/zlib"

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
  struct Pixel
    property r : Int32
    property g : Int32
    property b : Int32
    property a : Int32

    def initialize(@r : Int32, @g : Int32, @b : Int32, @a : Int32 = 255)
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
    property ascii : Bool
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
      samples = parse_lines idat
      @bmp = create_bitmap samples
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
        len = u32(buf, i).to_i
        i += 4
        name = String.new(buf[i, 4])
        i += 4
        break if i + len > buf.size
        data = buf[i, len]
        i += len
        i += 4 # skip CRC

        case name
        when "IHDR"
          @width = u32(data, 0).to_i
          @height = u32(data, 4).to_i
          @bit_depth = data[8].to_i
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
          # Palette transparency: assign alpha to existing palette entries.
          data.each_with_index do |alpha, idx|
            break if idx >= @palette.size
            old = @palette[idx]
            @palette[idx] = Pixel.new(old.r, old.g, old.b, alpha.to_i)
          end
        when "IDAT"
          @idat << bytes_dup(data)
        when "acTL"
          @actl = {"numFrames" => u32(data, 0).to_i, "numPlays" => u32(data, 4).to_i}
          @num_plays = u32(data, 4).to_i
        when "fcTL"
          fctl = parse_fctl(data)
          if @idat.empty?
            # IDAT is itself the first frame: acTL->fcTL->IDAT
            @raw_frames << {fctl: fctl, fdat: @idat, idat: true}
          else
            @raw_frames << {fctl: fctl, fdat: [] of Bytes, idat: false}
          end
        when "fdAT"
          # First 4 bytes are a sequence number; the rest is zlib data.
          @raw_frames[-1][:fdat] << bytes_dup(data[4, data.size - 4])
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
        samples = parse_lines idat
        bmp = create_bitmap samples
        den = fc["delayDen"] == 0 ? 100 : fc["delayDen"]
        delay = (fc["delayNum"] / den * 1000).to_i
        frames << Frame.new(bmp, delay, fc["width"], fc["height"],
          fc["xOffset"], fc["yOffset"], fc["disposeOp"], fc["blendOp"])
      end
      frames.empty? ? nil : frames
    end

    # --------------------------------------------------------------- scanlines

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

    private def parse_lines(data : Bytes) : Array(Int32)
      compute_metrics
      return sample_interlaced_lines(data) if @interlace == 1

      samples = Array(Int32).new(@width * @height * @sample_depth)
      prior = Bytes.new(@byte_width, 0u8)
      p = 0
      while p < data.size
        filter = data[p].to_i
        p += 1
        line = Bytes.new(@byte_width, 0u8)
        n = Math.min(@byte_width, data.size - p)
        data[p, n].copy_to(line) if n > 0
        p += @byte_width
        unfilter_line filter, line, prior
        sample_line_into samples, line, @width
        prior = line
      end
      samples
    end

    private def unfilter_line(filter : Int32, line : Bytes, prior : Bytes)
      return if filter == 0
      bpp = @bytes_per_pixel
      x = 0
      while x < line.size
        a = x >= bpp ? line[x - bpp].to_i : 0
        b = x < prior.size ? prior[x].to_i : 0
        c = (x >= bpp && x - bpp < prior.size) ? prior[x - bpp].to_i : 0
        cur = line[x].to_i
        val = case filter
              when 1 then cur + a
              when 2 then cur + b
              when 3 then cur + ((a + b) // 2)
              when 4 then cur + paeth(a, b, c)
              else        cur
              end
        line[x] = (val & 0xff).to_u8
        x += 1
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

    private def create_bitmap(samples : Array(Int32)) : Bitmap
      rows = Bitmap.new
      w = @width
      return rows if w <= 0

      sd = @sample_depth
      row = Array(Pixel).new(w)
      i = 0
      while i < samples.size
        case @color_type
        when 0
          v = sample_to_8bit samples[i]
          row << Pixel.new(v, v, v, 255)
        when 2
          row << Pixel.new(sample_to_8bit(samples[i]), sample_to_8bit(samples[i + 1]), sample_to_8bit(samples[i + 2]), 255)
        when 3
          idx = samples[i]
          row << (@palette[idx]? || Pixel.new(0, 0, 0, 0))
        when 4
          v = sample_to_8bit samples[i]
          row << Pixel.new(v, v, v, sample_to_8bit(samples[i + 1]))
        when 6
          row << Pixel.new(sample_to_8bit(samples[i]), sample_to_8bit(samples[i + 1]), sample_to_8bit(samples[i + 2]), sample_to_8bit(samples[i + 3]))
        end
        i += sd
        if row.size == w
          rows << row
          row = Array(Pixel).new(w)
        end
      end
      rows << row unless row.empty?
      rows
    end

    # Adam7 deinterlacing, ported from tng.js (originally from PyPNG, MIT).
    private def sample_interlaced_lines(raw : Bytes) : Array(Int32)
      adam7 = [{0, 0, 8, 8}, {4, 0, 8, 8}, {0, 4, 4, 8}, {2, 0, 4, 4}, {0, 2, 2, 4}, {1, 0, 2, 2}, {0, 1, 1, 2}]
      psize = (@bit_depth / 8.0) * @sample_depth
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
          filter = raw[source].to_i
          source += 1
          line = Bytes.new(row_size, 0u8)
          n = Math.min(row_size, raw.size - source)
          raw[source, n].copy_to(line) if n > 0
          source += row_size
          unfilter_line filter, line, recon
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

      cellmap = Bitmap.new
      y = 0.0
      while y < height
        yy = y.round.to_i
        row = bmp[yy]?
        break unless row
        line = [] of Pixel
        x = 0.0
        while x < width
          xx = x.round.to_i
          px = row[xx]?
          break unless px
          line << px
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
      return nil unless fr && !fr.empty?

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
        snapshot = nil
        if frame.dispose_op == 2
          snapshot = Bitmap.new
          frame.height.times do |sy|
            row = Array(Pixel).new(frame.width)
            frame.width.times { |sx| row << canvas[frame.y_offset + sy][frame.x_offset + sx] }
            snapshot << row
          end
        end

        # Blit the frame onto the canvas (blend_op 0 = source, 1 = over).
        frame.height.times do |sy|
          fy = frame.y_offset + sy
          next unless (0...@canvas_height).includes?(fy)
          frow = frame.bmp[sy]?
          next unless frow
          frame.width.times do |sx|
            fx = frame.x_offset + sx
            next unless (0...@canvas_width).includes?(fx)
            px = frow[sx]?
            next unless px
            if frame.blend_op == 0 || px.a != 0
              canvas[fy][fx] = px
            end
          end
        end

        prev_snapshot = snapshot
        prev = frame
        result << {create_cellmap(canvas, cmwidth, cmheight, scale), frame.delay}
      end

      result
    end

    private def each_rect(frame : Frame, &)
      frame.height.times do |sy|
        y = frame.y_offset + sy
        next unless (0...@canvas_height).includes?(y)
        frame.width.times do |sx|
          x = frame.x_offset + sx
          next unless (0...@canvas_width).includes?(x)
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

      @bmp = frames[0].bmp
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
      status = Process.run("convert", ["-:-", "png:-"], input: IO::Memory.new(input), output: stdout, error: Process::Redirect::Close)
      raise "cannot decode image: ImageMagick `convert` failed or is not installed" unless status.success?
      stdout.to_slice
    rescue ex : File::NotFoundError | RuntimeError
      raise "cannot decode image: install ImageMagick (`convert`) for non-PNG/GIF formats"
    end

    # ------------------------------------------------------------- decompress

    private def inflate(buffers : Array(Bytes)) : Bytes
      return Bytes.empty if buffers.empty?
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

    private def bytes_dup(b : Bytes) : Bytes
      dup = Bytes.new(b.size)
      b.copy_to(dup)
      dup
    end

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
      property interlaced = false
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
        total.times do
          @colors << Pixel.new(buf[p].to_i, buf[p + 1].to_i, buf[p + 2].to_i, 255)
          p += 3
        end
      end

      p = parse_blocks(buf, p)
      raise "no image data or bad decompress" if @images.empty?
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
      label = buf[p]
      p += 1
      if label == 0xf9 # graphic control
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
        p += 1            # block size (always 11)
        id = String.new(buf[p, 8])
        auth = String.new(buf[p + 8, 3])
        p += 11
        data = [] of UInt8
        while p < buf.size && buf[p] != 0x00
          bsize = buf[p].to_i
          p += 1
          data.concat(buf[p, bsize])
          p += bsize
        end
        p += 1
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

    private def parse_image(buf : Bytes, p : Int32) : Int32
      img = Image.new
      img.left = u16(buf, p).to_i; p += 2
      img.top = u16(buf, p).to_i; p += 2
      img.width = u16(buf, p).to_i; p += 2
      img.height = u16(buf, p).to_i; p += 2
      flags = buf[p].to_i; p += 1
      lct = (flags & 0x80) != 0
      img.interlaced = (flags & 0x40) != 0
      lctsize = (flags & 0x07) + 1

      table = @colors
      if lct
        table = [] of Pixel
        total = 1 << lctsize
        total.times do
          table << Pixel.new(buf[p].to_i, buf[p + 1].to_i, buf[p + 2].to_i, 255)
          p += 3
        end
      end

      code_size = buf[p].to_i; p += 1
      lzw = [] of UInt8
      while p < buf.size && buf[p] != 0x00
        size = buf[p].to_i
        p += 1
        lzw.concat(buf[p, size])
        p += size
      end
      p += 1 # block terminator

      img.delay = @gc_delay
      img.dispose_method = @gc_dispose
      indices = lzw_decompress(Slice.new(lzw.to_unsafe, lzw.size), code_size)
      build_gif_bitmap img, indices, table, @gc_transparent
      @images << img

      # Reset transient graphic-control state after consuming it.
      @gc_delay = 0
      @gc_dispose = 0
      @gc_transparent = -1
      p
    end

    private def build_gif_bitmap(img, indices, table, transparent)
      interlacing = [{0, 8}, {4, 8}, {2, 4}, {1, 2}, {0, 0}]
      # Place indices into a row-major sample buffer, honouring interlacing.
      samples = Array(Pixel).new(img.width * img.height, Pixel.new(0, 0, 0, 0))
      row = 0
      col = 0
      ilp = 0
      indices.each do |b|
        if pos = (row * img.width + col)
          color = table[b]? || Pixel.new(0, 0, 0, 0)
          color = Pixel.new(color.r, color.g, color.b, 0) if transparent >= 0 && b == transparent
          samples[pos] = color if pos < samples.size
        end
        col += 1
        if col >= img.width
          col = 0
          if img.interlaced
            row += interlacing[ilp][1]
            if row >= img.height && ilp < interlacing.size - 1
              ilp += 1
              row = interlacing[ilp][0]
            end
          else
            row += 1
          end
        end
      end

      bmp = Bitmap.new
      idx = 0
      img.height.times do
        line = [] of Pixel
        img.width.times do
          line << (samples[idx]? || Pixel.new(0, 0, 0, 0))
          idx += 1
        end
        bmp << line
      end
      img.bmp = bmp
    end

    # LZW decompression ported from tng.js / ka-cs-programs gif-reader (MIT).
    private def lzw_decompress(input : Bytes, code_size : Int32) : Array(Int32)
      bit_depth = code_size + 1
      cc = 1 << code_size
      eoi = cc + 1
      stack = [] of Int32
      table = [] of Tuple(Int32, Int32, Int32)
      ntable = 0
      old_code = -1
      buffer = 0
      nbuffer = 0
      p = 0
      buf = [] of Int32
      max_elem = 0

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
            table = [] of Tuple(Int32, Int32, Int32)
            cc.times { |i| table << {i, -1, i} }
            # Reserve slots for the Clear (cc) and EOI (cc+1) codes so that the
            # array index stays in lockstep with `ntable` (which starts at cc+2)
            # as new entries are appended.
            table << {0, -1, 0}
            table << {0, -1, 0}
            bit_depth = code_size + 1
            max_elem = 1 << bit_depth
            ntable = cc + 2
            old_code = -1
            next
          end

          if old_code == -1
            old_code = code
            buf << table[code][0]
            next
          end

          if code < ntable
            i = code
            while i >= 0
              stack << table[i][0]
              i = table[i][1]
            end
            table << {table[code][2], old_code, table[old_code][2]}
            ntable += 1
          else
            k = table[old_code][2]
            table << {k, old_code, k}
            ntable += 1
            i = code
            while i >= 0
              stack << table[i][0]
              i = table[i][1]
            end
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
