# pnggif

Pure-Crystal **PNG / APNG / GIF** reader, and **PNG / APNG** writer.

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
- **Encoding**: still **PNG** and animated **APNG** written in-process, no
  external tools (see below).

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

## Encoding

The shard also writes PNG and APNG, pure-Crystal (stdlib `Compress::Zlib` and
`Digest::CRC32` only):

```crystal
bytes = PNGGIF.encode_png(bmp)                  # bmp : Array(Array(PNGGIF::Pixel))
bytes = PNGGIF.encode_apng(frames, num_plays: 0) # frames : Array({Bitmap, delay_ms})
```

Both have `(…, io : IO)` overloads for writing straight to a file or stream.
Output is always truecolor + alpha (color type 6, 8-bit), matching the
in-memory `Bitmap` format, so no quantization happens. `encode_apng` emits a
spec-correct animation (`acTL`/`fcTL`/`fdAT`); the first frame doubles as the
still `IDAT`, so non-APNG viewers show it. `num_plays: 0` loops forever.
Round-trips through the shard's own decoder (`PNGGIF::PNG#frames`).

Current limitations, chosen for simplicity:

- **Not streaming**: `encode_apng` takes all frames up front (`acTL` carries
  the frame count and precedes the frames). Long recordings buffer every raw
  bitmap in memory; a streaming variant would need a seekable IO to patch
  `acTL`, or buffering of the (much smaller) compressed chunks.
- **No inter-frame optimization**: every frame is a full-canvas `fdAT` with
  scanline filter 0 (dispose NONE / blend SOURCE), and all frames must match
  the first frame's canvas size. Files are therefore larger than what
  optimizing encoders (e.g. ffmpeg) produce via sub-rectangle diffs and
  filter selection.
- **Duplicate frames are the caller's job**: identical consecutive frames are
  encoded again in full. When capturing mostly-static content, fold repeats
  by extending the previous frame's `delay_ms` instead of appending a frame.

There is no GIF or JPEG encoder — for those, pipe frames to an external
encoder instead.

## License

AGPLv3
