import euronav5 as e5, json, os, math
from collections import defaultdict

m=json.load(open("../full_db/db/settings/system/appMatrix.json"))['member']
cov=defaultdict(set); nm={}; sym1={}
for e in m:
    L,sid=e[0]; cov[sid].add(L); nm[sid]=e[1][0]
    if L==1:
        pt=e[1][2][0]; sym1[sid]=pt[2] if len(pt)>2 else None
def schemestr(s):
    L=sorted(cov[s]); return "alla5" if L==[0,1,2,3,4] else "S"+''.join(map(str,L))

# ---- välj 100 stil-ID:n: kända intressanta + jämn spridning över katalogen ----
known=[800,801,802,803,804,805,806, 617,618,610,932,799, 408,409,410,411,412,413,
       70,76,78,273,520,524,534,535,540,537,538, 580,581,578,579, 550,
       24,14,214,200,36,229,7,9,22,28,29]
allids=sorted(cov.keys())
ids=list(dict.fromkeys(known))                  # behåll ordning, unika
# fyll på till 100 med jämn spridning över resten
rest=[s for s in allids if s not in set(ids)]
step=max(1,len(rest)//(100-len(ids)))
for s in rest[::step]:
    if len(ids)>=100: break
    ids.append(s)
ids=ids[:100]

TS=(2026,6,11,12,0,0)
BLAT, BLON = 58.5000, 15.5000
def mlat(metres): return metres/111320.0
def mlon(metres,lat): return metres/(111320.0*math.cos(math.radians(lat)))
def ud(x): return int(round(x*1_000_000))

ROWGAP=1000.0      # 1 km mellan raderna (nord-syd)
COLGAP=100.0       # 100 m mellan objekt (öst-väst)
rows=[('line','',  0), ('poly','', 1), ('circle','NAVIGATIONALZONE',2), ('point','POI',3)]

records=[]; k=0; manifest_obj=[]
for geo,typ,ri in rows:
    rlat = BLAT + mlat(ri*ROWGAP)
    for j,app in enumerate(ids):
        lat = rlat
        lon = BLON + mlon(j*COLGAP, rlat)
        k+=1
        oid = k if geo=='line' else (-k if geo=='poly' else 0)
        name=str(app)
        base=dict(USEROBJECTID=oid, DATEDAYS=TS[2],DATEMONTHS=TS[1],DATEYEARS=TS[0],
                  TIMESECONDS=TS[5],TIMEMINUTES=TS[4],TIMEHOURS=TS[3],
                  TYPE=typ, NAME=name, DESCRIPTION='', LABEL=1, APPERANCE=app,
                  ELEVATION=-1025, RANGELETHAL=0, RANGEDETECTION=0,
                  ATTACHMENT='', SPEED=0.0, COURSE=0, WARNINGSENSITIVE=0, CLASS=0, SOURCE=0)
        if geo=='line':
            pts=[(lat-mlat(30),lon),(lat+mlat(30),lon)]
        elif geo=='poly':
            pts=[(lat-mlat(25),lon),(lat+mlat(25),lon+mlon(15,lat)),
                 (lat-mlat(10),lon+mlon(30,lat)),(lat-mlat(25),lon)]
        elif geo=='circle':
            base['RANGEDETECTION']=30; pts=[(lat,lon)]
        else:
            pts=[(lat,lon)]
        for (la,lo) in pts:
            r=dict(base); r['ID']=len(records)+1; r['LATITUDE']=ud(la); r['LONGITUDE']=ud(lo)
            records.append(r)

template=open("../set1/db/SQL/USER2.tbl",'rb').read(e5.HDR_SIZE)
tbl=e5.build_tbl(records, template)
idxs={kind:e5.build_idx(records,kind) for kind in ('ID','LN','OI')}

OUT="/Volumes/Untitled/db/SQL"; os.makedirs(OUT, exist_ok=True)
open(f"{OUT}/USER4.tbl",'wb').write(tbl)
for kind in ('ID','LN','OI'): open(f"{OUT}/USER4-{kind}.idx",'wb').write(idxs[kind])

# manifest
L=[]
L.append("TESTKORT — 4 rader (geometri), 100 objekt/rad, 100 m isär (öst-väst), rader 1 km isär (nord-syd).")
L.append(f"Bas: {BLAT}N {BLON}E. Etiketten på varje objekt = STIL-ID.")
L.append("Rad 1 (sydligast) = LINJER (TYPE tom) | Rad 2 = POLYGONER (TYPE tom) | Rad 3 = CIRKLAR (TYPE=NAVIGATIONALZONE, radie 30m) | Rad 4 (nordligast) = PUNKTER (TYPE=POI)")
L.append("Samma 100 stil-ID i alla fyra rader. Kolumn j (0..99) = stil nedan, öst-väst.")
L.append("")
L.append("KOL | STIL | SCHEMA | SYMBOL(S1) | NAMN")
L.append("-"*70)
for j,app in enumerate(ids):
    L.append(f"{j:>3} | {app:<5}| {schemestr(app):<6} | {str(sym1.get(app,'-')):<10} | {nm[app]}")
open("/Volumes/Untitled/TESTMANIFEST.txt",'w').write("\n".join(L)+"\n")

print(f"{len(ids)} stilar × 4 geometrier = {len(ids)*4} objekt, {len(records)} records, {(len(tbl)-3480)//4104} sidor")
sch=defaultdict(int)
for a in ids: sch[schemestr(a)]+=1
print("schema-fördelning bland de 100 stilarna:", dict(sch))
# verifiera
p=e5.parse_tbl(f"{OUT}/USER4.tbl")
assert all(e5.build_idx(p['records'],kind)==idxs[kind] for kind in ('ID','LN','OI'))
print("parse + idx (multi-node B-träd) round-trip OK,", len(p['records']), "records på stickan")
