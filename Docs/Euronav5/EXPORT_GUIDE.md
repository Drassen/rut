# iOS Export Guide

How to produce `USERN.tbl` + the three `.idx` files exactly as the planning
station does. The Python reference (`Euronav5 avkodning/analysis/euronav5.py`)
is the executable version of this recipe; it reproduces every reference
file byte-for-byte.

The iOS implementation is `Services/Export/Euronav5Encoder.swift`
(byte-exact Swift port of the Python reference; verified by
`Euronav5 avkodning/analysis/verify_swift.py`, which compiles the encoder
with `swiftc` and regenerates all 60 reference files byte-for-byte) plus
the thin adapter `Services/Export/Euronav5ExportService.swift` that maps
`VectorShape` onto encoder figures.

## Inputs the app must supply

Only genuine user content is input; every other byte is rule-derived.
Proven by regenerating **all 45 files of all 10 sets byte-exactly** from
nothing but this list (`verify_all.py`, "figure-level regeneration"):

| Input | Goes to | Notes |
|-------|---------|-------|
| Export timestamp | DATE*/TIME* fields | same value in every record of the export |
| Figure name | NAME | what the user typed (`l1`, `area5`, …) |
| Zone type | TYPE | empty, or `NAVIGATIONALZONE` / `DANGERZONE` / `PROHIBITEDZONE` / `RESTRICTEDZONE` |
| Zone ceiling | ELEVATION | metres; −1025 when not set |
| Layer choice | which USERN files | user picks layer 1–6 |
| Draw order | USEROBJECTID counter | the order figures were created in the session |

## Derived rules (do not ask the user for these)

### USEROBJECTID

Maintain one counter k = 1, 2, 3, … per export session, incremented for
**every** figure created, in creation order **across all layers**:

```
open polyline                      →  +k
closed polygon                     →  −k
single-record object (circle)     →   0   (k still consumed)
```

Verified on all 63 figures of the 10 sets (including the interleaved
multi-layer numbering of set1/set2) and consistent with production:
all 21 756 single-record obstacle points have 0, all 225 closed figures
are negative. Deleting a figure before export leaves a gap (counter
values are not reused — production shows such gaps).

### APPERANCE (style id) — from TYPE

| TYPE | APPERANCE |
|------|-----------|
| *(empty)* | 806 FDRAWING |
| NAVIGATIONALZONE | 802 FNAVIGATIONAL |
| DANGERZONE | 800 FDANGER |
| RESTRICTEDZONE | 803 FOPERATION |
| PROHIBITEDZONE | 806 FDRAWING |

Consistent in every reference figure. (Styles 801 FMISSION, 804 FSAR,
805 FWARNING exist in appMatrix but no set exercises them.)

**Appearance schemes — why a styled object can render white.** The
appMatrix `scheme` index (0–4) selects a style's look per lighting mode
(DAG/NATT/DIM0/DIM25/DIM50). A style id only renders in the schemes it is
defined for; in any other scheme the object falls back to plain white.
The helicopter rendered an exported USER layer using scheme 1, so a
scheme-0-only style (e.g. 524 OVNINGSSEKTOR, 534 KRAFTLEDNING RÖD) came out
white even though the user picked a colored style. Pick styles present in
**all five schemes** (272 of them) to render in every lighting mode. Full
detail and the scheme-by-scheme breakdown: APPMATRIX_SYM.md → "Appearance
schemes".

**Rendering caveats (decoded from appMatrix):** the F-zone styles are
muted by design — thin colored outline (800 red, 802 olive, 804 lilac,
805 blue, 806 khaki) with an opaque white polygon fill. 803 FOPERATION
and 801 FMISSION are all-white with visibility flags `[0,0,0,0]` —
effectively invisible. None of the F-styles has a point symbol
(`symbolId = -1`), so a point object with an F-style renders nothing;
point objects need a symbol style (POI 408, OBSTACLE 411, PERSON 412,
NO FLY 413, …).

**iOS app policy** (`Euronav5ExportService.appearance(for:kind:)`): the
user's style-picker choice (`dmgStyleClass`) is exported as APPERANCE
when set; otherwise defaults are chosen for visibility — points → 408
POI, RESTRICTEDZONE areas → 805 FWARNING (instead of the white 803), all
other lines/areas → the planner-faithful TYPE mapping above. The
encoder itself keeps the faithful mapping so the reference sets still
regenerate byte-exactly.

**Circles always carry a zone TYPE.** Every planner-made reference
circle has `TYPE=NAVIGATIONALZONE` (+ APPERANCE 802) — an empty-TYPE
circle is an unobserved combination. The iOS adapter therefore writes
the user's zone type, or `NAVIGATIONALZONE` when none is chosen, so the
encoder's TYPE mapping yields the planner's exact field values. Ring
radius is `RANGEDETECTION` (metres).

**Threat-range semantics** (point objects): `RANGELETHAL` = engagement/
kill radius (e.g. how far an air-defence site can shoot), `RANGEDETECTION`
= detection radius. The planner's threat point templates ("OUTHOUSE
10 NM" = 18 520 m, "FTG STOFF 6 NM" = 11 112 m) set RANGELETHAL; the
circle tool reuses RANGEDETECTION as a plain circle. Both rings are
drawn around a single point record and toggled in EuroNav via the
THREAT RANGES / Intervisibility display menu.

The card format has **no per-shape color fields** — in-app stroke/fill
colors cannot transfer; APPERANCE is the only rendering control.

### WARNINGSENSITIVE

Set to 1 exactly when ELEVATION is set, 0 otherwise — true for every
object in the corpus (10 sets + 22 000 production objects). Semantically
this is most likely the "warn when entering/approaching" flag for the
helicopter's warning system (the cards carry `OBST WARN ON/OFF` macros,
and every production obstacle has it set), with the planner requiring an
altitude for warnable objects. Treat it as elevation-coupled by default;
the reference implementation accepts an explicit override
(`figures_to_records(..., warning=...)`) if the planner UI turns out to
expose it separately.

### Everything else

LABEL = 1, DESCRIPTION/ATTACHMENT empty, SPEED/COURSE/CLASS/SOURCE = 0.
RANGEDETECTION = circle radius; on points the app's threat-range fields
are exported as RANGELETHAL / RANGEDETECTION (0 when not set).

## Recipe

### 1. Flatten figures to records

For each figure, in draw order; assign `ID` sequentially from 1 across the
whole file:

* polyline → one record per vertex
* polygon → one record per distinct vertex **+ repeat of the first vertex**
* circle → see note below

**Circles do not render natively.** A single-record circle with
`RANGEDETECTION = radius_m` (the planner's c1 encoding) draws **no ring**
on the helicopter at any radius — confirmed by on-hardware testing of a
dedicated circle card (radii 100 m–8 km, both range fields, with
intervisibility/THREAT RANGES enabled: nothing appeared). The iOS app
therefore **tessellates circles into polygon rings** (48 vertices) and
exports them as ordinary polygons, which render reliably. RANGEDETECTION
is left 0; the radius lives in the vertex geometry.

Coordinates: `round(degrees × 1_000_000)` as i32 LE. All records carry the
figure's shared fields (TBL_FORMAT.md record table).

### 2. Build the .tbl

1. Take the constant 3480-byte header template (copy from any set file or
   embed as a resource).
2. Patch `u32 @0x08 = ceil(recordCount / 16)` (min 1) and
   `u32 @0x68 = recordCount + 1`.
3. Append pages: each page `u32 0x100`, `u32 usedCount`, then 16 record
   slots (256 B each); zero-fill unused slots.

### 3. Build the three .idx files

Per INDEX_FORMAT.md. With ≤ 63 records (a 3-page table holds at most 48):

```
pairs(ID) = sorted (USEROBJECTID, ID)
pairs(LN) = sorted (LONGITUDE, ID)
pairs(OI) = (1,1) … (N,N)
```

Each file = 60-byte header (max key, min key, their row IDs, root = 60)
+ one 768-byte leaf node. Use the real B-tree algorithm if a layer can
ever exceed 63 records.

### 4. Write to card

```
db/SQL/USERN.tbl
db/SQL/USERN-ID.idx
db/SQL/USERN-LN.idx
db/SQL/USERN-OI.idx
```

Only write files for layers that contain figures (sets never ship empty
layers).

## Self-check before shipping

* `fileSize == 3480 + pageCount × 4104`
* `u32@0x68 == recordCount + 1`
* every record's ID is its 1-based position
* polygon figures end with a copy of their first vertex
* idx: `60 + nodes × 768`; in-order traversal = sorted pairs
* compare output against a set fixture with
  `Euronav5 avkodning/analysis/verify_all.py` style diffing
