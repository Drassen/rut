#!/usr/bin/env python3
import sys, os, struct
from pathlib import Path

# ==============================
# FÄRGER & FORMATERING
# ==============================
RÖD = '\033[91m'
GRÖN = '\033[92m'
GUL = '\033[93m'
BLÅ = '\033[94m'
MAGENTA = '\033[95m'
CYAN = '\033[96m'
VIT = '\033[0m'
GRÅ = '\033[90m'

def bits_str(data: bytes) -> str:
    """Returnerar en sträng med 8-bitars grupper: 00000000 11111111..."""
    chunks = []
    for b in data:
        b_str = f"{b:08b}"
        # Färgkoda ettor
        colored = ""
        for char in b_str:
            if char == '1': colored += f"{GUL}1{VIT}"
            else: colored += f"{GRÅ}0{VIT}"
        chunks.append(colored)
    return " ".join(chunks)

def print_section(data: bytes, desc: str = ""):
    """Skriver ut bitar följt av beskrivning."""
    print(f"{bits_str(data)}")
    if desc:
        print(f"{CYAN}# {desc}{VIT}")

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
    """Avkodar 4 bytes till sträng (används för ruttnamn och gamla punkter)."""
    if len(data) < 4: return ""
    val32 = struct.unpack(">I", data[0:4])[0]
    chars = []
    shifts = [26, 20, 14, 8, 2]
    for s in shifts:
        code = (val32 >> s) & 0x3F
        chars.append(SIXBIT_MAP.get(code, "?"))
    return "".join(chars).strip()

def decode_3byte_id(data: bytes) -> str:
    """Avkodar 3 bytes (24 bitar) till 4 tecken (används för Logistical ID)."""
    if len(data) < 3: return ""
    # Slå ihop 3 bytes till ett 24-bitars heltal
    val24 = (data[0] << 16) | (data[1] << 8) | data[2]
    chars = []
    # 4 tecken á 6 bitar = 24 bitar. 
    # Shift: 18, 12, 6, 0
    shifts = [18, 12, 6, 0]
    for s in shifts:
        code = (val24 >> s) & 0x3F
        chars.append(SIXBIT_MAP.get(code, ""))
    return "".join(chars).strip()

def get_logistical_type_desc(type_code: int) -> str:
    """Tolkar 3-bitars typkoden från byte 16."""
    if type_code == 0b010: return "Ingen (010)"
    if type_code == 0b100: return "System/Jep (100)"
    if type_code == 0b101: return "User (101)"
    return f"Okänd ({type_code:03b})"

# ==============================
# PARSER
# ==============================
def visual_dump_route(path: Path):
    print(f"\n{MAGENTA}--- SÖKER I: {path} ---{VIT}")
    
    if not path.exists():
        return

    raw_data = path.read_bytes()
    size = len(raw_data)
    print(f"{GRÖN}HITTADE ROUTE.P01 ({size} bytes){VIT}")

    if size < 16:
        print(f"{RÖD}Filen är för liten för att ha en header.{VIT}")
        return

    # --- FILHEADER ---
    print(f"\n{GUL}#ROUTE.P01 Filheader{VIT}")
    
    # Bitmask 0-12
    print_section(raw_data[0:13], "Byte 0-12: Antal routes som ettor (Bitmask)")
    
    # Checksum 13-15
    chk_a = raw_data[13]
    chk_b = raw_data[14]
    print_section(raw_data[13:16], f"byte 13-15 checksum (A:{chk_a}, B:{chk_b})")
    print("") 

    # --- RUTTER ---
    offset = 16
    route_idx = 0
    
    while offset + 500 <= size:
        block = raw_data[offset : offset + 500]
        route_idx += 1
        
        # --- HOPPA ÖVER TOMMA RUTTER ---
        # Om namnet (första 8 byten) är nollat, skippa.
        name_bytes = block[0:8]
        if all(b == 0 for b in name_bytes):
            offset += 500
            continue

        # Hämta namn för rubrik
        r_name = decode_6bit_str(block[0:4]) + decode_6bit_str(block[4:8])
        
        print(f"{GUL}========================================{VIT}")
        print(f"{GUL}# NY RUTT (Slot {route_idx}) - NAMN: {r_name}{VIT}")
        print(f"{GUL}========================================{VIT}")
        print(f"{GRÖN}Rutt-header (20 bytes totalt){VIT}")
        
        # Namn (0-7)
        print_section(block[0:8], f"Rutt Namn '{r_name}' (Byte 0-7)")
        
        # --- LOGISTICAL FLIGHTPLAN (8-15) ---
        print(f"\n{CYAN}--- Logistical Flightplan (Byte 8-15) ---{VIT}")
        
        # PARSA START (Byte 8-11)
        start_id_bytes = block[8:11]
        start_idx = block[11]
        start_id_str = decode_3byte_id(start_id_bytes)
        
        # PARSA DESTINATION (Byte 12-15)
        dest_id_bytes = block[12:15]
        dest_idx = block[15]
        dest_id_str = decode_3byte_id(dest_id_bytes)

        # Skriv ut Start
        print_section(block[8:12], f"START (Byte 8-11): ID='{start_id_str}' (3 byte), DB-Index={start_idx}")
        
        # Skriv ut Destination
        print_section(block[12:16], f"DEST  (Byte 12-15): ID='{dest_id_str}' (3 byte), DB-Index={dest_idx}")
        
        print(f"{CYAN}-----------------------------------------{VIT}")
        
        # --- KONTROLLSIFFROR (Byte 16-19) ---
        # Byte 16: Typer
        b16 = block[16]
        # Bit 7-5: Start typ
        start_type_code = (b16 >> 5) & 0x07
        # Bit 4-2: Slut typ
        dest_type_code = (b16 >> 2) & 0x07
        
        start_type_str = get_logistical_type_desc(start_type_code)
        dest_type_str = get_logistical_type_desc(dest_type_code)
        
        # Byte 17-19: Count (som förut)
        b17 = block[17]
        b18 = block[18]
        count = (int(b17) * 8) + (int(b18) >> 5)
        
        print_section(block[16:20], 
                      f"KONTROLL (Byte 16-19)\n"
                      f"  - Start Typ: {start_type_str}\n"
                      f"  - Dest  Typ: {dest_type_str}\n"
                      f"  - Count: {count} (Stat byte: {b16:02X})")

        # Punktlista (20-499)
        print(f"\n{GRÖN}Ruttens punktlista:{VIT}")
        
        pt_off = 20
        for i in range(40):
            p = block[pt_off : pt_off + 12]
            b11 = p[11]
            idx = p[0]

            # Om punkten är en slutmarkör (8C), bryt loopen
            if b11 == 0x8C:
                break
            
            # Data
            pt_name = decode_6bit_str(p[4:8])
            
            # Typ-tolkning
            typ_str = "UNK"
            if b11 == 0x5C: typ_str = "Airport"
            elif b11 == 0x6C: typ_str = "Waypoint"
            elif b11 == 0x7C: typ_str = "Navaid"
            elif idx == 0: typ_str = "Jeppesen"
            
            print(f"# WPT {i+1} (Idx:{idx}, Typ:{typ_str}, Namn:{pt_name})")
            
            # Byte 0-3 (Index/Flags)
            print_section(p[0:4], f"- Byte 0-3 (Idx {idx})")
            # Byte 4-7 (Namn)
            print_section(p[4:8], f"- Byte 4-7 (Namn '{pt_name}')")
            # Byte 8-11 (Typ/Extra)
            print_section(p[8:12], f"- Byte 8-11 (Typ {b11:02X})")
            print("") 
            
            pt_off += 12

        print("") # Tomrad mellan rutter
        offset += 500

def main():
    if len(sys.argv) < 2:
        print("Ange mapp att söka i.")
        sys.exit(1)
        
    root = Path(sys.argv[1])
    print(f"Scannar katalogträd: {root}")
    
    found_any = False
    for d in sorted(os.walk(root), key=lambda x: x[0].lower()):
        r_path = Path(d[0]) / "ROUTE.P01"
        if r_path.exists():
            found_any = True
            visual_dump_route(r_path)
    
    if not found_any:
        print(f"{RÖD}Inga ROUTE.P01 filer hittades i underkatalogerna.{VIT}")

if __name__ == "__main__":
    main()