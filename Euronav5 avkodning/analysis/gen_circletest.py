import euronav5 as e5, json, os, math
from collections import defaultdict
m=json.load(open("../full_db/db/settings/system/appMatrix.json"))['member']
cov=defaultdict(set); nm={}
for e in m: cov[e[0][1]].add(e[0][0]); nm[e[0][1]]=e[1][0]
def sch(s):
    L=sorted(cov[s]); return "alla5" if L==[0,1,2,3,4] else "S"+''.join(map(str,L))

TS=(2026,6,11,12,0,0)
BLAT=58.5000; LON0=15.5000
def mlon(metres,lat): return metres/(111320.0*math.cos(math.radians(lat)))
def mlat(metres): return metres/111320.0
def ud(x): return int(round(x*1_000_000))

# testfall: (kod, radie_m, fält, TYPE, APP, extra)
# fält: 'RD','RL','BOTH'
T=[]
# GRUPP A — radie-ramp (stil 802, NAVIGATIONALZONE, RANGEDETECTION)
for r in (100,250,500,1000,2000,4000,8000):
    T.append((f"R{r}", r, 'RD', 'NAVIGATIONALZONE', 802, {}))
# GRUPP B — range-fält (radie 2000, 802, NAVIGATIONALZONE)
T.append(("Bdet", 2000,'RD','NAVIGATIONALZONE',802,{}))
T.append(("Bleth",2000,'RL','NAVIGATIONALZONE',802,{}))
T.append(("Bboth",2000,'BOTH','NAVIGATIONALZONE',802,{}))
# GRUPP C — TYPE-varianter (radie 2000, stil 802 konstant, RD)
for t in ('NAVIGATIONALZONE','DANGERZONE','RESTRICTEDZONE','PROHIBITEDZONE','OBSTACLE','POI',''):
    T.append((f"C-{t or 'TOM'}", 2000,'RD', t, 802, {}))
# GRUPP D — stil-varianter (radie 2000, NAVIGATIONALZONE, RD)
for app in (802,805,800,806,76,70,617,932,408,524):
    T.append((f"D{app}", 2000,'RD','NAVIGATIONALZONE', app, {}))
# GRUPP E — encoding-egenheter (radie 2000)
T.append(("E-2pt",   2000,'RD','NAVIGATIONALZONE',802,{'twopt':True}))
T.append(("E-obst",  2000,'RD','OBSTACLE',411,{'elev':100,'warn':1}))
T.append(("E-lbl5",  2000,'RD','NAVIGATIONALZONE',802,{'label':5}))

records=[]; man=[]; k=0; lon=LON0; prev_r=0
for i,(code,rad,field,typ,app,ex) in enumerate(T):
    # adaptivt avstånd: halva förra + halva denna + 1500 m marginal
    gap = prev_r + rad + 1500
    lon = lon + mlon(gap, BLAT) if i>0 else LON0
    prev_r = rad
    rd = rad if field in ('RD','BOTH') else 0
    rl = rad if field=='RL' else (rad//2 if field=='BOTH' else 0)
    elev=ex.get('elev'); warn=ex.get('warn',0); label=ex.get('label',1)
    twopt=ex.get('twopt',False)
    k+=1
    name=f"{i+1:02d}{code}"
    oid = k if twopt else 0
    base=dict(USEROBJECTID=oid, DATEDAYS=TS[2],DATEMONTHS=TS[1],DATEYEARS=TS[0],
              TIMESECONDS=TS[5],TIMEMINUTES=TS[4],TIMEHOURS=TS[3],
              TYPE=typ, NAME=name, DESCRIPTION='', LABEL=label, APPERANCE=app,
              ELEVATION=(-1025 if elev is None else elev),
              RANGELETHAL=rl, RANGEDETECTION=rd, ATTACHMENT='', SPEED=0.0,
              COURSE=0, WARNINGSENSITIVE=warn, CLASS=0, SOURCE=0)
    if twopt:
        # centrum + kantpunkt (radie österut), inga range-fält
        b2=dict(base); b2['RANGEDETECTION']=0; b2['RANGELETHAL']=0
        pts=[(BLAT,lon),(BLAT, lon+mlon(rad,BLAT))]
        for (la,lo) in pts:
            r=dict(b2); r['ID']=len(records)+1; r['LATITUDE']=ud(la); r['LONGITUDE']=ud(lo)
            records.append(r)
    else:
        r=dict(base); r['ID']=len(records)+1; r['LATITUDE']=ud(BLAT); r['LONGITUDE']=ud(lon)
        records.append(r)
    man.append((i+1,name,rad,field,typ or '(tom)',app,sch(app),
                '2 records' if twopt else ('elev/warn' if elev else ('LABEL5' if label==5 else ''))))

template=open("../set1/db/SQL/USER2.tbl",'rb').read(e5.HDR_SIZE)
tbl=e5.build_tbl(records, template)
idxs={kind:e5.build_idx(records,kind) for kind in ('ID','LN','OI')}
OUT="/Volumes/Untitled/db/SQL"; os.makedirs(OUT,exist_ok=True)
open(f"{OUT}/USER4.tbl",'wb').write(tbl)
for kind in ('ID','LN','OI'): open(f"{OUT}/USER4-{kind}.idx",'wb').write(idxs[kind])

L=["CIRKELTEST — en lång rad cirklar (öst-väst) vid 58.5000N, start 15.5000E.",
   "Adaptivt avstånd (ingen överlappning). Etikett på varje = NAMN nedan.",
   "VIKTIGT: slå PÅ intervisibility/THREAT RANGES i EuroNav (User Databases-menyn) — annars syns inga range-ringar.",
   "",
   "# | NAMN       | RADIE(m) | FÄLT | TYPE             | STIL | SCHEMA | NOTIS",
   "-"*92]
for r in man:
    L.append(f"{r[0]:>2}| {r[1]:<10} | {r[2]:>7}  | {r[3]:<4} | {r[4]:<16} | {r[5]:<4} | {r[6]:<6} | {r[7]}")
open("/Volumes/Untitled/TESTMANIFEST.txt",'w').write("\n".join(L)+"\n")
print("\n".join(L))
print(f"\n{len(T)} cirklar, {len(records)} records, {(len(tbl)-3480)//4104} sidor")
p=e5.parse_tbl(f"{OUT}/USER4.tbl")
assert all(e5.build_idx(p['records'],kind)==idxs[kind] for kind in ('ID','LN','OI'))
print("round-trip OK ->", len(p['records']),"records på stickan")
