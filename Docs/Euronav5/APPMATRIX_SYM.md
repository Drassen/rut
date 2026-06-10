# appMatrix.json and .sym Files

Rendering support data. These are **read** by the app (map rendering of
imported overlays); the iOS app does not need to generate them. Reference
copies live in `Supporting Files/euronav5/` and on the cards under
`db/settings/system/`.

## appMatrix.json — style catalog

Verified structure (counted from `full_db/db/settings/system/appMatrix.json`):

```json
{ "version": 1,
  "member": [ [[layer, styleId], [name, [flags...], [state...], ...]], ... ] }
```

* 1675 members; 585 distinct style ids; layer ∈ {0,1,2,3,4}
  (5 visualization layers / display modes — each style id can appear once
  per layer).
* `member[i][0]` = `[layer, styleId]`; `member[i][1][0]` = style name.

Style ids relevant for user figures (APPERANCE column in USER tables):

| Id | Name |
|----|------|
| 800 | FDANGER |
| 801 | FMISSION |
| 802 | FNAVIGATIONAL |
| 803 | FOPERATION |
| 804 | FSAR |
| 805 | FWARNING |
| 806 | FDRAWING |

Observed pairings in the test sets: plain drawings → 806; DANGERZONE → 800;
NAVIGATIONALZONE → 802; RESTRICTEDZONE → 803. (PROHIBITEDZONE appeared with
806 in the sets — the planner does not enforce a TYPE↔style coupling.)

The per-state payload (colors RGBA arrays, line weight/dash bitmask,
symbol id, text styling such as `ePosTop`/`eTextRectangle`) is interpreted
by the app's working parser — see `Services/Style.swift`, which is the
authoritative reference for the state layout the app relies on. Field
semantics beyond what `Style.swift` consumes are not independently
verified.

## *.sym — symbol glyph bitmaps

Files `0.sym`–`3.sym`, each exactly 133 120 bytes:

```
0x0000  glyph directory: 128 slots × 16 bytes (unused slots all-zero)
0x0800  bitmap: 256 × 256 pixels × 2 bytes = 131 072 bytes
```

Directory entry (verified layout):

| Offset | Type | Field |
|--------|------|-------|
| +0 | u32 | glyph id (e.g. 37–63, 0x8000+ for special glyphs) |
| +4 | u16 | cell top row (y0) |
| +6 | u16 | cell left column (x0) |
| +8 | u16 | cell bottom row (y1) |
| +10 | u16 | cell right column (x1) |
| +12 | u16 | glyph width |
| +14 | u16 | glyph height |

Glyphs sit in a grid of cells inside the 256×256 atlas; `3.sym` contains
27 glyphs. The two bytes per pixel select primary/secondary coloring —
the app's working extractor `Services/GlyphBitmapExtractor.swift` is the
reference for pixel interpretation (not independently re-verified).
