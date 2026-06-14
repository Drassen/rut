import euronav5 as e5, json, os, math
from collections import defaultdict
m=json.load(open("../full_db/db/settings/system/appMatrix.json"))['member']
cov=defaultdict(set); nm={}
for e in m: cov[e[0][1]].add(e[0][0]); nm[e[0][1]]=e[1][0]
glyph_styles=defaultdict(list)
for e in m:
    L,sid=e[0]; st=e[1][2][0]
    sym=st[2] if len(st)>2 else -1
    if isinstance(sym,int) and sym>0: glyph_styles[sym].append((sid,L))
def best(g):
    for sid,L in glyph_styles[g]:
        if cov[sid]=={0,1,2,3,4}: return sid,'alla5'
    return glyph_styles[g][0][0],'S'+''.join(map(str,sorted({L for _,L in glyph_styles[g]})))
glyphs=sorted(glyph_styles)

TS=(2026,6,11,12,0,0); BLAT=58.5000; LON0=15.5000
def mlon(metres,lat): return metres/(111320.0*math.cos(math.radians(lat)))
def mlat(metres): return metres/111320.0
def ud(x): return int(round(x*1_000_000))
PERROW=31; COL=100.0; ROWGAP=400.0

records=[]; man=[]
for idx,g in enumerate(glyphs):
    row=idx//PERROW; colj=idx%PERROW
    app,scheme=best(g)
    lat=BLAT+mlat(row*ROWGAP); lon=LON0+mlon(colj*COL,BLAT)
    records.append(dict(ID=len(records)+1, USEROBJECTID=0,
        DATEDAYS=TS[2],DATEMONTHS=TS[1],DATEYEARS=TS[0],
        TIMESECONDS=TS[5],TIMEMINUTES=TS[4],TIMEHOURS=TS[3],
        TYPE='POI', NAME=str(g), DESCRIPTION='', LABEL=1, APPERANCE=app,
        LATITUDE=ud(lat), LONGITUDE=ud(lon), ELEVATION=-1025,
        RANGELETHAL=0, RANGEDETECTION=0, ATTACHMENT='', SPEED=0.0,
        COURSE=0, WARNINGSENSITIVE=0, CLASS=0, SOURCE=0))
    man.append((row+1, colj+1, g, app, scheme))

template=open("../set1/db/SQL/USER2.tbl",'rb').read(e5.HDR_SIZE)
tbl=e5.build_tbl(records, template)
idxs={k:e5.build_idx(records,k) for k in ('ID','LN','OI')}
OUT="/Volumes/Untitled/db/SQL"; os.makedirs(OUT,exist_ok=True)
open(f"{OUT}/USER4.tbl",'wb').write(tbl)
for k in ('ID','LN','OI'): open(f"{OUT}/USER4-{k}.idx",'wb').write(idxs[k])

nrows=(len(glyphs)+PERROW-1)//PERROW
L=[f"GLYF-KATALOG — {len(glyphs)} glyfer i {nrows} rader (a {PERROW}/rad), 100 m isär öst-väst, rader 400 m isär (Rad 1 sydligast).",
   "Bas 58.5000N 15.5000E. Etikett = GLYF-ID. TYPE=POI. Stil = alla-5 om möjligt (annars schema-begränsad).",
   ""]
for r in range(nrows):
    items=[x for x in man if x[0]==r+1]
    L.append(f"--- RAD {r+1} (söder->norr) ---")
    L.append("  pos:glyf(stil/schema)  " + "  ".join(f"{x[1]}:{x[2]}({x[3]}/{x[4]})" for x in items))
open("/Volumes/Untitled/TESTMANIFEST.txt",'w').write("\n".join(L)+"\n")
print(f"{len(records)} glyfer, {nrows} rader, {(len(tbl)-3480)//4104} sidor")
p=e5.parse_tbl(f"{OUT}/USER4.tbl")
assert all(e5.build_idx(p['records'],k)==idxs[k] for k in ('ID','LN','OI'))
print("round-trip OK")
