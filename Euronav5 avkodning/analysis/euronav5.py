"""
Euronav5 USER-table (.tbl) and index (.idx) library.

Verified byte-exact against every USER table and index file in
"Euronav5 avkodning" (set1-set10, full_db, vector map data) on 2026-06-10.
Run verify_all.py to re-check all claims.

File model (USER*.tbl):
  [16-byte file header][24 x 96-byte column descriptors][index directory + padding]
  = 3480-byte header, then N pages of 4104 bytes.
  Page = [u32 recordSize=0x100][u32 usedRecords] + 16 x 256-byte record slots.
  Unused slots are zero-filled.

Variable header fields (everything else is a constant template):
  0x08  u32 LE  page count
  0x68  u32 LE  next row ID = recordCount + 1

Index files (USER*-{ID,LN,OI}.idx):
  [60-byte header][K x 768-byte B-tree nodes]
  ID: key = USEROBJECTID, LN: key = LONGITUDE (microdeg), OI: key = ID.
  Value is always the row ID. Built by inserting rows in ID order.
"""
import struct

HDR_SIZE = 3480
PAGE_SIZE = 4104
REC_SIZE = 256
RECS_PER_PAGE = 16

# (name, offset-in-record, type); strings occupy declared size + 1 NUL byte
FIELDS = [
    ("ID",               0x00, 'i4'),
    ("USEROBJECTID",     0x04, 'i4'),
    ("DATEDAYS",         0x08, 'u2'),
    ("DATEMONTHS",       0x0a, 'u2'),
    ("DATEYEARS",        0x0c, 'u2'),
    ("TIMESECONDS",      0x0e, 'u2'),
    ("TIMEMINUTES",      0x10, 'u2'),
    ("TIMEHOURS",        0x12, 'u2'),
    ("TYPE",             0x14, 's21'),
    ("NAME",             0x29, 's21'),
    ("DESCRIPTION",      0x3e, 's129'),
    ("LABEL",            0xbf, 'i4'),
    ("APPERANCE",        0xc3, 'i4'),
    ("LATITUDE",         0xc7, 'i4'),   # microdegrees
    ("LONGITUDE",        0xcb, 'i4'),   # microdegrees
    ("ELEVATION",        0xcf, 'i4'),   # metres; -1025 = not set
    ("RANGELETHAL",      0xd3, 'i4'),
    ("RANGEDETECTION",   0xd7, 'i4'),   # circle radius in metres
    ("ATTACHMENT",       0xdb, 's16'),
    ("SPEED",            0xeb, 'f8'),
    ("COURSE",           0xf3, 'i4'),
    ("WARNINGSENSITIVE", 0xf7, 'u1'),
    ("CLASS",            0xf8, 'i4'),
    ("SOURCE",           0xfc, 'i4'),
]


# ----------------------------------------------------------------------------
# .tbl
# ----------------------------------------------------------------------------

def parse_record(rec):
    out = {}
    for n, o, t in FIELDS:
        if t == 'i4':
            out[n] = struct.unpack_from('<i', rec, o)[0]
        elif t == 'u2':
            out[n] = struct.unpack_from('<H', rec, o)[0]
        elif t == 'u1':
            out[n] = rec[o]
        elif t == 'f8':
            out[n] = struct.unpack_from('<d', rec, o)[0]
        else:
            size = int(t[1:])
            out[n] = rec[o:o + size].split(b'\0')[0].decode('latin1')
    return out


def build_record(d):
    rec = bytearray(REC_SIZE)
    for n, o, t in FIELDS:
        v = d.get(n, 0 if t != 's' else '')
        if t == 'i4':
            struct.pack_into('<i', rec, o, v)
        elif t == 'u2':
            struct.pack_into('<H', rec, o, v)
        elif t == 'u1':
            rec[o] = v
        elif t == 'f8':
            struct.pack_into('<d', rec, o, v)
        else:
            b = (v or '').encode('latin1')
            rec[o:o + len(b)] = b
    return bytes(rec)


def parse_tbl(path):
    data = open(path, 'rb').read()
    hdr = data[:HDR_SIZE]
    npages = struct.unpack_from('<I', hdr, 0x08)[0]
    counter = struct.unpack_from('<I', hdr, 0x68)[0]
    assert len(data) == HDR_SIZE + npages * PAGE_SIZE, "file size mismatch"
    recs = []
    for p in range(npages):
        poff = HDR_SIZE + p * PAGE_SIZE
        recsize, used = struct.unpack_from('<II', data, poff)
        assert recsize == REC_SIZE
        for r in range(RECS_PER_PAGE):
            raw = data[poff + 8 + r * REC_SIZE: poff + 8 + (r + 1) * REC_SIZE]
            if r < used:
                recs.append(parse_record(raw))
            else:
                assert not any(raw), "nonzero bytes in unused record slot"
    assert counter == len(recs) + 1, "0x68 counter != recordCount+1"
    return dict(header=hdr, records=recs, data=data)


def build_tbl(records, template_header):
    """records: list of field dicts (ID must be 1..N in order)."""
    hdr = bytearray(template_header)
    npages = max(1, -(-len(records) // RECS_PER_PAGE))
    struct.pack_into('<I', hdr, 0x08, npages)
    struct.pack_into('<I', hdr, 0x68, len(records) + 1)
    out = bytearray(hdr)
    for p in range(npages):
        chunk = records[p * RECS_PER_PAGE:(p + 1) * RECS_PER_PAGE]
        out += struct.pack('<II', REC_SIZE, len(chunk))
        for d in chunk:
            out += build_record(d)
        out += b'\0' * ((RECS_PER_PAGE - len(chunk)) * REC_SIZE)
    return bytes(out)


# ----------------------------------------------------------------------------
# .idx  (B-tree, order 63, bottom-up splits)
# ----------------------------------------------------------------------------

MAXK = 63
SPLIT_AT = 31  # left keeps 31, median up, right gets 32


class _Node:
    __slots__ = ('idx', 'leaf', 'pairs', 'kids', 'parent')

    def __init__(s, idx, leaf=True):
        s.idx = idx
        s.leaf = leaf
        s.pairs = []
        s.kids = []
        s.parent = None


class _Tree:
    def __init__(s):
        s.nodes = [_Node(0)]
        s.root = 0
        s.stale63 = {}  # node idx -> child idx left in slot 63 after a split

    def _alloc(s, leaf):
        n = _Node(len(s.nodes), leaf)
        s.nodes.append(n)
        return n

    def insert(s, k, v):
        n = s.nodes[s.root]
        while not n.leaf:
            i = 0
            while i < len(n.pairs) and k >= n.pairs[i][0]:
                i += 1
            c = s.nodes[n.kids[i]]
            c.parent = n.idx
            n = c
        i = 0
        while i < len(n.pairs) and k >= n.pairs[i][0]:
            i += 1
        n.pairs.insert(i, (k, v))
        while len(n.pairs) > MAXK:
            n = s._split(n)

    def _split(s, n):
        med = n.pairs[SPLIT_AT]
        r = s._alloc(n.leaf)
        r.pairs = n.pairs[SPLIT_AT + 1:]
        if not n.leaf:
            r.kids = n.kids[SPLIT_AT + 1:]
            # planner quirk: clearing the vacated child slots misses slot 63
            s.stale63[n.idx] = n.kids[63]
            n.kids = n.kids[:SPLIT_AT + 1]
        n.pairs = n.pairs[:SPLIT_AT]
        if n.parent is None and n.idx == s.root:
            nr = s._alloc(False)
            nr.pairs = [med]
            nr.kids = [n.idx, r.idx]
            s.root = nr.idx
            return nr
        p = s.nodes[n.parent]
        j = p.kids.index(n.idx)
        p.pairs.insert(j, med)
        p.kids.insert(j + 1, r.idx)
        r.parent = p.idx
        return p

    def serialize(s, mx, maxrow, mn, minrow):
        out = struct.pack('<HH', 3, 3)
        out += struct.pack('<ii', 60 + 768 * s.root, 0)
        out += struct.pack('<ii', -1, -1)
        out += struct.pack('<iIIii', mx, 0x80000000, 0x80000000, maxrow, maxrow)
        out += struct.pack('<iIIii', mn, 0x80000000, 0x80000000, minrow, minrow)
        for n in s.nodes:
            out += struct.pack('<ii', len(n.pairs), 0)
            slots = [-1] * 64
            for q, c in enumerate(n.kids):
                slots[q] = c
            if not n.leaf and n.idx in s.stale63 and len(n.kids) <= 63:
                slots[63] = s.stale63[n.idx]
            out += b''.join(struct.pack('<i', -1 if c == -1 else 60 + 768 * c)
                            for c in slots)
            out += b''.join(struct.pack('<ii', k, v) for k, v in n.pairs)
            out += b'\0' * 8 * (MAXK - len(n.pairs))
        return out


IDX_KEY = {'ID': 'USEROBJECTID', 'LN': 'LONGITUDE', 'OI': 'ID'}


def build_idx(records, kind):
    """kind in {'ID','LN','OI'}; records in row order (ID 1..N)."""
    keyf = IDX_KEY[kind]
    t = _Tree()
    for r in records:
        t.insert(r[keyf], r['ID'])
    ks = sorted((r[keyf], r['ID']) for r in records)
    mx, mn = ks[-1][0], ks[0][0]
    maxrow = max(v for k, v in ks if k == mx)
    minrow = min(v for k, v in ks if k == mn)
    return t.serialize(mx, maxrow, mn, minrow)


# ----------------------------------------------------------------------------
# Figure-level export (planner emulation)
# ----------------------------------------------------------------------------

# Fixed TYPE -> APPERANCE (style id) mapping used by the planner's drawing UI.
TYPE_APPEARANCE = {
    '':                 806,  # FDRAWING
    'NAVIGATIONALZONE': 802,  # FNAVIGATIONAL
    'DANGERZONE':       800,  # FDANGER
    'RESTRICTEDZONE':   803,  # FOPERATION
    'PROHIBITEDZONE':   806,  # FDRAWING
}

ELEV_NOT_SET = -1025


def assign_object_ids(figures):
    """figures: list of dicts with 'kind' in {'line','polygon','circle'},
    in creation order across the whole session. Adds 'oid' to each.
    Rule (verified on all 10 sets + production):
      session counter k = 1,2,3,... per figure;
      polygon (closed) -> -k, line (open) -> +k,
      single-record objects (circle/point) -> 0 (slot still consumed)."""
    for k, f in enumerate(figures, 1):
        f['oid'] = 0 if f['kind'] == 'circle' else (-k if f['kind'] == 'polygon' else k)
    return figures


def figures_to_records(figures, ts):
    """figures: creation-ordered dicts for ONE layer file, already carrying
    'oid'. Keys: kind, name, type ('' if none), points [(lat_udeg, lon_udeg)]
    (polygons WITHOUT closing repeat), radius_m (circles),
    elevation_m (None if not set).
    ts: (year, month, day, hour, minute, second).
    Returns record dicts ready for build_tbl()."""
    y, mo, d, h, mi, s = ts
    recs = []
    rid = 0
    for f in figures:
        typ = f.get('type', '')
        elev = f.get('elevation_m')
        common = dict(
            USEROBJECTID=f['oid'],
            DATEDAYS=d, DATEMONTHS=mo, DATEYEARS=y,
            TIMESECONDS=s, TIMEMINUTES=mi, TIMEHOURS=h,
            TYPE=typ, NAME=f['name'], DESCRIPTION='',
            LABEL=1, APPERANCE=TYPE_APPEARANCE[typ],
            ELEVATION=ELEV_NOT_SET if elev is None else elev,
            RANGELETHAL=0, RANGEDETECTION=0, ATTACHMENT='',
            SPEED=0.0, COURSE=0,
            # Likely an obstacle/zone-warning-system flag (cf. the
            # "OBST WARN ON/OFF" macros on the cards). In every reference
            # object it is set exactly when ELEVATION is set, which is the
            # default here; pass 'warning' explicitly to override.
            WARNINGSENSITIVE=f.get('warning', 0 if elev is None else 1),
            CLASS=0, SOURCE=0,
        )
        pts = list(f.get('points', []))
        if f['kind'] == 'polygon':
            pts = pts + [pts[0]]                      # close the ring
        elif f['kind'] == 'circle':
            pts = [f['center']]
        for (lat, lon) in pts:
            rid += 1
            r = dict(common, ID=rid, LATITUDE=lat, LONGITUDE=lon)
            if f['kind'] == 'circle':
                r['RANGEDETECTION'] = f['radius_m']
            recs.append(r)
    return recs


def export_layer(figures, ts, template_header):
    """Full export of one layer: returns (tbl, id_idx, ln_idx, oi_idx)."""
    recs = figures_to_records(figures, ts)
    return (build_tbl(recs, template_header),
            build_idx(recs, 'ID'), build_idx(recs, 'LN'), build_idx(recs, 'OI'))
