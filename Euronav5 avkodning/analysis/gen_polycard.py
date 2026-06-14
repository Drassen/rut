import euronav5 as e5, json, os, math
from collections import defaultdict
m=json.load(open("../full_db/db/settings/system/appMatrix.json"))['member']
cov=defaultdict(set); rep={}; nm={}
for e in m: cov[e[0][1]].add(e[0][0]); nm[e[0][1]]=e[1][0]
for e in m:
    sid=e[0][1]; rsch=0 if 0 in cov[sid] else min(cov[sid])
    if e[0][0]==rsch and sid not in rep: rep[sid]=e[1]
def colored(c):
    if not isinstance(c,list) or len(c)<3: return False
    a=c[3] if len(c)>=4 else 255
    return a>0 and not(c[0]>=249 and c[1]>=249 and c[2]>=249)
# polygon-dugliga: alla-5, ingen symbol, färgad kant ELLER synlig fyllning
styles=[]
for sid,body in rep.items():
    if cov[sid]!={0,1,2,3,4}: continue
    st=body[2]; sym=st[0][2] if len(st[0])>2 else -1
    if isinstance(sym,int) and sym>0: continue
    line=st[1][0][0] if st[1] and st[1][0] else None
    fill=st[2][0] if st[2] else None
    if colored(line) or colored(fill): styles.append(sid)
styles.sort()
print(f"polygon-dugliga stilar: {len(styles)}")

TS=(2026,6,11,12,0,0); BLAT=58.5000; LON0=15.5000
def mlon(metres,lat): return metres/(111320.0*math.cos(math.radians(lat)))
def mlat(metres): return metres/111320.0
def ud(x): return int(round(x*1_000_000))
PERROW=20; COL=150.0; ROWGAP=300.0; D=30.0

records=[]; man=[]; k=0
for idx,sid in enumerate(styles):
    row=idx//PERROW; colj=idx%PERROW
    clat=BLAT+mlat(row*ROWGAP); clon=LON0+mlon(colj*COL,BLAT)
    k+=1
    dlat=mlat(D); dlon=mlon(D,clat)
    verts=[(clat-dlat,clon-dlon),(clat-dlat,clon+dlon),(clat+dlat,clon+dlon),
           (clat+dlat,clon-dlon),(clat-dlat,clon-dlon)]  # stängd
    for (la,lo) in verts:
        records.append(dict(ID=len(records)+1, USEROBJECTID=-k,
            DATEDAYS=TS[2],DATEMONTHS=TS[1],DATEYEARS=TS[0],
            TIMESECONDS=TS[5],TIMEMINUTES=TS[4],TIMEHOURS=TS[3],
            TYPE='', NAME=str(sid), DESCRIPTION='', LABEL=1, APPERANCE=sid,
            LATITUDE=ud(la), LONGITUDE=ud(lo), ELEVATION=-1025,
            RANGELETHAL=0, RANGEDETECTION=0, ATTACHMENT='', SPEED=0.0,
            COURSE=0, WARNINGSENSITIVE=0, CLASS=0, SOURCE=0))
    man.append((row+1, colj+1, sid, nm[sid]))

template=open("../set1/db/SQL/USER2.tbl",'rb').read(e5.HDR_SIZE)
tbl=e5.build_tbl(records, template)
idxs={x:e5.build_idx(records,x) for x in ('ID','LN','OI')}
OUT="/Volumes/Untitled/db/SQL"; os.makedirs(OUT,exist_ok=True)
open(f"{OUT}/USER4.tbl",'wb').write(tbl)
for x in ('ID','LN','OI'): open(f"{OUT}/USER4-{x}.idx",'wb').write(idxs[x])
nrows=(len(styles)+PERROW-1)//PERROW
L=[f"POLYGON-KATALOG — {len(styles)} polygon-stilar i {nrows} rader (a {PERROW}), etikett = STIL-ID.",
   "Bas 58.5000N 15.5000E. Rad 1 sydligast. 150 m mellan polygoner, 300 m mellan rader. TYPE tom.",""]
for r in range(nrows):
    items=[x for x in man if x[0]==r+1]
    L.append(f"--- RAD {r+1} ---  " + "  ".join(f"{x[2]}({x[3][:14]})" for x in items))
open("/Volumes/Untitled/TESTMANIFEST.txt",'w').write("\n".join(L)+"\n")
print(f"{len(records)} records, {(len(tbl)-3480)//4104} sidor")
p=e5.parse_tbl(f"{OUT}/USER4.tbl")
assert all(e5.build_idx(p['records'],x)==idxs[x] for x in ('ID','LN','OI'))
print("round-trip OK")
