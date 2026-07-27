module PNGGIF
  # Generic raster utilities over `PNGGIF::Bitmap`/row-major grids: palette
  # quantization with dithering, run-length scanning, RGBA flattening and
  # alpha compositing. Nothing here is terminal- or toolkit-specific; these
  # are the building blocks any consumer rendering bitmaps to a constrained
  # target (palette device, byte stream, cell grid) needs.
  module Raster
    # 4×4 Bayer ordered-dither matrix (values 0..15).
    BAYER_MATRIX = [
      [0, 8, 2, 10],
      [12, 4, 14, 6],
      [3, 11, 1, 9],
      [15, 7, 13, 5],
    ]

    # How an image's colors are dithered when reduced to a smaller palette
    # than the source.
    #
    # Dithering trades spatial resolution for perceived color depth: instead
    # of snapping each pixel to its nearest palette entry (which bands
    # gradients), it scatters the two nearest entries so the eye averages
    # them back to the in-between color.
    enum Dither
      None      # snap to the nearest palette entry — cleanest, but bands gradients
      Ordered   # 4×4 Bayer ordered dither — deterministic per pixel, so frame-stable
      Diffusion # Floyd–Steinberg error diffusion — best for a still; shimmers if animated
      Auto      # Diffusion for a still image, Ordered for an animation (default)

      # Collapses `Auto` to a concrete method: error diffusion looks best on a
      # still, but its irregular stipple shimmers across frames, so an animated
      # source falls back to the frame-stable ordered dither.
      def resolve(animated : Bool) : Dither
        return self unless auto?
        animated ? Ordered : Diffusion
      end
    end

    # Quantizes an RGBA *bmp* (*pw*×*ph*) to one value per pixel, applying the
    # requested *dither*.
    #
    # The block is invoked once per opaque pixel with the channels to quantize
    # and an ordered-dither threshold *t* (Bayer offset in `[-0.5, 0.5)` for
    # `Ordered`, else `0.0`); it must return `{value, qr, qg, qb}` — the stored
    # value (palette index or packed `0xRRGGBB`) plus the RGB it resolves to, so
    # `Diffusion` can spread the residual onto not-yet-visited neighbours. Fully
    # transparent pixels (`a == 0` or missing) are assigned *transparent* and
    # never reach the block. *animated* collapses `Dither::Auto`.
    #
    # *into*, when non-nil and already sized *ph* rows × *pw* wide, is reused as
    # the output grid, avoiding a per-frame allocation; every cell is assigned on
    # every pass, so no stale value can survive. Only a caller that re-encodes
    # per frame may pass a persistent scratch here — a caller that caches the
    # returned grid must leave it nil.
    def self.dither_rgb(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32,
                        dither : Dither, animated : Bool, transparent : V,
                        into : Array(Array(V))? = nil,
                        & : Int32, Int32, Int32, Float64 -> Tuple(V, Int32, Int32, Int32)) : Array(Array(V)) forall V
      mode = dither.resolve(animated)
      diffuse = mode.diffusion?
      # Per-channel Floyd–Steinberg error carried to the current and next scan
      # line, as a two-row sliding window rather than a full-image buffer. Only
      # diffusion needs them; ordered/none leave them empty so an ordered frame
      # doesn't allocate six pw-wide scratch rows it never reads.
      dsize = diffuse ? pw : 0
      cur_r = Array(Float64).new(dsize, 0.0); cur_g = Array(Float64).new(dsize, 0.0); cur_b = Array(Float64).new(dsize, 0.0)
      nxt_r = Array(Float64).new(dsize, 0.0); nxt_g = Array(Float64).new(dsize, 0.0); nxt_b = Array(Float64).new(dsize, 0.0)

      reuse = !into.nil? && grid_fits?(into, pw, ph)
      out = (reuse ? into : nil) || Array(Array(V)).new(ph)
      ph.times do |y|
        rin = bmp[y]
        row = reuse ? out.unsafe_fetch(y) : Array(V).new(pw, transparent)
        pw.times do |x|
          px = rin[x]?
          if px.nil? || px.a == 0
            row[x] = transparent
            next
          end
          if diffuse
            wr = px.r + cur_r[x]; wg = px.g + cur_g[x]; wb = px.b + cur_b[x]
            value, qr, qg, qb = yield wr.round.to_i, wg.round.to_i, wb.round.to_i, 0.0
            row[x] = value
            er = wr - qr; eg = wg - qg; eb = wb - qb
            if x + 1 < pw
              cur_r[x + 1] += er * 7.0 / 16.0; cur_g[x + 1] += eg * 7.0 / 16.0; cur_b[x + 1] += eb * 7.0 / 16.0
              nxt_r[x + 1] += er * 1.0 / 16.0; nxt_g[x + 1] += eg * 1.0 / 16.0; nxt_b[x + 1] += eb * 1.0 / 16.0
            end
            nxt_r[x] += er * 5.0 / 16.0; nxt_g[x] += eg * 5.0 / 16.0; nxt_b[x] += eb * 5.0 / 16.0
            if x > 0
              nxt_r[x - 1] += er * 3.0 / 16.0; nxt_g[x - 1] += eg * 3.0 / 16.0; nxt_b[x - 1] += eb * 3.0 / 16.0
            end
          else
            t = mode.ordered? ? (BAYER_MATRIX[y & 3][x & 3] + 0.5) / 16.0 - 0.5 : 0.0
            value, _qr, _qg, _qb = yield px.r, px.g, px.b, t
            row[x] = value
          end
        end
        out << row unless reuse
        # Next line's accumulated error becomes the current line's; reuse the
        # drained buffers as the new (zeroed) next line. No-ops for the empty
        # ordered/none buffers.
        cur_r, nxt_r = nxt_r, cur_r; cur_g, nxt_g = nxt_g, cur_g; cur_b, nxt_b = nxt_b, cur_b
        nxt_r.fill(0.0); nxt_g.fill(0.0); nxt_b.fill(0.0)
      end
      out
    end

    # Rec.709 relative luminance of *px* (`0.2126·R + 0.7152·G + 0.0722·B`), in
    # the channels' own 0..255 scale. Callers fold alpha/scale in themselves.
    def self.luminance(px : PNGGIF::Pixel) : Float64
      0.2126 * px.r + 0.7152 * px.g + 0.0722 * px.b
    end

    # Clamps *v* into the `0..255` byte range.
    def self.clamp8(v : Int32) : Int32
      v < 0 ? 0 : (v > 255 ? 255 : v)
    end

    # Index of the nearest entry in *palette* (packed `0xRRGGBB` values) to
    # *r*,*g*,*b* by squared RGB distance; ties go to the lower index.
    def self.nearest_index(palette : Array(Int32), r : Int32, g : Int32, b : Int32) : Int32
      best = 0
      bestd = Int32::MAX
      i = 0
      n = palette.size
      while i < n
        rgb = palette.unsafe_fetch(i)
        dr = r - ((rgb >> 16) & 0xff)
        dg = g - ((rgb >> 8) & 0xff)
        db = b - (rgb & 0xff)
        d = dr*dr + dg*dg + db*db
        if d < bestd
          bestd = d
          best = i
        end
        i += 1
      end
      best
    end

    # Scans a *row* of *width* values into maximal runs of equal adjacent
    # values, yielding each run's value, start column, and length.
    def self.each_run(row : Indexable(T), width : Int32, & : T, Int32, Int32 ->) forall T
      x = 0
      while x < width
        v = row[x]
        rl = 1
        while x + rl < width && row[x + rl] == v
          rl += 1
        end
        yield v, x, rl
        x += rl
      end
    end

    # Dimensions `{w, h}` of a row-major 2D grid *bmp* (`bmp.size` rows, each
    # `bmp[0].size` wide; `{0, 0}` if empty). Generic, so it covers both a
    # `PNGGIF::Bitmap` and other row-major grids.
    def self.dims(bmp : Array(Array(T))) : Tuple(Int32, Int32) forall T
      h = bmp.size
      w = h > 0 ? bmp[0].size : 0
      {w, h}
    end

    # Whether *grid* already measures exactly *w*×*h*. The canonical spelling of
    # the "can I reuse this scratch buffer?" guard for per-frame encode fast
    # paths — a hand-written copy with the wrong polarity either silently
    # disables reuse or fills an undersized grid in place.
    def self.grid_fits?(grid : Array(Array(T)), w : Int32, h : Int32) : Bool forall T
      grid.size == h && (grid[0]?.try(&.size) || 0) == w
    end

    # Unpacks a packed `0xRRGGBB` color into its `{r, g, b}` byte channels.
    # Inlined because dither callers use it per pixel: it lets LLVM scalarize
    # the intermediate tuple away.
    @[AlwaysInline]
    def self.rgb24(v : Int32) : Tuple(Int32, Int32, Int32)
      {(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff}
    end

    # Flattens *bmp* to raw interleaved RGBA bytes (`w*h*4`) — the format
    # ffmpeg ingests as `-f rawvideo -pixel_format rgba`, and a common
    # interchange payload generally.
    def self.rgba(bmp : PNGGIF::Bitmap) : Bytes
      h = bmp.size
      w = h > 0 ? bmp[0].size : 0
      buf = Bytes.new(w * h * 4)
      i = 0
      bmp.each do |row|
        row.each do |px|
          buf[i] = px.r.to_u8!
          buf[i + 1] = px.g.to_u8!
          buf[i + 2] = px.b.to_u8!
          buf[i + 3] = px.a.to_u8!
          i += 4
        end
      end
      buf
    end

    # Alpha-blends *bmp* onto *canvas* with its top-left at pixel (*ox*,*oy*),
    # clipping to the canvas bounds. The result is fully opaque where written.
    def self.composite(canvas : PNGGIF::Bitmap, bmp : PNGGIF::Bitmap, ox : Int32, oy : Int32) : Nil
      ph = canvas.size
      pw = ph > 0 ? canvas[0].size : 0
      bmp.size.times do |y|
        cy = oy + y
        next if cy < 0 || cy >= ph
        srow = bmp[y]
        drow = canvas[cy]
        srow.size.times do |x|
          cx = ox + x
          next if cx < 0 || cx >= pw
          sp = srow.unsafe_fetch(x)
          a = sp.a
          next if a <= 0
          if a >= 255
            drow[cx] = PNGGIF::Pixel.new(sp.r, sp.g, sp.b, 255)
          else
            dp = drow.unsafe_fetch(cx)
            ia = 255 - a
            drow[cx] = PNGGIF::Pixel.new(
              (sp.r * a + dp.r * ia) // 255,
              (sp.g * a + dp.g * ia) // 255,
              (sp.b * a + dp.b * ia) // 255,
              255)
          end
        end
      end
    end
  end
end
