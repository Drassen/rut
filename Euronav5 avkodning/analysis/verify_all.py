"""
Full verification suite for the Euronav5 format documentation.

Re-derives every claim in Docs/Euronav5/ from the reference data in
"Euronav5 avkodning/" and reports PASS/FAIL. Run from this directory:

    python3 verify_all.py
"""
import glob
import json
import struct
import sys

import euronav5 as e5

FAILS = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")
    if not ok:
        FAILS.append(name)


SET_TBLS = sorted(glob.glob("../set*/db/SQL/USER*.tbl"))
ALL_TBLS = (SET_TBLS
            + sorted(glob.glob("../full_db/db/SQL/USER[1-6].tbl"))
            + ["../vector map data/db/SQL/USER6.tbl"])

# 1. Every USER .tbl round-trips byte-exactly through parse + rebuild
template = open(SET_TBLS[0], 'rb').read(e5.HDR_SIZE)
for f in ALL_TBLS:
    p = e5.parse_tbl(f)
    rebuilt = e5.build_tbl(p['records'], template)
    check(f"tbl roundtrip {f}", rebuilt == p['data'],
          f"{len(p['records'])} records")

# 2. Header is constant except 0x08 (page count) and 0x68 (recordCount+1)
base = template
for f in ALL_TBLS:
    h = open(f, 'rb').read(e5.HDR_SIZE)
    diff = {i for i in range(e5.HDR_SIZE) if h[i] != base[i]}
    check(f"hdr constant {f}", diff <= {0x08, 0x09, 0x68, 0x69})

# 3. Every index file rebuilds byte-exactly from its .tbl (incl. B-trees)
IDX_SRC = SET_TBLS + ["../full_db/db/SQL/USER2.tbl",
                      "../full_db/db/SQL/USER6.tbl",
                      "../vector map data/db/SQL/USER6.tbl"]
for tbl in IDX_SRC:
    p = e5.parse_tbl(tbl)
    if not p['records']:
        continue
    for kind in ('ID', 'LN', 'OI'):
        actual = open(tbl.replace('.tbl', f'-{kind}.idx'), 'rb').read()
        check(f"idx {kind} {tbl}", e5.build_idx(p['records'], kind) == actual)

# 4. geojson features match table figures exactly (coords in microdegrees)
for s in ('set1', 'set2', 'set3'):
    g = json.load(open(f"../{s}/SET_complete.geojson"))
    want = {}
    for f in g['features']:
        geom = f['geometry']
        pts = geom['coordinates'][0] if geom['type'] == 'Polygon' \
            else geom['coordinates']
        want[f['properties']['name']] = \
            [(round(p[1] * 1e6), round(p[0] * 1e6)) for p in pts]
    got = {}
    for tbl in sorted(glob.glob(f"../{s}/db/SQL/USER*.tbl")):
        figs = {}
        for r in e5.parse_tbl(tbl)['records']:
            figs.setdefault(r['USEROBJECTID'], []).append(r)
        for rs in figs.values():
            got[rs[0]['NAME']] = [(r['LATITUDE'], r['LONGITUDE']) for r in rs]
    check(f"geojson match {s}", want == got, f"{len(want)} figures")

# 4b. Full planner emulation: regenerate every set from figure-level inputs
# only (geometry, name, type, elevation, layer, draw order, timestamp).
# USEROBJECTID, APPERANCE, WARNINGSENSITIVE, row IDs, pages and all index
# bytes are derived by the documented rules — nothing is copied.
for s in [f"set{i}" for i in range(1, 11)]:
    perfile = {}
    figs_all = []
    for tbl in sorted(glob.glob(f"../{s}/db/SQL/USER*.tbl")):
        g, order = {}, []
        for r in e5.parse_tbl(tbl)['records']:
            if r['USEROBJECTID'] not in g:
                order.append(r['USEROBJECTID'])
            g.setdefault(r['USEROBJECTID'], []).append(r)
        figs = []
        for oid in order:
            rs = g[oid]
            r0 = rs[0]
            pts = [(r['LATITUDE'], r['LONGITUDE']) for r in rs]
            closed = len(rs) > 1 and pts[0] == pts[-1]
            circle = len(rs) == 1 and r0['RANGEDETECTION'] > 0
            f = dict(name=r0['NAME'], type=r0['TYPE'],
                     elevation_m=None if r0['ELEVATION'] == e5.ELEV_NOT_SET
                     else r0['ELEVATION'],
                     kind='circle' if circle
                     else ('polygon' if closed else 'line'),
                     _ref_oid=oid)
            if circle:
                f['center'], f['radius_m'] = pts[0], r0['RANGEDETECTION']
            else:
                f['points'] = pts[:-1] if closed else pts
            ts = (r0['DATEYEARS'], r0['DATEMONTHS'], r0['DATEDAYS'],
                  r0['TIMEHOURS'], r0['TIMEMINUTES'], r0['TIMESECONDS'])
            figs.append(f)
            figs_all.append(f)
        perfile[tbl] = (figs, ts)
    # creation order: non-circles sorted by |oid|; circles fill gap slots
    slots = {abs(f['_ref_oid']): f for f in figs_all if f['kind'] != 'circle'}
    circles = [f for f in figs_all if f['kind'] == 'circle']
    gaps = [k for k in range(1, len(figs_all) + 1) if k not in slots]
    for k, f in zip(gaps, circles):
        slots[k] = f
    e5.assign_object_ids([slots[k] for k in range(1, len(figs_all) + 1)])
    check(f"derived oids {s}",
          all(f['oid'] == f['_ref_oid'] for f in figs_all))
    ok = True
    for tbl, (figs, ts) in perfile.items():
        built = e5.export_layer(figs, ts, template)
        actual = [open(p, 'rb').read() for p in
                  (tbl, tbl.replace('.tbl', '-ID.idx'),
                   tbl.replace('.tbl', '-LN.idx'),
                   tbl.replace('.tbl', '-OI.idx'))]
        ok = ok and list(built) == actual
    check(f"figure-level regeneration {s}", ok,
          f"{len(figs_all)} figures, {len(perfile) * 4} files")

# 5. appMatrix.json structure
m = json.load(open("../full_db/db/settings/system/appMatrix.json"))['member']
ids = {e[0][1] for e in m}
layers = {e[0][0] for e in m}
check("appMatrix members", len(m) == 1675, f"{len(m)}")
check("appMatrix style ids", len(ids) == 585, f"{len(ids)}")
check("appMatrix layers", layers == {0, 1, 2, 3, 4})
names = {e[0][1]: e[1][0] for e in m}
check("zone styles", names.get(800) == 'FDANGER'
      and names.get(802) == 'FNAVIGATIONAL'
      and names.get(803) == 'FOPERATION'
      and names.get(806) == 'FDRAWING')

# 6. .sym layout: 2048-byte glyph directory + 256x256x2 bitmap
for s in ('0', '1', '2', '3'):
    d = open(f"../full_db/db/settings/system/symbols/{s}.sym", 'rb').read()
    check(f"{s}.sym size", len(d) == 2048 + 256 * 256 * 2, f"{len(d)}")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURES:", *FAILS, sep="\n  ")
    sys.exit(1)
print("ALL CHECKS PASSED")
