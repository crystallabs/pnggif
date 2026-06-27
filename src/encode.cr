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
    write_chunk io, "IDAT", deflate(filter_none(bmp, w, h))
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

    # acTL: animation control (frame count + loop count).
    actl = IO::Memory.new
    actl.write_bytes frames.size.to_u32, IO::ByteFormat::BigEndian
    actl.write_bytes num_plays.to_u32, IO::ByteFormat::BigEndian
    write_chunk io, "acTL", actl.to_slice

    seq = 0_u32
    frames.each_with_index do |(bmp, delay), i|
      fw, fh = bitmap_dimensions bmp
      # All frames share the canvas size: they are encoded at offset 0,0 with
      # dispose NONE / blend SOURCE (full-frame replace), so an undersized frame
      # would leave the previous frame's pixels showing in the uncovered region.
      if fw != w || fh != h
        raise ArgumentError.new("encode_apng: frame #{i} (#{fw}x#{fh}) does not match canvas #{w}x#{h}")
      end
      write_chunk io, "fcTL", fctl(seq, fw, fh, delay)
      seq += 1

      data = deflate(filter_none(bmp, fw, fh))
      if i == 0
        # First frame's pixels live in IDAT (shared with still viewers).
        write_chunk io, "IDAT", data
      else
        # Subsequent frames: fdAT = 4-byte sequence number + the IDAT payload.
        fdat = IO::Memory.new
        fdat.write_bytes seq, IO::ByteFormat::BigEndian
        fdat.write data
        write_chunk io, "fdAT", fdat.to_slice
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
    ihdr = IO::Memory.new
    ihdr.write_bytes w.to_u32, IO::ByteFormat::BigEndian
    ihdr.write_bytes h.to_u32, IO::ByteFormat::BigEndian
    ihdr.write_byte 8u8 # bit depth
    ihdr.write_byte 6u8 # color type: truecolor + alpha
    ihdr.write_byte 0u8 # compression: deflate
    ihdr.write_byte 0u8 # filter method: adaptive (per-scanline byte)
    ihdr.write_byte 0u8 # interlace: none
    write_chunk io, "IHDR", ihdr.to_slice
  end

  # APNG per-frame control: position (always 0,0 — we encode full frames), size,
  # delay as a fraction (delay_ms / 1000), and dispose/blend set to overwrite.
  private def self.fctl(seq : UInt32, w : Int32, h : Int32, delay_ms : Int32) : Bytes
    m = IO::Memory.new
    m.write_bytes seq, IO::ByteFormat::BigEndian
    m.write_bytes w.to_u32, IO::ByteFormat::BigEndian
    m.write_bytes h.to_u32, IO::ByteFormat::BigEndian
    m.write_bytes 0_u32, IO::ByteFormat::BigEndian                                # x_offset
    m.write_bytes 0_u32, IO::ByteFormat::BigEndian                                # y_offset
    m.write_bytes delay_ms.clamp(0, UInt16::MAX).to_u16, IO::ByteFormat::BigEndian # delay_num (ms)
    m.write_bytes 1000_u16, IO::ByteFormat::BigEndian                             # delay_den
    m.write_byte 0u8                                                              # dispose_op: NONE
    m.write_byte 0u8                                                              # blend_op: SOURCE (overwrite)
    m.to_slice
  end

  # Serializes *bmp* to raw PNG image data: each scanline prefixed with filter
  # byte 0 (None), then R,G,B,A per pixel. Short rows are padded transparent.
  private def self.filter_none(bmp : Bitmap, w : Int32, h : Int32) : Bytes
    stride = w * 4
    data = Bytes.new(h * (stride + 1))
    oi = 0
    h.times do |y|
      data[oi] = 0u8 # filter: None
      oi += 1
      row = bmp[y]
      rn = row.size
      x = 0
      while x < w
        if x < rn
          px = row.unsafe_fetch(x)
          data[oi] = px.r.to_u8!; data[oi + 1] = px.g.to_u8!
          data[oi + 2] = px.b.to_u8!; data[oi + 3] = px.a.to_u8!
        end # else leaves {0,0,0,0} transparent
        oi += 4
        x += 1
      end
    end
    data
  end

  private def self.deflate(raw : Bytes) : Bytes
    mem = IO::Memory.new
    Compress::Zlib::Writer.open(mem) do |zw|
      zw.write raw
    end
    mem.to_slice
  end

  private def self.write_chunk(io : IO, type : String, data : Bytes) : Nil
    io.write_bytes data.size.to_u32, IO::ByteFormat::BigEndian
    type_bytes = type.to_slice
    io.write type_bytes
    io.write data
    crc = Digest::CRC32.update(type_bytes, Digest::CRC32.initial)
    crc = Digest::CRC32.update(data, crc)
    io.write_bytes crc, IO::ByteFormat::BigEndian
  end
end
