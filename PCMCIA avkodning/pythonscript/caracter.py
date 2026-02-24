#!/usr/bin/env python3
import sys
from pathlib import Path

# ANSI-färgkoder
RÖD = '\033[91m'
GRÖN = '\033[92m'
GUL = '\033[93m'
BLÅ = '\033[94m'
VIT = '\033[0m'  # reset

# --- Specifik radindelning (antal bytes per rad) enligt ditt exempel ---
RADGRUPPER = [
    4,
    8,
    4,
    12,
    12,
    12,
    12,
    4,
    8,   # <-- label: Waypoint
    4,
    8,   # <-- label: Airport
    4,
    8,   # <-- label: Navaid
    4,
    8    # <-- label: Route
]

# Etiketter att skriva ut PRECIS före vissa grupper (index räknat från 0)
LABELS_BY_GROUP_INDEX = {
    8:  "---Waypoint---",
    10: "---Airport---",
    12: "---Navaid---",
    14: "---Route---",
}

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
            bin_tokens.append(f"{BLÅ}{bits}{VIT}")
        else:
            bin_tokens.append(bits)
    bin_line = " ".join(bin_tokens)

    dec_tokens = []
    for b in byte_chunk:
        centered = center_text(str(b), COL_WIDTH)
        dec_tokens.append(f"{GRÖN}{centered}{VIT}")
    dec_line = " ".join(dec_tokens)
    return bin_line, dec_line

def is_4x0(chunk: bytes) -> bool:
    return len(chunk) == 4 and all(b == 0 for b in chunk)

def is_head_plus_zeros(chunk: bytes) -> bool:
    """Standardrad att SKIPPA: första byte ≠ 0, övriga byte = 0."""
    return len(chunk) > 4 and chunk[0] != 0 and all(b == 0 for b in chunk[1:])

def is_magic_header(chunk: bytes) -> bool:
    """Matchar exakt 01010101 10101010 01010101 10101010 (0x55,0xAA,0x55,0xAA)."""
    return len(chunk) == 4 and tuple(chunk) == (0x55, 0xAA, 0x55, 0xAA)

def main():
    if len(sys.argv) < 2:
        print("Användning: python3 dump_caracter.py <filnamn>")
        sys.exit(1)

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"Fel: Filen {path} hittades inte.", file=sys.stderr)
        sys.exit(1)

    data = path.read_bytes()
    idx = 0
    group_index = 0
    pending_blankline = False  # tomrad från en tidigare 4x0-grupp

    def flush_blankline_if_needed(next_has_label: bool):
        nonlocal pending_blankline
        if pending_blankline:
            if not next_has_label:
                print()
            pending_blankline = False

    while idx < len(data) and group_index < len(RADGRUPPER):
        gsize = RADGRUPPER[group_index]
        chunk = data[idx:idx + gsize]

        label = LABELS_BY_GROUP_INDEX.get(group_index)
        flush_blankline_if_needed(next_has_label=(label is not None))

        # Särskild regel: skippa första gruppen helt om den är magisk header
        if group_index == 0 and is_magic_header(chunk):
            idx += gsize
            group_index += 1
            continue

        if label:
            print(f"{RÖD}{label}{VIT}")  # <--- titel i rött

        if is_4x0(chunk):
            pending_blankline = True
        elif is_head_plus_zeros(chunk):
            pass  # skippa helt
        else:
            bin_line, dec_line = format_binary_and_dec_lines(chunk)
            print(bin_line)
            print(dec_line)

        idx += gsize
        group_index += 1

    # Hantera eventuell rest (utöver fördefinierade grupper)
    if idx < len(data):
        rest = data[idx:]
        flush_blankline_if_needed(next_has_label=False)

        if is_4x0(rest):
            pending_blankline = True
        elif is_head_plus_zeros(rest):
            pass
        else:
            bin_line, dec_line = format_binary_and_dec_lines(rest)
            print(bin_line)
            print(dec_line)

    if pending_blankline:
        print()

if __name__ == "__main__":
    main()
