require "./spec_helper"

# Assembles a PNG from raw chunk payloads. The decoder does not check CRCs,
# so they are written as zero.
private def b20_png(chunks : Array(Tuple(String, Bytes))) : Bytes
  io = IO::Memory.new
  io.write PNGGIF::PNG_SIGNATURE.to_slice
  chunks.each do |(type, data)|
    io.write_bytes data.size.to_u32, IO::ByteFormat::BigEndian
    io << type
    io.write data
    io.write_bytes 0_u32, IO::ByteFormat::BigEndian
  end
  io.to_slice
end

private def b20_be(io : IO, v : UInt32) : Nil
  io.write_bytes v, IO::ByteFormat::BigEndian
end

private def b20_ihdr(w : Int32, h : Int32, depth : Int32, color_type : Int32) : Bytes
  io = IO::Memory.new
  b20_be io, w.to_u32
  b20_be io, h.to_u32
  io.write Bytes[depth.to_u8, color_type.to_u8, 0, 0, 0]
  io.to_slice
end

private def b20_zlib(raw : Bytes) : Bytes
  io = IO::Memory.new
  Compress::Zlib::Writer.open(io) { |z| z.write raw }
  io.to_slice
end

private def b20_fctl(seq : Int32, w : UInt32, h : UInt32, x : UInt32, y : UInt32) : Bytes
  io = IO::Memory.new
  b20_be io, seq.to_u32
  b20_be io, w
  b20_be io, h
  b20_be io, x
  b20_be io, y
  io.write Bytes[0, 1, 0, 10, 0, 0] # delay 1/10 s, dispose none, blend source
  io.to_slice
end

private def b20_actl(frames : Int32) : Bytes
  io = IO::Memory.new
  b20_be io, frames.to_u32
  b20_be io, 0_u32
  io.to_slice
end

# A 1×1 opaque RGBA canvas whose second APNG frame declares *w*×*h* at
# (*x*,*y*).
private def b20_apng(w : UInt32, h : UInt32, x : UInt32 = 0_u32, y : UInt32 = 0_u32) : Bytes
  pixel = b20_zlib(Bytes[0, 10, 20, 30, 255])
  fdat = IO::Memory.new
  b20_be fdat, 2_u32
  fdat.write pixel
  b20_png([
    {"IHDR", b20_ihdr(1, 1, 8, 6)},
    {"acTL", b20_actl(2)},
    {"fcTL", b20_fctl(0, 1_u32, 1_u32, 0_u32, 0_u32)},
    {"IDAT", pixel},
    {"fcTL", b20_fctl(1, w, h, x, y)},
    {"fdAT", fdat.to_slice},
    {"IEND", Bytes.empty},
  ])
end

describe PNGGIF::PNG do
  describe "16-bit tRNS color key" do
    it "keys only the exact 16-bit gray sample, not every sample sharing its high byte" do
      raw = Bytes[0, 0x12, 0x34, 0x12, 0x00] # filter 0, gray 0x1234, gray 0x1200
      png = PNGGIF::PNG.new(b20_png([
        {"IHDR", b20_ihdr(2, 1, 16, 0)},
        {"tRNS", Bytes[0x12, 0x34]},
        {"IDAT", b20_zlib(raw)},
        {"IEND", Bytes.empty},
      ]))
      png.bmp[0][0].a.should eq 0
      png.bmp[0][1].a.should eq 255
      png.bmp[0][1].r.should eq 0x12
    end

    it "keys only the exact 16-bit RGB triple" do
      raw = Bytes[0, 0x12, 0x34, 0, 0, 0, 0, 0x12, 0x00, 0, 0, 0, 0]
      png = PNGGIF::PNG.new(b20_png([
        {"IHDR", b20_ihdr(2, 1, 16, 2)},
        {"tRNS", Bytes[0x12, 0x34, 0, 0, 0, 0]},
        {"IDAT", b20_zlib(raw)},
        {"IEND", Bytes.empty},
      ]))
      png.bmp[0][0].a.should eq 0
      png.bmp[0][1].a.should eq 255
    end
  end

  describe "APNG frame regions" do
    it "decodes a frame that lies within the canvas" do
      png = PNGGIF::PNG.new(b20_apng(1_u32, 1_u32))
      png.frames.try(&.size).should eq 2
    end

    it "skips a frame that extends past the canvas" do
      png = PNGGIF::PNG.new(b20_apng(4000_u32, 4000_u32))
      png.frames.try(&.size).should eq 1
      png.bmp.size.should eq 1
    end

    it "skips a frame whose offset puts it off the canvas" do
      png = PNGGIF::PNG.new(b20_apng(1_u32, 1_u32, 1_u32, 0_u32))
      png.frames.try(&.size).should eq 1
    end

    it "skips a frame whose dimensions have bit 31 set instead of raising" do
      png = PNGGIF::PNG.new(b20_apng(0x8000_0000_u32, 1_u32))
      png.frames.try(&.size).should eq 1
    end
  end
end

private def b20_gif(screen_w : Int32, screen_h : Int32, img_w : Int32, img_h : Int32) : Bytes
  gif = TRANSPARENT_GIF.dup
  {6 => screen_w, 8 => screen_h, 32 => img_w, 34 => img_h}.each do |at, v|
    gif[at] = (v & 0xff).to_u8
    gif[at + 1] = (v >> 8).to_u8
  end
  gif
end

describe "PNGGIF pixel limit" do
  it "has a default no realistic image reaches" do
    PNGGIF::DEFAULT_MAX_PIXELS.should eq 134_217_728
    PNGGIF::PNG.new(PNGGIF.encode_png(sample_bitmap(4, 4))).max_pixels.should eq PNGGIF::DEFAULT_MAX_PIXELS
  end

  it "rejects a PNG whose IHDR declares more pixels than the limit" do
    tiny = b20_zlib(Bytes[0, 0])
    expect_raises(Exception, /exceed the 134217728-pixel limit/) do
      PNGGIF::PNG.new(b20_png([{"IHDR", b20_ihdr(40_000, 40_000, 8, 6)}, {"IDAT", tiny}, {"IEND", Bytes.empty}]))
    end
    # One side alone within Int32, the product far beyond it.
    expect_raises(Exception, /pixel limit/) do
      PNGGIF::PNG.new(b20_png([{"IHDR", b20_ihdr(Int32::MAX, Int32::MAX, 1, 0)}, {"IDAT", tiny}, {"IEND", Bytes.empty}]))
    end
  end

  it "rejects an interlaced PNG over the limit" do
    ihdr = b20_ihdr(40_000, 40_000, 8, 6)
    ihdr[12] = 1_u8
    expect_raises(Exception, /pixel limit/) do
      PNGGIF::PNG.new(b20_png([{"IHDR", ihdr}, {"IDAT", b20_zlib(Bytes[0, 0])}, {"IEND", Bytes.empty}]))
    end
  end

  it "takes the limit from the initializer" do
    data = PNGGIF.encode_png(sample_bitmap(4, 4))
    PNGGIF::PNG.new(data, max_pixels: 16).width.should eq 4
    expect_raises(Exception, /exceed the 15-pixel limit/) do
      PNGGIF::PNG.new(data, max_pixels: 15)
    end
  end

  it "rejects a GIF logical screen over the limit" do
    expect_raises(Exception, /bad gif: dimensions 65535x65535 exceed/) do
      PNGGIF::PNG.new(b20_gif(65_535, 65_535, 1, 1))
    end
    expect_raises(Exception, /pixel limit/) do
      PNGGIF::GIF.new(b20_gif(65_535, 65_535, 1, 1))
    end
  end

  it "rejects a GIF image over the limit on a small logical screen" do
    expect_raises(Exception, /bad gif image: dimensions 30000x30000 exceed/) do
      PNGGIF::PNG.new(b20_gif(1, 1, 30_000, 30_000))
    end
  end

  it "passes the initializer's limit to the GIF decoder" do
    PNGGIF::PNG.new(b20_gif(3, 3, 1, 1), max_pixels: 9).width.should eq 3
    expect_raises(Exception, /exceed the 8-pixel limit/) do
      PNGGIF::PNG.new(b20_gif(3, 3, 1, 1), max_pixels: 8)
    end
    expect_raises(Exception, /exceed the 8-pixel limit/) do
      PNGGIF::GIF.new(b20_gif(1, 1, 3, 3), max_pixels: 8)
    end
  end

  it "inflates no more than the declared dimensions need" do
    # 2x2 8-bit gray needs 6 bytes; the stream expands to 64 MiB.
    bomb = b20_zlib(Bytes.new(64 * 1024 * 1024))
    data = b20_png([{"IHDR", b20_ihdr(2, 2, 8, 0)}, {"IDAT", bomb}, {"IEND", Bytes.empty}])
    before = GC.stats.total_bytes
    png = PNGGIF::PNG.new(data)
    (GC.stats.total_bytes - before).should be < 4_u64 * 1024 * 1024
    png.bmp.size.should eq 2
    png.bmp[1].size.should eq 2
  end

  it "still decodes a stream shorter than the declared dimensions" do
    data = b20_png([{"IHDR", b20_ihdr(2, 3, 8, 0)}, {"IDAT", b20_zlib(Bytes[0, 9, 9])}, {"IEND", Bytes.empty}])
    png = PNGGIF::PNG.new(data)
    png.bmp.size.should eq 3
    png.bmp[0][0].r.should eq 9
    png.bmp[2][1].a.should eq 0
  end
end
