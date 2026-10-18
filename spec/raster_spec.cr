require "./spec_helper"

describe PNGGIF::Raster do
  describe ".pack_rgba / .unpack_rgba" do
    it "round-trips a row through interleaved RGBA bytes" do
      row = sample_bitmap(5, 1)[0]
      bytes = Bytes.new(20)
      PNGGIF::Raster.pack_rgba(row, 5, bytes)
      bytes[0, 4].should eq Bytes[row[0].r, row[0].g, row[0].b, row[0].a]
      bytes[16, 4].should eq Bytes[row[4].r, row[4].g, row[4].b, row[4].a]
      PNGGIF::Raster.unpack_rgba(bytes, 5).should eq row
      into = Array(PNGGIF::Pixel).new(5, PNGGIF::Pixel.new(9, 9, 9, 9))
      PNGGIF::Raster.unpack_rgba(bytes, into, 5)
      into.should eq row
    end

    it "pads a short row transparent and drops extra pixels" do
      bytes = Bytes.new(12, 0xff_u8)
      PNGGIF::Raster.pack_rgba([PNGGIF::Pixel.new(1, 2, 3)], 3, bytes)
      bytes.should eq Bytes[1, 2, 3, 255, 0, 0, 0, 0, 0, 0, 0, 0]
      PNGGIF::Raster.pack_rgba(solid_bitmap(4, 1, 7, 7, 7)[0], 1, bytes)
      bytes[0, 4].should eq Bytes[7, 7, 7, 255]
    end
  end

  describe ".rgba" do
    it "keeps rows aligned when one is short" do
      bmp = solid_bitmap(2, 3, 1, 2, 3)
      bmp[1] = [PNGGIF::Pixel.new(4, 5, 6)]
      bytes = PNGGIF::Raster.rgba(bmp)
      bytes.size.should eq 24
      bytes[8, 8].should eq Bytes[4, 5, 6, 255, 0, 0, 0, 0]
      bytes[16, 4].should eq Bytes[1, 2, 3, 255]
    end
  end
end

describe "PNGGIF::Raster.dither_rgb" do
  it "treats missing rows and pixels as transparent" do
    bmp = solid_bitmap(2, 1, 10, 20, 30)
    out = PNGGIF::Raster.dither_rgb(bmp, 3, 2, PNGGIF::Raster::Dither::None, false, -1) do |r, g, b, _t|
      {(r << 16) | (g << 8) | b, r, g, b}
    end
    out.should eq [[0x0a141e, 0x0a141e, -1], [-1, -1, -1]]
  end
end
