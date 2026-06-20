# pnggif

Pure-Crystal **PNG / APNG / GIF** reader.

It decodes an image file (or in-memory buffer) into RGBA bitmaps and, optionally,
a downscaled **terminal-cell map** suitable for solid-block rendering in a TUI
(one cell per sampled pixel, the cell background set to the pixel color).

Ported from [Blessed](https://github.com/chjj/blessed)'s bundled
[`tng.js`](https://github.com/chjj/tng) (MIT).

## Features

- **PNG**: all color types (grayscale, RGB, palette, gray+alpha, RGBA), bit
  depths 1–16, all scanline filters, Adam7 interlacing, palette transparency.
  Decompression uses Crystal's stdlib `Compress::Zlib`.
- **APNG**: animation frames with dispose/blend compositing.
- **GIF** (87a/89a): ported LZW decoder, interlacing, transparency, NETSCAPE
  loop counts, multi-frame animation.
- **JPEG / other**: converted to PNG via ImageMagick `convert` when available.
- **Cellmaps**: nearest-neighbour downscaling with non-square-cell **aspect
  correction** (`cell_aspect`, default `2.0`) so images don't look stretched.

## Usage

```crystal
require "pnggif"

img = PNGGIF::PNG.new("picture.png", cell_width: 40)

img.width        # => image pixel width
img.height       # => image pixel height
img.bmp          # => Array(Array(PNGGIF::Pixel)), full-resolution RGBA
img.cellmap      # => downscaled bitmap, one PNGGIF::Pixel per terminal cell
img.frames       # => Array(PNGGIF::Frame)? for animations, else nil

# Pre-composited animation frames ({cellmap, delay_ms}):
if frames = img.animation_cellmaps(40)
  frames.each { |cellmap, delay_ms| ... }
end
```

Each `PNGGIF::Pixel` has `r`, `g`, `b`, `a` channels (0–255).

## License

AGPLv3
