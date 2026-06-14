import euronav5 as e5, json, os, math
from collections import defaultdict
m=json.load(open("../full_db/db/settings/system/appMatrix.json"))['member']
cov=defaultdict(set); byl={}; nm={}
for e in m: cov[e[0][1]].add(e[0][0]); byl[(e[0][1],e[0][0])]=e[1]; nm[e[0][1]]=e[1][0]
ACTIVE=2
def rep(s): return ACTIVE if ACTIVE in cov[s] else min(cov[s])
def colored(c):
    if not isinstance(c,list) or len(c)<3: return False
    a=c[3] if len(c)>=4 else 255
    return a>0 and not(c[0]>=249 and c[1]>=249 and c[2]>=249)
def info(s):
    st=byl[(s,rep(s))][2]; sym=st[0][2] if len(st[0])>2 else -1
    line=st[1][0][0] if st[1] and st[1][0] else None
    return sym,line
# ALLA färgade linjestilar (ingen symbol), oavsett schema
styles=sorted(s for s in cov if not(isinstance(info(s)[0],int) and info(s)[0]>0) and colored(info(s)[1]))
print(f"{len(styles)} linjestilar (inkl schema-begränsade)")

TS=(2026,6,11,12,0,0); BLAT=58.5000; LON0=15.5000
def mlon(me,lat): return me/(111320.0*math.cos(math.radians(lat)))
def mlat(me): return me/111320.0
def ud(x): return int(round(x*1_000_000))
PERROW=20; COL=150.0; ROWGAP=300.0; HALF=30.0

records=[]; man=[]; k=0
for idx,sid in enumerate(styles):
    row=idx//PERROW; colj=idx%PERROW
    clat=BLAT+mlat(row*ROWGAP); clon=LON0+mlon(colj*COL,BLAT)
    k+=1
    for (la,lo) in [(clat-mlat(HALF),clon),(clat+mlat(HALF),clon)]:  # vertikalt segment
        records.append(dict(ID=len(records)+1, USEROBJECTID=k,
            DATEDAYS=TS[2],DATEMONTHS=TS[1],DATEYEARS=TS[0],
            TIMESECONDS=TS[5],TIMEMINUTES=TS[4],TIMEHOURS=TS[3],
            TYPE='', NAME=str(sid), DESCRIPTION='', LABEL=1, APPERANCE=sid,
            LATITUDE=ud(la), LONGITUDE=ud(lo), ELEVATION=-1025,
            RANGELETHAL=0, RANGEDETECTION=0, ATTACHMENT='', SPEED=0.0,
            COURSE=0, WARNINGSENSITIVE=0, CLASS=0, SOURCE=0))
    man.append((row+1,colj+1,sid,'all5' if cov[sid]=={0,1,2,3,4} else 'S'+''.join(map(str,sorted(cov[sid]))),nm[sid]))

template=open("../set1/db/SQL/USER2.tbl",'rb').read(e5.HDR_SIZE)
tbl=e5.build_tbl(records,template)
idxs={x:e5.build_idx(records,x) for x in ('ID','LN','OI')}
OUT="/Volumes/Untitled/db/SQL"; os.makedirs(OUT,exist_ok=True)
open(f"{OUT}/USER4.tbl",'wb').write(tbl)
for x in ('ID','LN','OI'): open(f"{OUT}/USER4-{x}.idx",'wb').write(idxs[x])
nrows=(len(styles)+PERROW-1)//PERROW
L=[f"LINJE-KATALOG — {len(styles)} linjestilar i {nrows} rader (a {PERROW}), etikett=STIL-ID.",
   "RAD 1 = SYDLIGAST (nederst på skärmen, norr=upp). 150m mellan, 300m rader. Vertikala segment.",
   "Inkluderar schema-begränsade (markerade) — t.ex. KRAFTLEDNING 272/273/533/534 — för att se om de renderar.",""]
for r in range(nrows):
    items=[x for x in man if x[0]==r+1]
    L.append(f"--- KORT-RAD {r+1} (söderifrån) ---  "+"  ".join(f"{x[2]}[{x[3]}]" for x in items))
open("/Volumes/Untitled/TESTMANIFEST.txt",'w').write("\n".join(L)+"\n")
print(f"{len(records)} records, {(len(tbl)-3480)//4104} sidor")
# var ligger kraftledning?
for sid in (272,273,533,534):
    i=styles.index(sid); print(f"  KRAFTLEDNING {sid}: kort-rad {i//PERROW+1} (söderifrån), kol {i%PERROW+1}")
p=e5.parse_tbl(f"{OUT}/USER4.tbl")
assert all(e5.build_idx(p['records'],x)==idxs[x] for x in ('ID','LN','OI'))
print("round-trip OK")
