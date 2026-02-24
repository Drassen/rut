#!/usr/bin/env python3
import sys, os, struct
from pathlib import Path
from collections import defaultdict

# ==============================
# FÄRGER
# ==============================
RÖD = '\033[91m'
GRÖN = '\033[92m'
GUL = '\033[93m'
BLÅ = '\033[94m'
MAGENTA = '\033[95m' # Nu tillagd!
CYAN = '\033[96m'
VIT = '\033[0m'

# ==============================
# 6-BIT DECODING
# ==============================
SIXBIT_MAP = {
    0: "", 11: "-", 14: "0", 15: "1", 16: "2", 17: "3", 18: "4",
    19: "5", 20: "6", 21: "7", 22: "8", 23: "9", 30: "A", 31: "B",
    32: "C", 33: "D", 34: "E", 35: "F", 36: "G", 37: "H", 38: "I",
    39: "J", 40: "K", 41: "L", 42: "M", 43: "N", 44: "O", 45: "P",
    46: "Q", 47: "R", 48: "S", 49: "T", 50: "U", 51: "V", 52: "W",
    53: "X", 54: "Y", 55: "Z"
}

def decode_6bit_str(data: bytes) -> str:
    if len(data) < 4: return ""
    val32 = struct.unpack(">I", data[0:4])[0]
    chars = []
    shifts = [26, 20, 14, 8, 2]
    for s in shifts:
        code = (val32 >> s) & 0x3F
        chars.append(SIXBIT_MAP.get(code, "?"))
    return "".join(chars).strip()

# ==============================
# ANALYS
# ==============================
def analyze_airport_usage(d: Path):
    apt_file = d / "AIRPORT.P01"
    rte_file = d / "ROUTE.P01"
    
    if not apt_file.exists(): return

    # 1. RÄKNA ANVÄNDNING I RUTTER
    # Key: Airport Record Index, Value: Count
    usage_counts = defaultdict(int)
    
    if rte_file.exists():
        try:
            r_data = rte_file.read_bytes()
            offset = 16
            while offset + 500 <= len(r_data):
                block = r_data[offset : offset + 500]
                
                # Kolla om rutt är aktiv
                status = block[16]
                r_name = decode_6bit_str(block[0:4])
                
                if status != 0x90 and r_name: # Giltig rutt
                    # Kolla Logistik-header (Start/Dest)
                    start_idx = block[11]
                    dest_idx = block[15]
                    
                    # Kom ihåg: Index i ruttfilen = (Record + 1) * 2
                    # Så Record = (Index / 2) - 1
                    if start_idx > 0: usage_counts[(start_idx // 2) - 1] += 1
                    if dest_idx > 0:  usage_counts[(dest_idx // 2) - 1] += 1
                    
                    # Kolla punkter
                    pt_off = 20
                    for i in range(40):
                        p = block[pt_off : pt_off + 12]
                        if p[11] == 0x8C: break
                        
                        # Om typ är Airport (5C) och index > 0
                        if p[11] == 0x5C and p[0] > 0:
                            rec_idx = (p[0] // 2) - 1
                            usage_counts[rec_idx] += 1
                        
                        pt_off += 12
                offset += 500
        except: pass

    # 2. LÄS AIRPORT-FILEN OCH JÄMFÖR
    try:
        a_data = apt_file.read_bytes()
    except: return

    if len(a_data) < 56: return

    print(f"\n{MAGENTA}--- ANALYS: {d.name} ---{VIT}")
    print(f"{'Rec':<3} | {'ID':<6} | {'B17 Dec':<7} | {'B17 Bin':<8} | {'Rutt-träffar':<12} | {'Match?':<10} | {'B28-31 (Runway?)'}")
    print("-" * 85)

    offset = 16
    rec_num = 0
    
    while offset + 40 <= len(a_data):
        rec = a_data[offset : offset + 40]
        
        apt_id = decode_6bit_str(rec[0:4])
        b17 = rec[17]
        
        # Hämta verklig användning
        real_usage = usage_counts[rec_num]
        
        # Jämför teori mot verklighet
        match = False
        # Teori: 6=Oanvänd, 14=Använd, 30=Använd Flera?
        if real_usage == 0 and b17 == 6: match = True
        elif real_usage > 0 and b17 == 14: match = True
        elif real_usage > 1 and b17 == 30: match = True
        
        # Tillåt 14 för multipla också om systemet inte alltid sätter 30
        if real_usage > 1 and b17 == 14: match = True 
        
        match_col = f"{GRÖN}JA{VIT}" if match else f"{RÖD}NEJ{VIT}"
        
        # Kolla B28-31 (Runway)
        b28_31 = rec[28:32]
        val_28_31 = struct.unpack(">I", b28_31)[0]
        runway_str = f"{val_28_31}" if val_28_31 != 0 else "-"
        
        # Skriv ut (endast om ID finns, för att skippa tomma records på slutet)
        if apt_id:
            print(f"{rec_num:<3} | {apt_id:<6} | {b17:<7} | {b17:08b} | {real_usage:<12} | {match_col:<10} | {runway_str}")
        
        offset += 40
        rec_num += 1

def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    for d in sorted(os.walk(root), key=lambda x: x[0].lower()):
        analyze_airport_usage(Path(d[0]))

if __name__ == "__main__":
    main()