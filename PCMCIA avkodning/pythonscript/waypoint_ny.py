#!/usr/bin/env python3
import sys
from pathlib import Path

# ANSI-färgkoder
ROD = '\033[91m'
GRON = '\033[92m'
GUL = '\033[93m'
BLA = '\033[94m'
VIT = '\033[0m'  # reset

COL_WIDTH = 8  # 8 bitar per byte => 8 kolumntecken (monospace)

def center_text(txt: str, width: int) -> str:
    pad = max(0, width - len(txt))
    left = pad // 2
    right = pad - left
    return ' ' * left + txt + ' ' * right

def format_binary_and_dec_lines(byte_chunk: bytes):
    """Returnerar (bin_raden, dec_raden) med färg och centrerad decimal under varje byte."""
    bin_tokens = []
    for b in byte_chunk:
        bits = f"{b:08b}"
        if b != 0:
            bin_tokens.append(f"{BLA}{bits}{VIT}")
        else:
            bin_tokens.append(bits)
    bin_line = " ".join(bin_tokens)

    dec_tokens = []
    for b in byte_chunk:
        centered = center_text(str(b), COL_WIDTH)
        dec_tokens.append(f"{GRON}{centered}{VIT}")
    dec_line = " ".join(dec_tokens)
    return bin_line, dec_line

def print_group(chunk: bytes):
    """Skriv en grupp med binär rad och underliggande centrerad sifferrad."""
    bin_line, dec_line = format_binary_and_dec_lines(chunk)
    print(bin_line)
    print(dec_line)

def main():
    if len(sys.argv) < 2:
        print("Användning: python3 dump_waypoint.py <WAYPOINT.P01>")
        sys.exit(1)

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"Fel: Filen {path} hittades inte.", file=sys.stderr)
        sys.exit(1)

    data = path.read_bytes()
    n = len(data)
    if n < 16:
        print("Fel: Filen är kortare än 16 bytes (saknar header).", file=sys.stderr)
        sys.exit(1)

    # --- Header ---
    idx = 0
    # Bytes 0–11 finns men skrivs ej i denna layout
    idx += 12
    header_part2 = data[idx:idx+4]    # bytes 12–15
    idx += 4

    # Räkna ut antal waypoints enligt spec:
    b12, b13, b14, b15 = header_part2
    count_from_b13 = max(0, b13 - 129)
    count_from_b14 = b14 // 2
    waypoint_count = count_from_b13 if count_from_b13 == count_from_b14 else count_from_b13

    # --- Checksum-header ---
    print(f"{ROD}---Checksum header---{VIT}")
    print_group(header_part2)

    # --- Waypoints ---
    for i in range(waypoint_count):
        if idx + 28 > n:
            break  # slut på data
        wp = data[idx:idx+28]
        idx += 28

        lat   = wp[0:4]
        lng   = wp[4:8]
        name  = wp[8:20]
        flags = wp[20:24]
        wid   = wp[24:28]

        # Röd titelrad för varje waypoint
        print(f"{ROD}---Wpt {i+1}---------------------------------{VIT}")
        print_group(lat)
        print_group(lng)
        print_group(name)
        print_group(flags)
        print_group(wid)

if __name__ == "__main__":
    main()
