# USER*.tbl — Vector Database File

Verified byte-exact against 22 files (10 test sets + production databases).
Reference encoder/decoder: `Euronav5 avkodning/analysis/euronav5.py`.

All integers are **little-endian** unless stated otherwise.

## File layout

```
offset 0        3480-byte header  (constant template except two u32 fields)
offset 3480     page 0            4104 bytes
offset 7584     page 1            4104 bytes
...
fileSize = 3480 + pageCount × 4104
```

Observed sizes: 7584 (1 page), 11688 (2), 15792 (3), …, 6 721 728 (1637 pages).

## Header (3480 bytes)

The header is a self-describing schema. In practice: **copy the 3480-byte
header from any reference set verbatim and patch exactly two fields.**

| Offset | Type | Value | Meaning |
|--------|------|-------|---------|
| 0x00 | u8  | 0x03 | format version (constant) |
| 0x01 | u8  | 0x18 = 24 | number of columns |
| 0x02 | u16 | 0x1008 = 4104 | page size |
| 0x04 | u16 | 0x0100 = 256 | record size |
| 0x06 | u16 | 0 | — |
| **0x08** | **u32** | **pageCount** | ← patch per export |
| 0x0c | u32 | 0x00036660 | constant, meaning unknown (copy verbatim) |
| 0x10 | — | 24 × 96-byte column descriptors | constant for USER tables |
| **0x68** | **u32** | **recordCount + 1** | next row id (inside first descriptor's metadata area) ← patch per export |
| 0x910 | — | zeros | reserved |
| 0xc10 | — | index directory | constant (see below) |
| 0xc70–0xd97 | — | zeros | reserved |

Note: 0x68 physically lies inside the USEROBJECTID column descriptor
(0x10–0x6f, metadata bytes). It is the table's auto-increment counter and
always equals `recordCount + 1` in every reference file.

### Column descriptors (96 bytes each, at 0x10)

`name[64]` (ASCII, NUL-padded) + `meta[32]`. In `meta`: `u16` declared size
at +28 (strings only) and `u16` type code at +30.

Type codes: 1 = u8, 2 = u16, 3 = i32, 5 = i32 coordinate (microdegrees),
6 = f64, 7 = string of declared size + 1 NUL byte.

### Index directory (constant, at 0xc10)

Three 28-byte entries — `name[24]` + `u32` — declaring the companion
indexes: `"OI"`,1 · `"ID"`,9 · `"LN"`,0x71. The u32 meaning is unknown
(constant in all files; copy verbatim).

## Pages (4104 bytes)

```
+0x00  u32  record size (always 0x100)
+0x04  u32  number of used record slots in this page (0–16)
+0x08  16 × 256-byte record slots
```

Records fill pages in order; every page except the last has 16 used slots.
**Unused slots are completely zero-filled.** A table with 0 records still
has 1 page (observed in `full_db` USER1/3/4/5).

## Record layout (256 bytes)

The 24 schema columns packed in order. Strings occupy declared size + 1
NUL terminator and are zero-padded.

| Offset | Type | Column | Semantics (observed) |
|--------|------|--------|----------------------|
| 0x00 | i32 | ID | row number, 1-based, sequential over the whole file |
| 0x04 | i32 | USEROBJECTID | figure id, fully rule-derived: session counter k = 1,2,3,… per created figure; open polyline → **+k**, closed polygon → **−k**, single-record object (circle, obstacle point) → **0** (slot still consumed). Verified on all 10 sets + production (see EXPORT_GUIDE) |
| 0x08 | u16 | DATEDAYS | day of month |
| 0x0a | u16 | DATEMONTHS | month 1–12 |
| 0x0c | u16 | DATEYEARS | year (e.g. 2026) |
| 0x0e | u16 | TIMESECONDS | second |
| 0x10 | u16 | TIMEMINUTES | minute |
| 0x12 | u16 | TIMEHOURS | hour |
| 0x14 | char[21] | TYPE | zone type, plain ASCII: `NAVIGATIONALZONE`, `DANGERZONE`, `PROHIBITEDZONE`, `RESTRICTEDZONE`; empty for plain drawings |
| 0x29 | char[21] | NAME | figure name as typed by the user (`draw`, `area5`, `l1`, …) |
| 0x3e | char[129] | DESCRIPTION | observed empty |
| 0xbf | i32 | LABEL | observed 1 (label on) |
| 0xc3 | i32 | APPERANCE | appMatrix style id: 800 FDANGER, 802 FNAVIGATIONAL, 803 FOPERATION, 806 FDRAWING observed |
| 0xc7 | i32 | LATITUDE | microdegrees = `round(deg × 1 000 000)` |
| 0xcb | i32 | LONGITUDE | microdegrees |
| 0xcf | i32 | ELEVATION | metres; **−1025 = not set**; zone ceiling otherwise (3048/4572/6096 m = 10/15/20 kft observed) |
| 0xd3 | i32 | RANGELETHAL | threat engagement radius in metres (e.g. SAM kill range) — used by the planner's threat point templates ("OUTHOUSE 10 NM" = 18 520 m); 0 in all drawn-figure reference data |
| 0xd7 | i32 | RANGEDETECTION | threat detection radius in metres; the planner's circle tool reuses this as the **plain circle radius** (circle figures), else 0 |
| 0xdb | char[16] | ATTACHMENT | observed empty |
| 0xeb | f64 | SPEED | observed 0.0 |
| 0xf3 | i32 | COURSE | observed 0 |
| 0xf7 | u8 | WARNINGSENSITIVE | warning-system flag (likely feeds the helicopter's obstacle/zone warning — cf. the `OBST WARN ON/OFF` macros on the cards). In all 22 000+ reference objects it equals `ELEVATION != −1025` |
| 0xf8 | i32 | CLASS | observed 0 |
| 0xfc | i32 | SOURCE | observed 0 |

The date/time fields hold the export timestamp; identical in all records
written in one session.

## Figure encoding

One record per vertex. All records of a figure are consecutive, share
USEROBJECTID/NAME/TYPE/APPERANCE/timestamp, and differ only in ID and
coordinates.

| Shape | Records |
|-------|---------|
| Polyline, n points | n records |
| Polygon, n distinct vertices | n + 1 records — **first vertex repeated as the last record** |
| Circle | 1 record: center coordinates + RANGEDETECTION = radius (m) |

There is no separate "figure header" record and no point index — the old
documentation's header/point model was wrong.

## Layer files

`USER1.tbl` … `USER6.tbl` all use the identical schema. The planning
station distributes figures over layers as the user chooses; production
databases keep their data in USER6. A set only contains files for layers
that have content.
