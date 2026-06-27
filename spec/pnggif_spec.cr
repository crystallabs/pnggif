require "./spec_helper"

describe PNGGIF::Pixel do
  it "exposes channels as Int32 in 0..255" do
    px = PNGGIF::Pixel.new(10, 20, 30, 40)
    px.r.should eq 10
    px.g.should eq 20
    px.b.should eq 30
    px.a.should eq 40
  end

  it "defaults alpha to opaque" do
    PNGGIF::Pixel.new(1, 2, 3).a.should eq 255
  end

  it "wraps out-of-range channel values into a byte" do
    px = PNGGIF::Pixel.new(256, 257, -1, 511)
    px.r.should eq 0
    px.g.should eq 1
    px.b.should eq 255
    px.a.should eq 255
  end

  it "supports channel mutation" do
    px = PNGGIF::Pixel.new(0, 0, 0)
    px.r = 100
    px.a = 50
    px.r.should eq 100
    px.a.should eq 50
  end
end

describe PNGGIF::PNG do
  describe "format detection" do
    it "decodes a PNG buffer produced by the encoder" do
      bytes = PNGGIF.encode_png(solid_bitmap(2, 2, 1, 2, 3))
      png = PNGGIF::PNG.new(bytes)
      png.width.should eq 2
      png.height.should eq 2
    end

    it "raises for a buffer that is neither PNG nor GIF and cannot be converted" do
      # No real image; ImageMagick `convert` (if present) also rejects it, so
      # either branch ends in the same "cannot decode image" failure.
      expect_raises(Exception, /cannot decode image/) do
        PNGGIF::PNG.new(Bytes[0x00, 0x01, 0x02, 0x03, 0x04])
      end
    end
  end

  describe "GIF decoding" do
    it "decodes a minimal 1x1 transparent GIF" do
      png = PNGGIF::PNG.new(TRANSPARENT_GIF)
      png.width.should eq 1
      png.height.should eq 1
      png.bmp.size.should eq 1
      png.bmp[0].size.should eq 1
    end

    it "marks the transparent palette index as fully transparent" do
      png = PNGGIF::PNG.new(TRANSPARENT_GIF)
      png.bmp[0][0].a.should eq 0
    end

    it "treats a single-frame GIF as static (no animation frames)" do
      PNGGIF::PNG.new(TRANSPARENT_GIF).frames.should be_nil
    end
  end

  describe "#cellmap" do
    it "downscales with cell-aspect correction by default" do
      png = PNGGIF::PNG.new(PNGGIF.encode_png(solid_bitmap(8, 8, 200, 100, 50)))
      # scale 1.0, cell_aspect 2.0 => full width, half the rows.
      png.cellmap.size.should eq 4
      png.cellmap[0].size.should eq 8
    end

    it "honours an explicit cell width/height verbatim" do
      png = PNGGIF::PNG.new(PNGGIF.encode_png(solid_bitmap(8, 8, 0, 0, 0)),
        cell_width: 4, cell_height: 4)
      png.cellmap.size.should eq 4
      png.cellmap[0].size.should eq 4
    end
  end
end
