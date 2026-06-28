require "compress/zlib"
require "digest/crc32"

# PNG / APNG **encoder** for `PNGGIF` (the rest of the shard only decodes).
#
# Output is always truecolor + alpha (PNG color type 6, 8-bit depth), which is
# the in-memory `Bitmap` format exactly, so no quantization is needed. Scanlines
# use filter type 0 (None); `Compress::Zlib` does the compression and `Digest::CRC32`
# the per-chunk checksums — both already in Crystal's stdlib, so this adds no
# dependency.
#
# * `PNGGIF.encode_png(bmp)`   — a single still image.
# * `PNGGIF.encode_apng(frames)` — an animated PNG from `{bitmap, delay_ms}` frames,
#   reusing the same scanline/zlib path. Decoded back by `PNGGIF::PNG` (its `frames`).
module PNGGIF
  # The 8-byte PNG file signature.
  PNG_SIGNATURE = UInt8.static_array(137, 80, 78, 71, 13, 10, 26, 10)

  # Encodes *bmp* as a still PNG and returns the file bytes.
  def self.encode_png(bmp : Bitmap) : Bytes
    io = IO::Memory.new
    encode_png bmp, io
    io.to_slice
  end

  # Encodes *bmp* as a still PNG, writing the file bytes to *io*.
  def self.encode_png(bmp : Bitmap, io : IO) : Nil
    w, h = bitmap_dimensions bmp
    write_signature io
    write_ihdr io, w, h
    write_chunk io, "IDAT", compress_image(bmp, w, h)
    write_chunk io, "IEND", Bytes.empty
  end

  # Encodes *frames* (`{bitmap, delay_ms}`) as an animated PNG (APNG) and returns
  # the file bytes. *num_plays* is the loop count (0 = loop forever). The first
  # frame doubles as the still `IDAT` (so non-APNG viewers show it). All frames
  # must share the canvas size of the first frame.
  def self.encode_apng(frames : Array(Tuple(Bitmap, Int32)), num_plays : Int32 = 0) : Bytes
    io = IO::Memory.new
    encode_apng frames, io, num_plays
    io.to_slice
  end

  # :ditto:
  def self.encode_apng(frames : Array(Tuple(Bitmap, Int32)), io : IO, num_plays : Int32 = 0) : Nil
    raise ArgumentError.new("encode_apng: no frames") if frames.empty?
    bmp0, _ = frames[0]
    w, h = bitmap_dimensions bmp0

    write_signature io
    write_ihdr io, w, h

    # acTL: animation control (frame count + loop count). A negative loop count
    # is meaningless: written verbatim it would two's-complement-wrap into a huge
    # *finite* count (e.g. -1 -> 4_294_967_295) rather than the infinite loop a
    # caller passing -1 almost certainly intends. APNG already spells "infinite"
    # as 0, so fold any negative value to 0.
    num_plays = 0 if num_plays < 0
    write_chunk io, "acTL" do |actl|
      write_u32 actl, frames.size.to_u32
      write_u32 actl, num_plays.to_u32
    end

    seq = 0_u32
    frames.each_with_index do |(bmp, delay), i|
      fw, fh = bitmap_dimensions bmp
      # All frames share the canvas size: they are encoded at offset 0,0 with
      # dispose NONE / blend SOURCE (full-frame replace), so an undersized frame
      # would leave the previous frame's pixels showing in the uncovered region.
      if fw != w || fh != h
        raise ArgumentError.new("encode_apng: frame #{i} (#{fw}x#{fh}) does not match canvas #{w}x#{h}")
      end
      write_chunk(io, "fcTL") { |m| fctl(m, seq, fw, fh, delay) }
      seq += 1

      data = compress_image(bmp, fw, fh)
      if i == 0
        # First frame's pixels live in IDAT (shared with still viewers).
        write_chunk io, "IDAT", data
      else
        # Subsequent frames: fdAT = 4-byte sequence number + the IDAT payload.
        write_chunk io, "fdAT" do |fdat|
          write_u32 fdat, seq
          fdat.write data
        end
        seq += 1
      end
    end

    write_chunk io, "IEND", Bytes.empty
  end

  # ---- internals -----------------------------------------------------------

  private def self.bitmap_dimensions(bmp : Bitmap) : Tuple(Int32, Int32)
    h = bmp.size
    w = h > 0 ? bmp[0].size : 0
    raise ArgumentError.new("PNGGIF encode: empty bitmap") if w <= 0 || h <= 0
    {w, h}
  end

  private def self.write_signature(io : IO) : Nil
    io.write PNG_SIGNATURE.to_slice
  end

  private def self.write_ihdr(io : IO, w : Int32, h : Int32) : Nil
    write_chunk io, "IHDR" do |ihdr|
      write_u32 ihdr, w.to_u32
      write_u32 ihdr, h.to_u32
      ihdr.write_byte 8u8 # bit depth
      ihdr.write_byte 6u8 # color type: truecolor + alpha
      ihdr.write_byte 0u8 # compression: deflate
      ihdr.write_byte 0u8 # filter method: adaptive (per-scanline byte)
      ihdr.write_byte 0u8 # interlace: none
    end
  end

  # APNG per-frame control: position (always 0,0 — we encode full frames), size,
  # delay as a fraction (delay_ms / 1000), and dispose/blend set to overwrite.
  private def self.fctl(m : IO, seq : UInt32, w : Int32, h : Int32, delay_ms : Int32) : Nil
    write_u32 m, seq
    write_u32 m, w.to_u32
    write_u32 m, h.to_u32
    write_u32 m, 0_u32 # x_offset
    write_u32 m, 0_u32 # y_offset
    # delay = delay_num/delay_den seconds, both uint16. With millisecond units
    # (den 1000) delay_num only reaches 65_535 ms (~65 s), so simply clamping it
    # would silently *misreport* any longer frame delay. Drop to centisecond
    # units (den 100) past that point, extending the range to ~655 s. Round to
    # the nearest centisecond rather than truncating: truncation biases every
    # long delay short by up to 9 ms and, at the unit boundary, makes the encoded
    # delay non-monotonic (65_536 ms would floor to 6553 cs = 65.53 s, *below*
    # the 65.535 s of the 65_535 ms low-branch value).
    delay_ms = 0 if delay_ms < 0
    if delay_ms <= UInt16::MAX
      delay_num, delay_den = delay_ms.to_u16, 1000_u16
    else
      # `delay_ms + 5` would overflow `Int32` for a delay near `Int32::MAX`
      # (Crystal's `+` raises on overflow rather than wrapping, aborting the
      # encode) before the round-and-clamp could cap it. Any delay at/above
      # 655_345 ms already rounds to the 65_535-cs ceiling, so cap there first;
      # below it, `delay_ms + 5` stays well inside `Int32` and the rounded value
      # is <= 65_534, so `to_u16` needs no further clamp.
      cs = delay_ms >= 655_345 ? UInt16::MAX.to_i : (delay_ms + 5) // 10
      delay_num, delay_den = cs.to_u16, 100_u16
    end
    write_u16 m, delay_num # delay_num
    write_u16 m, delay_den # delay_den
    m.write_byte 0u8 # dispose_op: NONE
    m.write_byte 0u8 # blend_op: SOURCE (overwrite)
  end

  # Filters and deflates *bmp* into the compressed PNG image data in one streaming
  # pass, returning the IDAT/fdAT payload. Each scanline is filter type 0 (None) —
  # filter byte, then R,G,B,A per pixel; short rows are padded transparent.
  #
  # The filtered scanlines are fed straight into the `Compress::Zlib::Writer`
  # through a single reused `stride + 1` buffer rather than first materializing
  # the whole `w * h * 4` raw image: peak intermediate memory drops from O(w*h)
  # to O(w), which matters for the megapixel bitmaps / many-frame APNGs this
  # encoder targets, and sidesteps the `Int32` overflow of a `w * h`-sized alloc.
  private def self.compress_image(bmp : Bitmap, w : Int32, h : Int32) : Bytes
    line = Bytes.new(w * 4 + 1)
    line[0] = 0u8 # filter: None — never overwritten, so set once.
    dst = line.to_unsafe + 1
    mem = IO::Memory.new
    Compress::Zlib::Writer.open(mem) do |zw|
      h.times do |y|
        row = bmp[y]
        rn = row.size
        if rn >= w && sizeof(Pixel) == 4
          # `Pixel` is four contiguous bytes laid out r,g,b,a — byte-for-byte the
          # PNG color-type-6 scanline order — so a full-width row's element storage
          # can be copied straight into the scanline (after the filter byte),
          # skipping the per-pixel accessor round-trips. The `sizeof` guard folds to
          # a compile-time constant and keeps this exact-equivalent to the scalar
          # path below should the struct layout ever change. Extra pixels (rn > w)
          # are simply not copied.
          dst.copy_from(row.to_unsafe.as(UInt8*), w * 4)
        else
          oi = 1
          x = 0
          while x < w
            if x < rn
              px = row.unsafe_fetch(x)
              line[oi] = px.r.to_u8!; line[oi + 1] = px.g.to_u8!
              line[oi + 2] = px.b.to_u8!; line[oi + 3] = px.a.to_u8!
            else
              # The buffer is reused across rows, so padding must be re-zeroed
              # (it would otherwise retain the previous row's pixels).
              line[oi] = 0u8; line[oi + 1] = 0u8
              line[oi + 2] = 0u8; line[oi + 3] = 0u8
            end
            oi += 4
            x += 1
          end
        end
        zw.write line
      end
    end
    mem.to_slice
  end

  # Build a chunk whose payload is assembled by the block into a fresh buffer,
  # then framed with `write_chunk`. Folds the `IO::Memory.new` / `to_slice`
  # scaffolding repeated by every length-prefixed chunk (IHDR, acTL, fcTL, fdAT).
  private def self.write_chunk(io : IO, type : String, & : IO ->) : Nil
    m = IO::Memory.new
    yield m
    write_chunk io, type, m.to_slice
  end

  private def self.write_chunk(io : IO, type : String, data : Bytes) : Nil
    write_u32 io, data.size.to_u32
    type_bytes = type.to_slice
    io.write type_bytes
    io.write data
    crc = Digest::CRC32.update(type_bytes, Digest::CRC32.initial)
    crc = Digest::CRC32.update(data, crc)
    write_u32 io, crc
  end

  # PNG stores every multi-byte integer in network (big-endian) order; these
  # wrap the one stdlib call so that convention lives in a single place instead
  # of being respelled at every IHDR/acTL/fcTL/fdAT/chunk-framing field. Width
  # is explicit in the name so each call site still commits to a u32 or u16.
  private def self.write_u32(io : IO, value : UInt32) : Nil
    io.write_bytes value, IO::ByteFormat::BigEndian
  end

  private def self.write_u16(io : IO, value : UInt16) : Nil
    io.write_bytes value, IO::ByteFormat::BigEndian
  end
end
