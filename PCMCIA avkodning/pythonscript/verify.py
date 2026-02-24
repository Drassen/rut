#!/usr/bin/env python3
import sys, os, struct
from pathlib import Path
from collections import defaultdict

# ==========================================
# KONFIGURATION & KONSTANTER
# ==========================================
RÖD = '\033[91m'
GRÖN = '\033[92m'
GUL = '\033[93m'
BLÅ = '\033[94m'
MAGENTA = '\033[95m'
CYAN = '\033[96m'
VIT = '\033[0m'

FILES_CONFIG = {
    "ROUTE.P01":    {"size": 50020, "rec_len": 500, "head": 16},
    "WAYPOINT.P01": {"size": 2820,  "rec_len": 28,  "head": 16},
    "AIRPORT.P01":  {"size": 4020,  "rec_len": 40,  "head": 16},
    "NAVAID.P01":   {"size": 4020,  "rec_len": 40,  "head": 16},
    "CARACTER.P01": {"size": 116,   "rec_len": 0,   "head": 0},
    "PILOTE.HD":    {"size": 44,    "rec_len": 0,   "head": 0}
}

CARACTER_OFFSETS = {
    "WAYPOINT.P01": (68, 76),
    "AIRPORT.P01":  (80, 88),
    "NAVAID.P01":   (92, 100),
    "ROUTE.P01":    (104, 112)
}

# Giltiga 6-bitars koder (A109 standard: Endast Versaler, Siffror, Bindestreck)
# 0=Pad, 11='-', 14-23='0-9', 30-55='A-Z'
VALID_6BIT_CODES = {
    0, 11, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43,
    44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55
}

# ==========================================
# HJÄLPFUNKTIONER
# ==========================================

def count_set_bits(data: bytes) -> int:
    count = 0
    for b in data:
        count += bin(b).count('1')
    return count

def check_padding(data: bytes, desc: str) -> int:
    for i, b in enumerate(data):
        if b != 0:
            print(f"      {RÖD}FEL:{VIT} {desc} ej noll vid offset {i} (Värde: {b:02X})")
            return 1
    return 0

def check_float_range(val: float, min_v: float, max_v: float, desc: str) -> int:
    if val == 0.0: return 0
    if not (min_v <= val <= max_v):
        print(f"      {RÖD}FEL:{VIT} {desc} utanför intervall: {val:.4f} (Tillåtet: {min_v} till {max_v})")
        return 1
    return 0

def decode_6bit_val(code: int) -> str:
    if code == 0: return "" 
    if code == 11: return "-"
    if 14 <= code <= 23: return str(code - 14)
    if 30 <= code <= 55: return chr(code + 35) 
    return "?"

def decode_6bit_block_to_str(data: bytes) -> str:
    if len(data) != 4: return ""
    val32 = struct.unpack(">I", data)[0]
    chars = ""
    shifts = [26, 20, 14, 8, 2]
    for s in shifts:
        code = (val32 >> s) & 0x3F
        chars += decode_6bit_val(code)
    return chars

def check_6bit_string(data: bytes, desc: str) -> int:
    """Enkel kontroll av ett 4-byte block. (Behålls för bakåtkompatibilitet men check_valid_name_format är bättre)"""
    if len(data) != 4: return 0
    val32 = struct.unpack(">I", data)[0]
    if (val32 & 0x03) != 0:
        print(f"      {RÖD}FEL:{VIT} {desc} ogiltig padding (sista 2 bitar ej 0).")
        return 1
    shifts = [26, 20, 14, 8, 2]
    errors = 0
    for s in shifts:
        code = (val32 >> s) & 0x3F
        if code not in VALID_6BIT_CODES:
            print(f"      {RÖD}FEL:{VIT} {desc} ogiltig 6-bit kod: {code} (Dec)")
            errors = 1
    return errors

def check_valid_name_format(data: bytes, desc: str) -> int:
    """
    Kontrollerar ett namn (kan vara 4, 8, 12 bytes etc).
    Regler:
    1. Endast giltiga tecken (A-Z, 0-9, -).
    2. INGA mellanslag (kod 0) inuti namnet. Padding får endast finnas på slutet.
    """
    if len(data) % 4 != 0: return 0
    
    all_codes = []
    errors = 0
    
    # Extrahera alla koder från alla block
    for i in range(0, len(data), 4):
        block = data[i:i+4]
        val32 = struct.unpack(">I", block)[0]
        
        if (val32 & 0x03) != 0:
             print(f"      {RÖD}FEL:{VIT} {desc} (Block {i//4}) har ogiltiga slutbitar (ej 00).")
             errors += 1
        
        for s in [26, 20, 14, 8, 2]:
            code = (val32 >> s) & 0x3F
            all_codes.append(code)
            if code not in VALID_6BIT_CODES:
                 print(f"      {RÖD}FEL:{VIT} {desc} innehåller ogiltigt tecken kod {code}.")
                 errors += 1

    # Kontrollera "Mellanslag" (Padding 0 mitt i strängen)
    found_padding = False
    for idx, code in enumerate(all_codes):
        if code == 0:
            found_padding = True
        elif found_padding:
            # Vi har sett en 0:a (padding), men nu kom ett tecken till!
            print(f"      {RÖD}FEL:{VIT} {desc} innehåller mellanslag (000000) inuti namnet.")
            errors += 1
            break
            
    return 1 if errors > 0 else 0

def check_waypoint_id_special(data: bytes, desc: str) -> int:
    if len(data) != 4: return 1
    val32 = struct.unpack(">I", data)[0]
    errors = 0
    if (val32 & 0x80000000) == 0:
        print(f"      {RÖD}FEL:{VIT} {desc} Bit 31 (Byte 24 bit 7) är inte 1.")
        errors += 1
    if (val32 & 0x00000001) != 0:
        print(f"      {RÖD}FEL:{VIT} {desc} Bit 0 (Byte 27 bit 0) är inte 0.")
        errors += 1
    
    # Extrahera innehållet (30 bitar) och kontrollera tecken
    content = (val32 >> 1) & 0x3FFFFFFF
    
    # Skapa en fejkad "ren" 4-byte buffer för att kunna använda check_valid_name_format
    # Vi skiftar upp content 2 steg för att simulera standardformatet (där sista 2 bitarna är 0)
    simulated_val32 = (content << 2)
    simulated_data = struct.pack(">I", simulated_val32)
    
    errors += check_valid_name_format(simulated_data, desc)
    
    return errors

def calculate_x_y_checksums(data: bytes):
    sum_x = 0
    sum_y = 0
    for i in range(0, len(data), 4):
        if i + 4 > len(data): break
        val_x = struct.unpack('>h', data[i:i+2])[0]
        val_y = struct.unpack('>h', data[i+2:i+4])[0]
        sum_x += val_x
        sum_y += val_y
    return sum_x, sum_y

# ==========================================
# VERIFIERINGS-STEG
# ==========================================

def validate_files_exist(d: Path) -> bool:
    print(f"{CYAN}1. Filkontroll (Existens){VIT}")
    missing = []
    for fname in FILES_CONFIG:
        if not (d / fname).exists():
            missing.append(fname)
    if missing:
        print(f"  {RÖD}SAKNAS:{VIT} {', '.join(missing)}")
        return False
    print(f"  {GRÖN}Alla filer existerar.{VIT}")
    return True

def check_file_sizes(d: Path) -> int:
    print(f"\n{CYAN}2. Filstorlekar{VIT}")
    errs = 0
    for fname, cfg in FILES_CONFIG.items():
        p = d / fname
        size = p.stat().st_size
        if size != cfg["size"]:
            print(f"  {fname:<15} {RÖD}FEL STORLEK{VIT} ({size} bytes, ska vara {cfg['size']})")
            errs += 1
        else:
            print(f"  {fname:<15} {GRÖN}OK{VIT}")
    return errs

def verify_internal_structures(d: Path) -> int:
    print(f"\n{CYAN}3. Intern Data-integritet{VIT}")
    errors = 0

    for fname in FILES_CONFIG.keys():
        fpath = d / fname
        if not fpath.exists(): continue
        data = fpath.read_bytes()

        # --- PILOTE.HD ---
        if fname == "PILOTE.HD":
            ascii_bytes = data[0:12]
            try: ascii_str = ascii_bytes.decode('ascii').strip()
            except: 
                print(f"  PILOTE.HD       {RÖD}FEL:{VIT} Byte 0-11 är inte giltig ASCII")
                errors += 1; continue
            
            if not ascii_str.startswith("DTD"):
                print(f"  PILOTE.HD       {RÖD}FEL:{VIT} Datumsträng startar inte med 'DTD' ({ascii_str})")
                errors += 1
            
            val_year = struct.unpack('>I', data[12:16])[0]
            val_month = struct.unpack('>I', data[16:20])[0]
            val_day = struct.unpack('>I', data[20:24])[0]
            
            numeric_part = ascii_str.replace("DTD", "").replace(" ", "")
            expected_numeric = f"{val_day}{val_month:02d}{val_year}"
            
            if numeric_part != expected_numeric:
                print(f"  PILOTE.HD       {RÖD}FEL:{VIT} ASCII-datum ({ascii_str}) matchar ej binärdatum")
                errors += 1
            
            if not (1990 <= val_year <= 2040): errors += 1
            if not (1 <= val_month <= 12): errors += 1
            if not (1 <= val_day <= 31): errors += 1
            continue 

        # --- DB FILER & ROUTE HEADER ---
        if fname != "CARACTER.P01":
            cnt = count_set_bits(data[0:13])
            chk_a = data[13]; chk_b = data[14]
            exp_a = (129 + cnt) % 256
            if cnt == 100: exp_a = 128
            exp_b = (cnt * 2) % 256
            
            if chk_a != exp_a or chk_b != exp_b:
                print(f"  {fname:<15} {RÖD}HEADER FEL{VIT} (Räknat: {cnt}, Chk: {chk_a}/{chk_b})")
                errors += 1
            if data[15] != 0:
                 print(f"  {fname:<15} {RÖD}Byte 15 ej noll{VIT}")
                 errors += 1
        
        # --- RECORDS ---
        cfg = FILES_CONFIG[fname]
        rec_len = cfg["rec_len"]
        if rec_len == 0: continue 

        offset = 16
        for i in range(100):
            if offset + rec_len > len(data): break
            rec = data[offset : offset + rec_len]
            
            if all(b == 0 for b in rec): 
                offset += rec_len; continue
            
            if fname == "ROUTE.P01":
                name_byte = rec[0]
                status_byte = rec[16]
                
                # --- DETEKTION AV TOM RUTT ---
                is_empty_slot = (name_byte == 0 and status_byte == 0x48)

                if is_empty_slot:
                    if any(b != 0 for b in rec[0:16]):
                        print(f"      {RÖD}FEL:{VIT} Tom Rutt {i+1}: Header (byte 0-15) innehåller data (Byte 11 = 0x{rec[11]:02X}). Ska vara 0.")
                        errors += 1
                    if any(b != 0 for b in rec[17:20]):
                         print(f"      {RÖD}FEL:{VIT} Tom Rutt {i+1}: Header (byte 17-19) ej nollade.")
                         errors += 1
                    pt_off = 20
                    for pIdx in range(40):
                        p = rec[pt_off : pt_off + 12]
                        if any(b != 0 for b in p[0:11]):
                            print(f"      {RÖD}FEL:{VIT} Tom Rutt {i+1}: Punkt {pIdx+1} har data i byte 0-10 (Ska vara 0).")
                            errors += 1
                            break 
                        if p[11] != 0x8C:
                            print(f"      {RÖD}FEL:{VIT} Tom Rutt {i+1}: Punkt {pIdx+1} byte 11 är 0x{p[11]:02X} (ska vara 8C).")
                            errors += 1
                            break
                        pt_off += 12
                    offset += rec_len
                    continue

                # --- AKTIV RUTT ---
                if rec[0] == 0: 
                     print(f"      {RÖD}FEL:{VIT} Rutt {i+1}: Saknar namn (0x00) men status är 0x{status_byte:02X} (ej 0x48).")
                     errors += 1

                # KONTROLL: Namnformat (inga inre mellanslag, godkända tecken)
                errors += check_valid_name_format(rec[0:8], f"Rutt {i+1} Namn")
                
                if (rec[16] & 0x03) != 0:
                     print(f"      {RÖD}FEL:{VIT} Rutt {i+1} Byte 16 padding ej 00")
                     errors += 1
                
                errors += check_padding(rec[19:20], f"Rutt {i+1} HeadPad")
                
                # --- KONTROLL AV ANTAL PUNKTER (MAX 40) ---
                b17 = rec[17]; b18 = rec[18]
                count_in_header = (int(b17) * 8) + (int(b18) >> 5)
                
                if count_in_header > 40:
                     print(f"      {RÖD}FEL:{VIT} Rutt {i+1}: Header anger {count_in_header} punkter. (MAX TILLÅTET ÄR 40).")
                     errors += 1

                pt_off = 20
                real_pts = 0
                for pIdx in range(40):
                    p = rec[pt_off : pt_off + 12]
                    b11 = p[11]
                    
                    if b11 == 0x8C:
                        if any(b != 0 for b in p[0:11]):
                             print(f"      {RÖD}FEL:{VIT} Rutt {i+1} Pt {pIdx+1} (Padding) ej nollad i byte 0-10.")
                             errors += 1
                    else:
                        real_pts += 1
                        if (b11 & 0x0F) != 0xC:
                            print(f"      {RÖD}FEL:{VIT} Rutt {i+1} Pt {pIdx+1} Byte 11 formatfel (0x{b11:02X})")
                            errors += 1
                        
                        # KONTROLL: Punktnamn (inga inre mellanslag)
                        errors += check_valid_name_format(p[4:8], f"Rutt {i+1} Pt {pIdx+1} Namn")

                        errors += check_padding(p[1:4], f"Rutt {i+1} Pt {pIdx+1} Pad1")
                        errors += check_padding(p[8:11], f"Rutt {i+1} Pt {pIdx+1} Pad2")

                    pt_off += 12
                
                if real_pts != count_in_header:
                    print(f"      {RÖD}FEL:{VIT} Rutt {i+1} Punkträkning: Header säger {count_in_header}, hittade {real_pts} aktiva.")
                    errors += 1

            elif fname == "AIRPORT.P01":
                errors += check_6bit_string(rec[0:4], f"APT {i} ID")
                if rec[3] != 0: errors += 1 
                errors += check_6bit_string(rec[4:8], f"APT {i} Namn1")
                errors += check_6bit_string(rec[8:12], f"APT {i} Namn2")
                errors += check_padding(rec[16:17], f"APT {i} FPad1")
                errors += check_padding(rec[18:20], f"APT {i} FPad2")
                if rec[17] not in [0, 6, 14, 30]: errors += 1
                
                lat = struct.unpack(">f", rec[20:24])[0]
                lon = struct.unpack(">f", rec[24:28])[0]
                errors += check_float_range(lat, -90, 90, f"APT {i} Lat")
                errors += check_float_range(lon, -180, 180, f"APT {i} Lon")
                errors += check_padding(rec[28:32], f"APT {i} Pad4")

            elif fname == "NAVAID.P01":
                if rec[0] != 0xE0:
                    print(f"      {RÖD}FEL:{VIT} NAV {i} Byte 0 ej 0xE0 ({rec[0]:02X})")
                    errors += 1
                if rec[1] != 0 or rec[3] != 0: errors += 1
                if rec[2] not in [0x00, 0x30, 0x70, 0xF0]: errors += 1
                errors += check_6bit_string(rec[4:8], f"NAV {i} ID")
                errors += check_6bit_string(rec[8:12], f"NAV {i} Namn1")
                errors += check_6bit_string(rec[16:20], f"NAV {i} Pad/Txt")
                
                freq = struct.unpack(">f", rec[20:24])[0]
                errors += check_float_range(freq, 0, 10000, f"NAV {i} Freq")
                lat = struct.unpack(">f", rec[24:28])[0]
                lon = struct.unpack(">f", rec[28:32])[0]
                errors += check_float_range(lat, -90, 90, f"NAV {i} Lat")
                errors += check_float_range(lon, -180, 180, f"NAV {i} Lon")

            elif fname == "WAYPOINT.P01":
                errors += check_padding(rec[20:21], f"WPT {i} Pad1")
                if rec[21] % 8 != 0: errors += 1
                errors += check_padding(rec[22:24], f"WPT {i} Pad2")
                lat = struct.unpack(">f", rec[0:4])[0]
                lon = struct.unpack(">f", rec[4:8])[0]
                errors += check_float_range(lat, -90, 90, f"WPT {i} Lat")
                errors += check_float_range(lon, -180, 180, f"WPT {i} Lon")
                
                # KONTROLL: Waypoint Namn och ID
                errors += check_valid_name_format(rec[8:20], f"WPT {i} Namn")
                errors += check_waypoint_id_special(rec[24:28], f"WPT {i} ID")

            offset += rec_len

    return errors

def verify_caracter_file(d: Path) -> int:
    c_path = d / "CARACTER.P01"
    if not c_path.exists(): return 0
    errs = 0
    try: data = c_path.read_bytes()
    except: return 1
    
    if len(data) != 116:
        print(f"  {RÖD}FEL:{VIT} CARACTER storlek {len(data)}")
        errs += 1
    if data[0:4] != b'\x55\xAA\x55\xAA': errs += 1
        
    c_text = decode_6bit_block_to_str(data[4:8]) + decode_6bit_block_to_str(data[8:12])
    if not c_text.startswith("DTD"): errs += 1
    
    b12 = data[12]; b13 = data[13]
    c_day = b12 >> 3
    c_month_idx = ((b12 & 0x07) << 1) | ((b13 >> 7) & 0x01)
    c_month = c_month_idx + 1 
    c_year = 2000 + (b13 & 0x1F)
    
    num_str = c_text.replace("DTD", "").strip()
    exp_str = f"{c_day}{c_month:02d}{c_year}"
    if num_str != exp_str: pass 

    for off in [16, 28, 40, 52]:
        if data[off] not in [0x80, 0x00]: errs += 1
    
    errors = errs + check_padding(data[17:28], "CARACTER Pad 1")
    errors += check_padding(data[29:40], "CARACTER Pad 2")
    errors += check_padding(data[41:52], "CARACTER Pad 3")
    errors += check_padding(data[53:68], "CARACTER Pad 4")

    return errors

def verify_logical_links(d: Path) -> int:
    print(f"\n{CYAN}4. Logiska Länkar{VIT}")
    errors = 0
    r_path = d / "ROUTE.P01"
    if not r_path.exists(): return 0
    r_data = r_path.read_bytes()
    
    db_counts = {}
    for name in ["WAYPOINT.P01", "AIRPORT.P01", "NAVAID.P01"]:
        p = d / name
        if p.exists():
            db_counts[name] = (p.stat().st_size - 16) // FILES_CONFIG[name]["rec_len"]
        else: db_counts[name] = 0

    used_apt = defaultdict(int)
    used_nav = defaultdict(int)
    used_wpt = defaultdict(int)
    route_to_wpt = defaultdict(set)

    offset = 16
    route_idx = 0
    while offset + 500 <= len(r_data):
        block = r_data[offset : offset + 500]
        route_idx += 1
        
        if block[0] != 0: 
            current_route_num = route_idx 
            s_idx = block[11]; d_idx = block[15]
            if s_idx > 0: used_apt[(s_idx//2)-1] += 1
            if d_idx > 0: used_apt[(d_idx//2)-1] += 1

            pt_off = 20
            for i in range(40):
                p = block[pt_off : pt_off + 12]
                b11 = p[11]
                idx = p[0]
                if b11 == 0x8C: break # Terminator
                
                if idx > 0:
                    rec = (idx // 2) - 1
                    target_db = ""
                    if b11 == 0x5C: 
                        target_db = "AIRPORT.P01"
                        used_apt[rec] += 1
                    elif b11 == 0x7C: 
                        target_db = "NAVAID.P01"
                        used_nav[rec] += 1
                    elif b11 == 0x6C: 
                        target_db = "WAYPOINT.P01"
                        used_wpt[rec] += 1
                        route_to_wpt[current_route_num].add(rec)
                    
                    if target_db and rec >= db_counts[target_db]:
                        print(f"  Rutt {route_idx} Pt {i+1}: {RÖD}Index {idx} utanför {target_db}{VIT}")
                        errors += 1
                pt_off += 12
        offset += 500
        
    if errors == 0: print(f"  {GRÖN}Logiska länkar OK.{VIT}")
    return errors

def verify_global_checksums(d: Path) -> int:
    print(f"\n{CYAN}5. Global Signering (CARACTER){VIT}")
    c_path = d / "CARACTER.P01"
    if not c_path.exists(): return 1
    c_data = c_path.read_bytes()
    errors = 0
    for fname, (start, end) in CARACTER_OFFSETS.items():
        fpath = d / fname
        exp_x, exp_y = struct.unpack('>ii', c_data[start:end])
        if not fpath.exists():
            if exp_x != 0 or exp_y != 0:
                print(f"  {fname:<15} {RÖD}FEL: Saknas men har checksumma!{VIT}")
                errors += 1
            continue
        act_x, act_y = calculate_x_y_checksums(fpath.read_bytes())
        if act_x != exp_x or act_y != exp_y:
             print(f"  {fname:<15} {RÖD}FEL CHECKSUMMA{VIT}")
             errors += 1
        else:
             print(f"  {fname:<15} {GRÖN}GODKÄND{VIT}")
    return errors

def main():
    if len(sys.argv) < 2:
        print("Ange katalog.")
        sys.exit(1)
    d = Path(sys.argv[1])
    print(f"{MAGENTA}=== VALIDERAR DATAKORT: {d.name} ==={VIT}")
    
    missing = [f for f in FILES_CONFIG if not (d/f).exists()]
    if missing:
        print(f"{RÖD}SAKNAS:{VIT} {missing}")
        sys.exit(1)
        
    errs = 0
    if check_file_sizes(d) > 0: errs += 1
    errs += verify_internal_structures(d)
    errs += verify_caracter_file(d)
    errs += verify_logical_links(d)
    errs += verify_global_checksums(d)
    print("-" * 40)
    if errs == 0: print(f"{GRÖN}>>> GODKÄNT <<<{VIT}")
    else: print(f"{RÖD}>>> {errs} FEL <<<{VIT}")

if __name__ == "__main__":
    main()