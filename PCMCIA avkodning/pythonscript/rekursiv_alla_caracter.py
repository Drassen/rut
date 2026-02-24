#!/usr/bin/env python3
import sys, os, argparse, html, struct
from pathlib import Path
from typing import List, Optional

# ANSI-färgkoder
RÖD = '\033[91m'
GRÖN = '\033[92m'
GUL = '\033[93m'
BLÅ = '\033[94m'
MAGENTA = '\033[95m'
CYAN = '\033[96m'
VIT = '\033[0m'

COL_WIDTH = 8

# ==============================
# 6-bitars avkodningstabell (för DTD-text)
# ==============================
SIXBIT_MAP = {
    0: "", 11: "-",
    14: "0", 15: "1", 16: "2", 17: "3", 18: "4",
    19: "5", 20: "6", 21: "7", 22: "8", 23: "9",
    30: "A", 31: "B", 32: "C", 33: "D", 34: "E", 35: "F",
    36: "G", 37: "H", 38: "I", 39: "J", 40: "K", 41: "L",
    42: "M", 43: "N", 44: "O", 45: "P", 46: "Q", 47: "R",
    48: "S", 49: "T", 50: "U", 51: "V", 52: "W", 53: "X",
    54: "Y", 55: "Z"
}

def get_6bit_char(code: int) -> str:
    if code in SIXBIT_MAP: return SIXBIT_MAP[code]
    try: return chr(code + 34)
    except: return "?"

def center_text(txt: str, width: int) -> str:
    pad = max(0, width - len(txt))
    left = pad // 2
    right = pad - left
    return ' ' * left + txt + ' ' * right

def format_chunk_lines(chunk: bytes, per_row: int) -> List[str]:
    lines: List[str] = []
    for i in range(0, len(chunk), per_row):
        row = chunk[i:i+per_row]
        bin_tokens = []
        for b in row:
            bits = f"{b:08b}"
            bin_tokens.append(f"{BLÅ}{bits}{VIT}" if b != 0 else bits)
        lines.append(" ".join(bin_tokens))
        dec_tokens = [f"{GRÖN}{center_text(str(b), COL_WIDTH)}{VIT}" for b in row]
        lines.append(" ".join(dec_tokens))
    return lines

# ==============================
# CARACTER.P01 — Strukturhantering
# ==============================

UNKNOWN_LINE_INDEX = 12 

def extract_unknown_line(data: bytes) -> Optional[bytes]:
    if len(data) >= 16:
        return data[UNKNOWN_LINE_INDEX:UNKNOWN_LINE_INDEX+4]
    return None

def decode_6bit_block(val32: int) -> str:
    chars = []
    shifts = [26, 20, 14, 8, 2]
    for s in shifts:
        code = (val32 >> s) & 0x3F 
        chars.append(get_6bit_char(code))
    return "".join(chars)

def extract_dtd_date(data: bytes) -> str:
    if len(data) < 12: return ""
    try:
        part1 = struct.unpack(">I", data[4:8])[0]
        part2 = struct.unpack(">I", data[8:12])[0]
        return decode_6bit_block(part1) + decode_6bit_block(part2)
    except: return "ERROR"

def decode_binary_date(b: bytes) -> str:
    """
    Avkodar byte 12-13 enligt den bekräftade formeln:
    Byte 12: [Day 5b][Month_High 3b]
    Byte 13: [Month_Low 1b][Unused 2b][Year 5b]
    """
    if len(b) < 2: return ""
    b12 = b[0]
    b13 = b[1]
    
    day = b12 >> 3
    
    # Månad: Ta de 3 lägsta från B12, shifta upp ett steg, lägg till högsta från B13
    month_high = b12 & 0x07
    month_low = (b13 >> 7) & 0x01
    month_raw = (month_high << 1) | month_low
    month = month_raw + 1 # 0-indexerad till 1-indexerad
    
    year_val = b13 & 0x1F
    year = 2000 + year_val
    
    return f"{day:02d}-{month:02d}-{year}"

def render_caracter_full(data: bytes) -> List[str]:
    out: List[str] = [f"{RÖD}---CARACTER.P01 (hela filen)---{VIT}"]
    out.extend(format_chunk_lines(data, per_row=8))
    return out

# ==============================
# WAYPOINT.P01
# ==============================

def parse_waypoint_count(header_part2: bytes) -> int:
    if len(header_part2) != 4: return 0
    _, b13, b14, _ = header_part2
    n1 = max(0, b13 - 129)
    n2 = b14 // 2
    return n1 if n1 == n2 else n1

# ==============================
# Skanning
# ==============================

def process_dir_for_unknown_line(d: Path) -> Optional[str]:
    files = {p.name.lower(): p for p in sorted(d.iterdir()) if p.is_file()}
    cfile = files.get("caracter.p01")
    if not cfile: return None

    try:
        data = cfile.read_bytes()
        
        # 1. Okända raden (Hex + Bits + Datum)
        unk_bytes = extract_unknown_line(data)
        hex_str = ""
        bin_str = ""
        bin_date_str = ""
        
        if unk_bytes:
            hex_str = " ".join(f"{b:02X}" for b in unk_bytes)
            # Skapa bit-sträng
            bin_str = f"{unk_bytes[0]:08b} {unk_bytes[1]:08b} {unk_bytes[2]:08b} {unk_bytes[3]:08b}"
            # Räkna ut binärt datum med nya formeln
            bin_date_str = decode_binary_date(unk_bytes)
        
        # 2. Datum (DTD Text)
        date_str = extract_dtd_date(data)
        
        if hex_str:
            # Format: Mappnamn | Hex | Bits | Bin-Date | DTD
            return (f"{MAGENTA}{d.name:<22}{VIT} "
                    f"HEX:{hex_str:<12} "
                    f"BITS:{CYAN}{bin_str:<36}{VIT} "
                    f"DATE:{GRÖN}{bin_date_str:<11}{VIT} "
                    f"DTD:{GUL}{date_str}{VIT}")
    except: pass
    return None

def process_dir_for_details(d: Path, min_wpts: int, max_wpts: int) -> List[str]:
    out: List[str] = []
    files = {p.name.lower(): p for p in sorted(d.iterdir()) if p.is_file()}
    cfile = files.get("caracter.p01")
    wfile = files.get("waypoint.p01")
    if not (cfile and wfile): return out

    try:
        wdata = wfile.read_bytes()
    except Exception as e: return [f"***{d.name}", f"Fel läsa wp: {e}", ""]

    if len(wdata) < 16: return [f"***{d.name}", "Wp fil för kort", ""]

    header2 = wdata[12:16]
    wp_count = parse_waypoint_count(header2)
    if wp_count > max_wpts or wp_count < min_wpts: return out

    out.append(f"{RÖD}***{d.name} ({wp_count} wpts){VIT}")
    
    try:
        car_data = cfile.read_bytes()
        out += render_caracter_full(car_data)
    except Exception as e: out.append(f"Fel läsa carac: {e}")

    out.append("")
    return out

# ==============================
# Main
# ==============================

def build_unknown_line_list(root: Path) -> List[str]:
    lines = [f"{MAGENTA}--- DATUM (BINÄRT vs TEXT) ---{VIT}", ""]
    for dirpath, _, _ in sorted(os.walk(root), key=lambda x: x[0].lower()):
        d = Path(dirpath)
        entry = process_dir_for_unknown_line(d)
        if entry: lines.append(entry)
    while lines and lines[-1] == "": lines.pop()
    return lines

def join_lines(lines: List[str]) -> str: return "\n".join(lines)

def ansi_to_html(ansi_text: str) -> str:
    out = []
    i = 0
    open_spans = 0
    s = ansi_text
    ESC = '\033['
    code_map = {'91m': 'red', '92m': 'green', '93m': 'yellow', '94m': 'blue', '95m': 'magenta', '96m': 'cyan', '0m': None}
    while i < len(s):
        if s.startswith(ESC, i):
            j = i + 2
            while j < len(s) and s[j] != 'm': j += 1
            if j < len(s):
                code = s[i+2:j+1]
                if code in code_map:
                    if code == '0m': 
                        if open_spans > 0: out.append('</span>'); open_spans -= 1
                    else: out.append(f'<span class="{code_map[code]}">'); open_spans += 1
                i = j + 1
                continue
        out.append(html.escape(s[i]))
        i += 1
    while open_spans > 0: out.append('</span>'); open_spans -= 1
    style = "<style>body{background:#111;color:#ddd}pre{font:13px monospace}.red{color:#ff5555}.green{color:#50fa7b}.blue{color:#61afef}.yellow{color:#e5c07b}.magenta{color:#bd93f9}.cyan{color:#8be9fd}</style>"
    return f"<!doctype html><meta charset='utf-8'>{style}<pre>{''.join(out)}</pre>"

def write_output(lines: List[str], out_path: str, fmt: str):
    text = join_lines(lines)
    if fmt == 'ansi': Path(out_path).write_text(text, encoding='utf-8')
    elif fmt == 'html': Path(out_path).write_text(ansi_to_html(text), encoding='utf-8')

DEFAULT_MIN_WPTS = 0
DEFAULT_MAX_WPTS = 120

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--out")
    ap.add_argument("--format", choices=["ansi", "html"], default="ansi")
    ap.add_argument("--maxwpts", nargs="?", const=8, type=int)
    ap.add_argument("--minwpts", nargs="?", const=0, type=int)
    args = ap.parse_args()

    root = Path(args.root)
    if not root.exists(): sys.exit(1)

    min_wpts = args.minwpts if args.minwpts is not None else DEFAULT_MIN_WPTS
    max_wpts = args.maxwpts if args.maxwpts is not None else DEFAULT_MAX_WPTS

    unk_list = build_unknown_line_list(root)
    det_lines = []
    for dirpath, _, _ in sorted(os.walk(root), key=lambda x: x[0].lower()):
        det_lines += process_dir_for_details(Path(dirpath), min_wpts, max_wpts)

    all_lines = unk_list + ["", "", f"{VIT}Detaljer:{VIT}", ""] + det_lines

    if not args.out: print("\n".join(all_lines))
    else: 
        write_output(all_lines, args.out, args.format)
        print(f"Skrev till {args.out}")

if __name__ == "__main__":
    main()