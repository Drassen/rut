#!/usr/bin/env python3
import sys, os, struct
from pathlib import Path

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

def decode_6bit_block(data: bytes) -> str:
    """Avkodar 4 bytes (32 bitar) till max 5 tecken."""
    if len(data) < 4: return ""
    val32 = struct.unpack(">I", data)[0]
    chars = []
    shifts = [26, 20, 14, 8, 2]
    for s in shifts:
        code = (val32 >> s) & 0x3F
        chars.append(SIXBIT_MAP.get(code, "?"))
    return "".join(chars).strip()

def decode_caracter_text_date(data: bytes) -> str:
    """Byte 4-11 i CARACTER (8 bytes = 10 tecken 6-bit)."""
    part1 = decode_6bit_block(data[4:8])
    part2 = decode_6bit_block(data[8:12])
    return part1 + part2

def decode_caracter_bin_date(data: bytes) -> str:
    """
    Byte 12-13 i CARACTER (Bit-packat).
    Byte 12: [Dag 5b][Månad_Hög 3b]
    Byte 13: [Månad_Låg 1b][Res 2b][År 5b]
    """
    b12 = data[12]
    b13 = data[13]
    
    day = b12 >> 3
    
    # Månad: Ta de 3 lägsta från B12, shifta upp ett steg, lägg till högsta från B13
    # Formel: ((Byte12 & 7) << 1) | ((Byte13 >> 7) & 1)
    month_idx = ((b12 & 0x07) << 1) | ((b13 >> 7) & 0x01)
    month = month_idx + 1 
    
    year_val = b13 & 0x1F
    year = 2000 + year_val
    
    return f"{day:02d}-{month:02d}-{year}"

def check_dates_in_dir(d: Path):
    car_path = d / "CARACTER.P01"
    pil_path = d / "PILOTE.HD"
    
    has_car = car_path.exists()
    has_pil = pil_path.exists()
    
    if not has_car and not has_pil: return

    print(f"\n{MAGENTA}=== DATUM-CHECK: {d.name} ==={VIT}")
    
    # --- CARACTER.P01 ---
    if has_car:
        try:
            c_data = car_path.read_bytes()
            if len(c_data) >= 16:
                # 1. Text Datum (4-11)
                c_text = decode_caracter_text_date(c_data)
                
                # 2. Binärt Datum (12-13)
                c_bin = decode_caracter_bin_date(c_data)
                
                print(f"{CYAN}CARACTER.P01{VIT}")
                print(f"  Byte 4-11 (6-bit Text):  {GUL}{c_text}{VIT}")
                print(f"  Byte 12-13 (Binärt):     {GUL}{c_bin}{VIT}")
            else:
                print(f"{RÖD}CARACTER.P01 för liten.{VIT}")
        except Exception as e:
            print(f"{RÖD}Fel vid läsning av CARACTER: {e}{VIT}")
    else:
        print(f"{GRÅ}CARACTER.P01 saknas.{VIT}")

    # --- PILOTE.HD ---
    if has_pil:
        try:
            p_data = pil_path.read_bytes()
            if len(p_data) >= 24:
                # 1. ASCII Datum (0-11)
                # Ersätt icke-printbara tecken för snygg utskrift
                p_ascii_raw = p_data[0:12]
                p_ascii = "".join([chr(b) if 32 <= b <= 126 else "?" for b in p_ascii_raw])
                
                # 2. Binära Integers (12-23) -> År, Månad, Dag
                # Byte 12-15: År
                y = struct.unpack('>I', p_data[12:16])[0]
                # Byte 16-19: Månad
                m = struct.unpack('>I', p_data[16:20])[0]
                # Byte 20-23: Dag
                d_val = struct.unpack('>I', p_data[20:24])[0]
                
                p_bin = f"{d_val:02d}-{m:02d}-{y}"
                
                print(f"{CYAN}PILOTE.HD{VIT}")
                print(f"  Byte 0-11 (8-bit ASCII): {GUL}{p_ascii}{VIT}")
                print(f"  Byte 12-23 (3x Int32):   {GUL}{p_bin}{VIT} (År:{y}, Mån:{m}, Dag:{d_val})")
                
            else:
                print(f"{RÖD}PILOTE.HD för liten.{VIT}")
        except Exception as e:
            print(f"{RÖD}Fel vid läsning av PILOTE: {e}{VIT}")
    else:
        print(f"{GRÅ}PILOTE.HD saknas.{VIT}")

def main():
    if len(sys.argv) < 2:
        print("Ange katalog att skanna.")
        sys.exit(1)
        
    root = Path(sys.argv[1])
    
    for d in sorted(os.walk(root), key=lambda x: x[0].lower()):
        check_dates_in_dir(Path(d[0]))

if __name__ == "__main__":
    main()