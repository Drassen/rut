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

LABEL = 1, DESCRIPTION/ATTACHMENT empty, SPEED/COURSE/CLASS/SOURCE/
RANGELETHAL = 0, RANGEDETECTION = circle radius (else 0).

## Recipe

### 1. Flatten figures to records

For each figure, in draw order; assign `ID` sequentially from 1 across the
whole file:

* polyline → one record per vertex
* polygon → one record per distinct vertex **+ repeat of the first vertex**
* circle → one record, center coords, `RANGEDETECTION = radius_m`

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
