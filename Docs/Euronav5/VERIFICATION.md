# Verification

How this documentation was validated, and what remains unproven.
Date: 2026-06-10.

## Method

The spec was *re-derived from the binaries*, not inherited from earlier
notes (the earlier notes turned out to be largely wrong — see README
historical note). The proof is constructive: a Python implementation
parses every reference file into semantic values and **regenerates the
file byte-for-byte** from those values alone. Any byte the model failed to
explain would break the round-trip.

Code: `Euronav5 avkodning/analysis/`
* `euronav5.py` — parser + byte-exact generator for `.tbl` and `.idx`
* `verify_all.py` — full check suite (run: `python3 verify_all.py`)

## Reference data

| Source | Contents |
|--------|----------|
| `set1`–`set10` | planner exports, 3–39 records, layers USER2–USER5, with input geojson for set1–set3 |
| `full_db` | complete production card incl. USER6 with 17 397 records |
| `vector map data` | second production card, USER6 with 26 184 records |

## Results

| Check | Result |
|-------|--------|
| `.tbl` parse→rebuild round-trip | 22/22 files byte-exact (incl. 6.7 MB USER6) |
| Header constant except 0x08/0x68 | 22/22 |
| Unused record slots all-zero | all files |
| `0x68 == recordCount + 1` | all files |
| `.idx` rebuilt from `.tbl` only | 48/48 files byte-exact |
| B-tree algorithm incl. node allocation order and slot-63 quirk | reproduces 643 kB / 466 kB / 648 kB production trees exactly |
| geojson ↔ records (set1–set3) | every feature matches; coords = `round(deg×1e6)` |
| **Figure-level regeneration** (planner emulation) | all 45 files of all 10 sets byte-exact from geometry + user inputs only — USEROBJECTID, APPERANCE, WARNINGSENSITIVE, IDs, pages, indexes all rule-derived |
| USEROBJECTID rule (±counter / 0) | 63/63 set figures; production: 21 756 × 0 = single-record, 225 × negative = closed, no exception |
| TYPE→APPERANCE mapping | consistent in all drawn figures |
| WARNINGSENSITIVE = (ELEVATION set) | 100% of corpus (sets + production) |
| appMatrix counts (1675 / 585 / 5 layers) | confirmed |
| `.sym` size & directory layout | 4/4 files |

## What "byte-identical export" requires

Given the figure geometry plus the genuine user inputs (timestamp, names,
zone types, elevations, layer, draw order), **every byte of all four files
is determined** — including USEROBJECTID, which follows the
counter/sign/zero rule in EXPORT_GUIDE.md. The figure-level regeneration
check proves this end to end for all 10 sets.

## Open questions

Unproven items, kept here on purpose instead of inside the spec:

1. **Helicopter acceptance envelope.** All claims are "matches what the
   planner writes". Which deviations the helicopter tolerates (e.g. TYPE
   strings it doesn't know, nonzero DESCRIPTION) is untested — no
   Euronav5 card has been helicopter-tested yet (`PCMCIA avkodning/`
   testing covered the six route files, not vector overlays).
1b. **Unobserved TYPE values.** The TYPE→APPERANCE table covers the five
   observed types. appMatrix also has FMISSION (801), FSAR (804),
   FWARNING (805); the planner presumably writes matching TYPE strings
   for those zone kinds, but no reference set exercises them.
1c. **WARNINGSENSITIVE independence.** It may be a user-settable
   "warn when entering this zone" flag; in all reference data it tracks
   ELEVATION exactly, so the coupling is the safe default. Only a planner
   experiment (zone with warning but no altitude, or vice versa) can
   separate the two.
2. **File-header u32 @0x0c** (`0x00036660`): constant in every USER table;
   meaning unknown. Copy verbatim.
3. **Index directory values** (`OI`=1, `ID`=9, `LN`=0x71 at 0xc10): constant;
   encoding unknown. Copy verbatim.
4. **Idx header u16 pair (3,3)** at 0x00: constant; meaning unknown.
5. **Empty-table .idx** (60-byte variant in `full_db`, 2017–2022 relics):
   written by an older tool; header fields differ (e.g. 2 at 0x20). Don't
   ship empty layers and this never arises.
6. **Field value ranges**: DESCRIPTION, ATTACHMENT, SPEED, COURSE, CLASS,
   SOURCE, RANGELETHAL are 0/empty in every reference record; LABEL is
   always 1. Behaviour with other values unobserved.
7. **WARNINGSENSITIVE/ELEVATION coupling**: set1 zones have both set;
   sets 8–10 zone-typed figures have neither. Which combinations the
   planner UI can produce is unknown.
8. **`.sym` pixel byte semantics** (primary/secondary color mapping):
   taken from the app's working extractor, not re-verified here.
9. **appMatrix state payload details** beyond what `Services/Style.swift`
   parses.
