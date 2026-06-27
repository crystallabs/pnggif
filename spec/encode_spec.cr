require "./spec_helper"

describe "PNGGIF.encode_png" do
  it "produces bytes carrying the PNG signature" do
    bytes = PNGGIF.encode_png(solid_bitmap(1, 1, 0, 0, 0))
    sig = PNGGIF::PNG_SIGNATURE.to_slice
    bytes[0, sig.size].should eq sig
  end

  it "round-trips dimensions and every pixel through decode" do
    src = sample_bitmap(5, 3)
    png = PNGGIF::PNG.new(PNGGIF.encode_png(src))

    png.width.should eq 5
    png.height.should eq 3
    png.color_type.should eq 6
    png.bit_depth.should eq 8

    3.times do |y|
      5.times do |x|
        got = png.bmp[y][x]
        want = src[y][x]
        {got.r, got.g, got.b, got.a}.should eq({want.r, want.g, want.b, want.a})
      end
    end
  end

  it "preserves non-opaque alpha (truecolor + alpha)" do
    src = solid_bitmap(2, 2, 10, 20, 30, 64)
    png = PNGGIF::PNG.new(PNGGIF.encode_png(src))
    px = png.bmp[0][0]
    {px.r, px.g, px.b, px.a}.should eq({10, 20, 30, 64})
  end

  it "writes to a supplied IO" do
    io = IO::Memory.new
    PNGGIF.encode_png(solid_bitmap(1, 1, 5, 5, 5), io)
    io.size.should be > 0
    PNGGIF::PNG.new(io.to_slice).width.should eq 1
  end

  it "rejects an empty bitmap" do
    expect_raises(ArgumentError) { PNGGIF.encode_png(PNGGIF::Bitmap.new) }
  end
end

describe "PNGGIF.encode_apng" do
  it "round-trips multiple frames, loop count and delays" do
    f0 = solid_bitmap(3, 2, 255, 0, 0)
    f1 = solid_bitmap(3, 2, 0, 255, 0)
    bytes = PNGGIF.encode_apng([{f0, 100}, {f1, 200}], num_plays: 3)

    png = PNGGIF::PNG.new(bytes)
    png.width.should eq 3
    png.height.should eq 2
    png.num_plays.should eq 3

    frames = png.frames.should_not be_nil
    frames.size.should eq 2
    frames[0].delay.should eq 100
    frames[1].delay.should eq 200

    # First frame doubles as the still IDAT, so #bmp is frame 0.
    png.bmp[0][0].r.should eq 255
    frames[0].bmp[0][0].r.should eq 255
    frames[1].bmp[0][0].g.should eq 255
  end

  it "rejects an empty frame list" do
    expect_raises(ArgumentError) do
      PNGGIF.encode_apng([] of Tuple(PNGGIF::Bitmap, Int32))
    end
  end
end

describe "PNGGIF::PNG.from_frames" do
  it "builds an animation directly from decoded frames" do
    f0 = solid_bitmap(4, 4, 10, 0, 0)
    f1 = solid_bitmap(4, 4, 0, 10, 0)
    png = PNGGIF::PNG.from_frames([{f0, 50}, {f1, 60}], 4, 4, num_plays: 2)

    png.canvas_width.should eq 4
    png.canvas_height.should eq 4
    png.num_plays.should eq 2

    frames = png.frames.should_not be_nil
    frames.size.should eq 2
  end

  it "composites per-frame animation cellmaps" do
    f0 = solid_bitmap(4, 4, 10, 0, 0)
    f1 = solid_bitmap(4, 4, 0, 10, 0)
    png = PNGGIF::PNG.from_frames([{f0, 50}, {f1, 60}], 4, 4)

    cellmaps = png.animation_cellmaps.should_not be_nil
    cellmaps.size.should eq 2
    cellmaps[0][1].should eq 50
    cellmaps[1][1].should eq 60
  end

  it "rejects an empty frame list" do
    expect_raises(Exception) do
      PNGGIF::PNG.from_frames([] of Tuple(PNGGIF::Bitmap, Int32), 4, 4)
    end
  end
end
