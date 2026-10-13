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

    it "raises a clean error (not IndexError) for a GIF truncated at the image separator" do
      # Valid 13-byte header (no global color table) + an image-separator byte,
      # then nothing: the fixed image descriptor that follows is cut off.
      truncated = Bytes[
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, # "GIF89a"
        0x01, 0x00, 0x01, 0x00,             # 1x1 logical screen
        0x00, 0x00, 0x00,                   # no GCT, bg index, aspect
        0x2c,                               # image separator, then truncated
      ]
      expect_raises(Exception, /truncated/) do
        PNGGIF::PNG.new(truncated)
      end
    end
  end

  describe "APNG frame delays" do
    it "round-trips a canonical num/den delay without truncation" do
      # 1001/1000 s = 1001 ms. The encoder writes delay_num=1001, delay_den=1000;
      # the old float decode `(1001 / 1000 * 1000).to_i` floored to 1000 ms.
      bytes = PNGGIF.encode_apng([{solid_bitmap(2, 2, 1, 2, 3), 1001}])
      png = PNGGIF::PNG.new(bytes)
      frames = png.frames
      fail "expected frames" unless frames
      frames.first.delay.should eq 1001
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

describe "PNGGIF::PNG#create_cellmap" do
  # A one-column bitmap whose red channel is the row index.
  column = ->(h : Int32) do
    PNGGIF::Bitmap.new(h) { |y| [PNGGIF::Pixel.new(y, 0, 0)] }
  end
  png = PNGGIF::PNG.new(PNGGIF.encode_png(solid_bitmap(1, 1, 0, 0, 0)))

  it "samples each cell at its centre when shrinking, reaching the last rows" do
    cm = png.create_cellmap(column.call(4), 1, 2)
    cm.map(&.first.r).should eq [1, 3]
    png.create_cellmap(column.call(4), 1, 2, into: PNGGIF::Bitmap.new).map(&.first.r).should eq [1, 3]
  end

  it "samples each cell at its centre when growing, each source row covering as many cells" do
    png.create_cellmap(column.call(2), 1, 4).map(&.first.r).should eq [0, 0, 1, 1]
    png.create_cellmap(column.call(3), 1, 6, into: PNGGIF::Bitmap.new).map(&.first.r).should eq [0, 0, 1, 1, 2, 2]
  end

  it "samples columns the same way" do
    row = PNGGIF::Bitmap.new(1) { Array(PNGGIF::Pixel).new(6) { |x| PNGGIF::Pixel.new(x, 0, 0) } }
    png.create_cellmap(row, 3, 1).first.map(&.r).should eq [1, 3, 5]
  end
end
