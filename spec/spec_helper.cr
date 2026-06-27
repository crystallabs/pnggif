require "spec"

require "../src/pnggif"

# Builds a `PNGGIF::Bitmap` (rows of `Pixel`, `bmp[y][x]`) of size *w*×*h* whose
# every channel varies with the coordinates, so a round-trip test that compares
# pixels also catches row/column transposition or off-by-one packing bugs.
def sample_bitmap(w : Int32, h : Int32) : PNGGIF::Bitmap
  bmp = PNGGIF::Bitmap.new(h)
  h.times do |y|
    row = Array(PNGGIF::Pixel).new(w)
    w.times do |x|
      row << PNGGIF::Pixel.new((x * 17) % 256, (y * 31) % 256, (x + y) % 256, 255)
    end
    bmp << row
  end
  bmp
end

# Builds a solid-color `PNGGIF::Bitmap` of size *w*×*h*.
def solid_bitmap(w : Int32, h : Int32, r : Int32, g : Int32, b : Int32, a : Int32 = 255) : PNGGIF::Bitmap
  bmp = PNGGIF::Bitmap.new(h)
  h.times do
    row = Array(PNGGIF::Pixel).new(w)
    w.times { row << PNGGIF::Pixel.new(r, g, b, a) }
    bmp << row
  end
  bmp
end

# A real, minimal 1×1 GIF89a (the widely-used 43-byte transparent pixel). Its
# 2-entry global color table is {black, white}, the single pixel uses index 0,
# and the graphic-control extension marks index 0 as transparent — so the
# decoded pixel is fully transparent black. Used to exercise the GIF/LZW path
# without depending on an external fixture file.
TRANSPARENT_GIF = Bytes[
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, # "GIF89a"
  0x01, 0x00, 0x01, 0x00,             # 1×1 logical screen
  0x80, 0x00, 0x00,                   # GCT flag, bg index, aspect
  0x00, 0x00, 0x00, 0xff, 0xff, 0xff, # GCT: black, white
  0x21, 0xf9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, # graphic control: transparent idx 0
  0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, # image descriptor 1×1
  0x02, 0x02, 0x44, 0x01, 0x00,       # LZW min code 2, data, terminator
  0x3b,                               # trailer
]
