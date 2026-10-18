require "./spec_helper"

# The fixtures are one 9×7 source image (see `reference_bitmap`) written by
# ImageMagick in every PNG colour type / bit depth, each both non-interlaced
# (`name.png`) and Adam7-interlaced (`name_i.png`), so the two scanline paths
# can be checked against each other and, where the conversion is lossless,
# against the source pixels.
FIXTURES = File.join(__DIR__, "fixtures")

def fixture(name : String) : PNGGIF::PNG
  PNGGIF::PNG.new(File.join(FIXTURES, name.starts_with?("gif") ? "#{name}.gif" : "#{name}.png"))
end

# The 9×7 pattern the fixtures were generated from.
def reference_bitmap : PNGGIF::Bitmap
  PNGGIF::Bitmap.new(7) do |y|
    Array(PNGGIF::Pixel).new(9) { |x| PNGGIF::Pixel.new((x * 29) % 256, (y * 37) % 256, (x * y * 13) % 256, 255 - ((x + y) * 9) % 128) }
  end
end

def pixels(bmp : PNGGIF::Bitmap) : Array(Array(Tuple(Int32, Int32, Int32, Int32)))
  bmp.map(&.map { |px| {px.r, px.g, px.b, px.a} })
end

describe "PNG fixtures" do
  {
    {"rgba8", 6, 8}, {"rgba16", 6, 16}, {"rgb8", 2, 8}, {"rgb16", 2, 16},
    {"ga8", 4, 8}, {"ga16", 4, 16},
    {"gray8", 0, 8}, {"gray16", 0, 16}, {"gray4", 0, 4}, {"gray2", 0, 2}, {"gray1", 0, 1},
    {"pal8", 3, 8}, {"pal4", 3, 4}, {"pal2", 3, 2}, {"pal1", 3, 1}, {"pal8a", 3, 8},
    {"rgb8key", 2, 8}, {"gray8key", 0, 8}, {"gray4key", 0, 4},
  }.each do |(name, color_type, bit_depth)|
    it "decodes #{name} identically interlaced and non-interlaced" do
      plain = fixture(name)
      inter = fixture("#{name}_i")
      plain.color_type.should eq color_type
      plain.bit_depth.should eq bit_depth
      {plain, inter}.each do |png|
        png.width.should eq 9
        png.height.should eq 7
        png.bmp.size.should eq 7
        png.bmp.all? { |row| row.size == 9 }.should be_true
      end
      pixels(inter.bmp).should eq pixels(plain.bmp)
    end
  end

  it "decodes 8- and 16-bit truecolor (with and without alpha) to the source pixels" do
    want = pixels(reference_bitmap)
    opaque = want.map(&.map { |(r, g, b, _)| {r, g, b, 255} })
    pixels(fixture("rgba8").bmp).should eq want
    pixels(fixture("rgba16_i").bmp).should eq want
    pixels(fixture("rgb8_i").bmp).should eq opaque
    pixels(fixture("rgb16").bmp).should eq opaque
  end

  it "applies palette transparency" do
    bmp = fixture("pal8a_i").bmp
    bmp.flat_map(&.map(&.a)).uniq!.size.should be > 1
  end

  it "applies truecolor and grayscale colour-key transparency" do
    {"rgb8key", "gray8key_i", "gray4key"}.each do |name|
      bmp = fixture(name).bmp
      # The source's (0,0) pixel is black, the keyed colour.
      bmp[0][0].a.should eq 0
      bmp[6][8].a.should eq 255
    end
  end
end

describe "GIF fixtures" do
  it "decodes an interlaced GIF identically to its non-interlaced twin" do
    {"gif", "gif_short"}.each do |name|
      plain = fixture(name)
      inter = fixture("#{name}_i")
      PNGGIF::GIF.new(File.read(File.join(FIXTURES, "#{name}_i.gif")).to_slice).images.first.interlaced?.should be_true
      plain.width.should eq 9
      inter.height.should eq plain.height
      pixels(inter.bmp).should eq pixels(plain.bmp)
    end
    fixture("gif_short").height.should eq 3
    # gif.gif was written losslessly from the 60-colour pal8.png.
    pixels(fixture("gif").bmp).should eq pixels(fixture("pal8").bmp)
  end

  it "decodes a multi-frame GIF with sub-rectangle frames and disposal" do
    png = fixture("gif_anim")
    png.num_plays.should eq 2 # ImageMagick stores `-loop 3` as 2 repeats
    frames = png.frames.should_not be_nil
    frames.size.should eq 2
    frames[0].delay.should eq 100
    frames[0].dispose_op.should eq 1 # GIF "restore to background"
    frames[1].x_offset.should eq 3
    frames[1].y_offset.should eq 2
    frames[1].width.should eq 4
    frames[1].height.should eq 3
    frames[1].bmp.size.should eq 3

    cellmaps = png.animation_cellmaps(9, 7).should_not be_nil
    cellmaps.size.should eq 2
    second = cellmaps[1][0]
    second[0][0].a.should eq 0   # cleared by frame 0's disposal
    second[2][3].a.should eq 255 # covered by frame 1
    second[4][6].a.should eq 255
    second[5][3].a.should eq 0
  end
end
