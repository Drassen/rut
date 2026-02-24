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
MAGENTA = '\033[95m'
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
# GLOBAL STATISTIK
# ==============================
summary_stats = defaultdict(list)
total_navaids_scanned = 0

# ==============================
# ANALYS
# ==============================
def scan_navaid_bytes_0_3(d: Path):
    global total_navaids_scanned
    f_path = d / "NAVAID.P01"
    if not f_path.exists(): return

    try:
        data = f_path.read_bytes()
    except: return

    if len(data) < 56: return 

    print(f"\n{MAGENTA}--- {d.name} (NAVAID) ---{VIT}")
    # Justerad header
    print(f"{'ID':<8} | {'Byte 0-3 (Binärt)':<37} | {'Decimal'}")
    print("-" * 60)
    
    offset = 16 # Skippa header
    
    while offset + 40 <= len(data):
        rec = data[offset : offset + 40]
        
        # ID för Navaid ligger på offset 4
        nav_id = decode_6bit_str(rec[4:8])
        
        # FILTER: Hoppa över rader utan ID
        if not nav_id:
            offset += 40
            continue
        
        # Hämta Byte 0-3
        chunk = rec[0:4]
        val_32 = struct.unpack(">I", chunk)[0]
        
        # Spara till statistik
        summary_stats[val_32].append(f"{nav_id} ({d.name})")
        total_navaids_scanned += 1
        
        # Formatera Binärt (med färg)
        bin_str_raw = f"{val_32:032b}"
        # Dela upp i 8-bitars grupper för läsbarhet
        groups = [bin_str_raw[i:i+8] for i in range(0, 32, 8)]
        
        fmt_bin = ""
        for group in groups:
            for bit in group:
                if bit == '1': fmt_bin += f"{GUL}1{VIT}"
                else: fmt_bin += f"{BLÅ}0{VIT}"
            fmt_bin += " " # Mellanslag mellan bytes
        
        print(f"{nav_id:<8} | {fmt_bin:<37} | {val_32}")
        
        offset += 40

def print_summary():
    print(f"\n\n{CYAN}=============================================={VIT}")
    print(f"{CYAN}    SAMMANSTÄLLNING AV BYTE 0-3 (NAV)         {VIT}")
    print(f"{CYAN}=============================================={VIT}")
    print(f"Totalt antal navaids skannade: {total_navaids_scanned}\n")
    
    print(f"{'Decimal':<10} | {'Hex':<10} | {'Antal':<6} | {'Exempel'}")
    print("-" * 80)
    
    for val in sorted(summary_stats.keys()):
        count = len(summary_stats[val])
        hex_val = f"0x{val:08X}"
        
        # Ta de första 5 exemplen
        examples = ", ".join(summary_stats[val][:5])
        if count > 5: examples += "..."
        
        print(f"{val:<10} | {hex_val:<10} | {count:<6} | {examples}")

def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    
    for d in sorted(os.walk(root), key=lambda x: x[0].lower()):
        scan_navaid_bytes_0_3(Path(d[0]))
        
    print_summary()

if __name__ == "__main__":
    main()