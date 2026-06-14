# appMatrix.json and .sym Files

Rendering support data. These are **read** by the app (map rendering of
imported overlays); the iOS app does not need to generate them. Reference
copies live in `Supporting Files/euronav5/` and on the cards under
`db/settings/system/`.

## appMatrix.json — style catalog

Verified structure (counted from `full_db/db/settings/system/appMatrix.json`):

```json
{ "version": 1,
  "member": [ [[scheme, styleId], [name, [flags...], [state...], ...]], ... ] }
```

* 1675 members; 585 distinct style ids; scheme ∈ {0,1,2,3,4}.
* `member[i][0]` = `[scheme, styleId]`; `member[i][1][0]` = style name.

### Appearance schemes (the `scheme` index 0–4) — important

The first number in `member[i][0]` is **not** a draw layer; it is the
**appearance/brightness scheme**. The cards carry exactly five display
macros — `DAG` (day), `NATT` (night), `DIM0`, `DIM25`, `DIM50` — and their
scripts open the *Appearance Editor / Brightness Setup*. These five schemes
correspond to the five `scheme` values 0–4. The catalog repeats each style
once per scheme, so a style can look different (or be absent) depending on
the lighting mode the crew has selected.

Consequences, verified against the catalog:

* A style id is **only rendered in the schemes it has an entry for.** If
  the active scheme has no entry, the object falls back to **plain white**
  (white fill / white line, no symbol) — this is the cause of the
  "everything white" export bug, see EXPORT_GUIDE.md.
* Coverage breakdown: **272 styles exist in all 5 schemes** (always render,
  identical in 195 of them, lightly tweaked per scheme in 77 — mostly
  scheme 1, then scheme 3). **62 styles exist only in scheme 0**, **249
  only in scheme 1**, 2 in schemes {0,1}.
* The same visual concept is often duplicated as **different style ids in
  different schemes**. Examples:

  | Concept | scheme-0 id | scheme-1 id | all-5 id |
  |---------|-------------|-------------|----------|
  | OVNINGSSEKTOR | 524 | 76 | — |
  | LÅGFLYGOMRÅDE | 535 | 78 | — |
  | KRAFTLEDNING RÖD | 534 | 273 | — |
  | ATZ | 520 | 70 | — |
  | FIR / TIA / TIZ | 540 / 537 / 538 | 72 / 73 / 74 | — |
  | CTR CTZ | — | — | 617 |
  | MCTR | — | — | 618 |
  | WARNING ZONE | — | — | 932 |
  | FDANGER … FDRAWING | — | — | 800–806 |

* On-hardware testing settled this: the helicopter renders an exported
  iOS `USER4.tbl` in an appearance scheme that contains **only the styles
  present in all five schemes** (the 272 set). Styles defined in just one
  scheme render as plain white — confirmed both ways: scheme-0-only
  (524 OVNINGSSEKTOR) *and* scheme-1-only (76 OVNINGSSEKTOR) both failed,
  while all-5 styles (799 KOSIF, 435 SYM 10, 805 FWARNING) rendered. By the
  catalog structure this active scheme is one of 2/3/4 (those contain
  exactly the 272 all-5 styles). The earlier "scheme 1" guess was wrong.

**Refinement (point symbols vs line/area color).** Further on-hardware
testing — a 183-glyph catalog card — showed that **point symbols render
regardless of scheme**: all 183 distinct glyphs appeared, including the
122 reachable only through scheme-0-only or scheme-1-only styles. Only the
**line stroke and polygon fill colour** are scheme-dependent (those revert
to white when the style is absent from the active scheme). So:

| Geometry | What renders | Scheme requirement |
|----------|--------------|--------------------|
| Point | the style's glyph | none — any symbol style works |
| Line | colored stroke | style must be in all 5 schemes |
| Polygon / circle | colored border / fill | style must be in all 5 schemes |

`Services/StyleSelectorModal.swift` filters accordingly: points → any
style with a symbol (≈330); lines → all-5 styles with a colored stroke
(≈128); polygons/circles → all-5 styles with a colored border or fill
(≈132). (The earlier all-5-only restriction for points was too strict;
550 POI AUTO SVC / glyph 286 does render — the single app-export miss of
it was unrelated to glyph or scheme.)

**Colours are read from the active scheme, not scheme 0.** A style can
have a *different* colour per scheme — sometimes a full hue change, e.g.
247 LINE WRN 2 is red in scheme 0 but blue in scheme 2/3/4; 611 TMA blue→
yellow; 235 POWER LINEWRN near-white→black. Since the helicopter renders
the iOS database in scheme 2/3/4, the picker reads each style's colour
(and evaluates the colored-line/fill filter) from the **active scheme
(2)** so the preview matches the display and the filter keeps the right
styles. (Schemes 2/3/4 are near-identical; the exact one corresponds to
the crew's DAG/NATT/DIM mode.)

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
