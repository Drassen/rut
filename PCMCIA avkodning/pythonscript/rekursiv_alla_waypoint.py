#!/usr/bin/env python3
import sys, os, argparse, html, struct
from pathlib import Path
from typing import List, Optional, Tuple

# ANSI-färgkoder
RÖD = '\033[91m'
GRÖN = '\033[92m'
GUL = '\033[93m'
BLÅ = '\033[94m'
VIT = '\033[0m'  # reset

COL_WIDTH = 8

def center_text(txt: str, width: int) -> str:
    pad = max(0, width - len(txt))
    left = pad // 2
    right = pad - left
    return ' ' * left + txt + ' ' * right

def format_chunk_lines(chunk: bytes, per_row: int) -> List[str]:
    """
    Växlar binär- och decimalrader, per_row bytes åt gången.
    """
    lines: List[str] = []
    for i in range(0, len(chunk), per_row):
        row = chunk[i:i+per_row]

        # Binärrad
        bin_tokens = []
        for b in row:
            bits = f"{b:08b}"
            bin_tokens.append(f"{BLÅ}{bits}{VIT}" if b != 0 else bits)
        lines.append(" ".join(bin_tokens))

        # Decimalrad
        dec_tokens = [f"{GRÖN}{center_text(str(b), COL_WIDTH)}{VIT}" for b in row]
        lines.append(" ".join(dec_tokens))
    return lines

def format_decimal_line(values: List[int], color: str = GUL) -> str:
    """
    EN rad med centrerade heltal.
    """
    return " ".join(f"{color}{center_text(str(v), COL_WIDTH)}{VIT}" for v in values)

# ==============================
# 6-bitarskodning
# ==============================

SIXBIT_DECODE_MAP = {
    0: "", 11: "-",
    14: "0", 15: "1", 16: "2", 17: "3", 18: "4",
    19: "5", 20: "6", 21: "7", 22: "8", 23: "9",
    30: "A", 31: "B", 32: "C", 33: "D", 34: "E", 35: "F",
    36: "G", 37: "H", 38: "I", 39: "J", 40: "K", 41: "L",
    42: "M", 43: "N", 44: "O", 45: "P", 46: "Q", 47: "R",
    48: "S", 49: "T", 50: "U", 51: "V", 52: "W", 53: "X",
    54: "Y", 55: "Z"
}

def sixbits_to_text(bits: List[int]) -> str:
    return "".join(SIXBIT_DECODE_MAP.get(v, " ") for v in bits).rstrip()

def unpack_6bit_groups_from_12_name_bytes(name12: bytes) -> List[int]:
    """3 × 32-bitblock, vardera med 2 pad-bitar → totalt 15 tecken (6 bit vardera)."""
    assert len(name12) == 12
    bitstream = ""
    for i in range(0, 12, 4):
        val = int.from_bytes(name12[i:i+4], "big")
        useful = val >> 2
        bitstream += f"{useful:030b}"
    return [int(bitstream[i:i+6], 2) for i in range(0, 90, 6)]

def unpack_6bit_groups_from_id_bytes(id4: bytes) -> List[int]:
    """32 bitar med ledande '1' och avslutande '0' → 5 grupper à 6 bit."""
    assert len(id4) == 4
    val = int.from_bytes(id4, "big")
    b = f"{val:032b}"
    core = b[1:31]
    return [int(core[i:i+6], 2) for i in range(0, 30, 6)]

def be_float32(b: bytes) -> float:
    return struct.unpack(">f", b)[0]

def decode_route(byte21: int) -> str:
    """Route kan vara 1..4 enligt värden 8→1, 16→2, 24→3, 32→4."""
    mapping = {8: "1", 16: "2", 24: "3", 32: "4"}
    return mapping.get(byte21, "0")

# ==============================
# CARACTER.P01 — endast waypoint-raden
# ==============================

CARAC_RADGRUPPER = [4, 8, 4, 12, 12, 12, 12, 4, 8, 4, 8, 4, 8, 4, 8]
WAYPOINT_GROUP_INDEX = 8

def is_magic_header(chunk: bytes) -> bool:
    return len(chunk) == 4 and tuple(chunk) == (0x55, 0xAA, 0x55, 0xAA)

def extract_caracter_waypoint_chunk(data: bytes) -> Optional[bytes]:
    idx = 0
    for gi, size in enumerate(CARAC_RADGRUPPER):
        if idx + size > len(data):
            break
        chunk = data[idx:idx+size]
        if gi == 0 and is_magic_header(chunk):
            idx += size
            continue
        if gi == WAYPOINT_GROUP_INDEX:
            return chunk
        idx += size
    return None

def render_caracter_waypoint_only(data: bytes) -> List[str]:
    out: List[str] = []
    chunk = extract_caracter_waypoint_chunk(data)
    if chunk:
        out.append(f"{RÖD}---CARACTER.P01---{VIT}")
        # 4 bytes per rad
        out.extend(format_chunk_lines(chunk, per_row=4))
    return out

# ==============================
# WAYPOINT.P01
# ==============================

def parse_waypoint_count(header_part2: bytes) -> int:
    if len(header_part2) != 4:
        return 0
    _, b13, b14, _ = header_part2
    n1 = max(0, b13 - 129)
    n2 = b14 // 2
    return n1 if n1 == n2 else n1

def split_waypoints(wdata: bytes) -> Tuple[bytes, bytes, List[bytes]]:
    """
    Returnerar (header0_12bytes, header2_4bytes, lista av wp-poster à 28 bytes).
    header0 = wdata[0:12] (skrivs ut och ingår i summering)
    header2 = wdata[12:16] (checksum-headern, skrivs ut och ingår i summering)
    """
    if len(wdata) < 16:
        return b"", b"", []
    header0 = wdata[0:12]
    idx = 12
    header2 = wdata[idx:idx+4]
    idx += 4
    wp_count = parse_waypoint_count(header2)
    wps: List[bytes] = []
    for _ in range(wp_count):
        if idx + 28 > len(wdata):
            break
        wps.append(wdata[idx:idx+28])
        idx += 28
    return header0, header2, wps

def compute_four_column_sums_all(header0: bytes, header2: bytes, wps: List[bytes]) -> List[int]:
    """
    Summera ALLA bytes vi skriver ut från WAYPOINT.P01:
      - header0 (0..11)
      - header2 (12..15, checksum-headern)
      - samtliga waypoint-poster (28 bytes vardera)
    i 4 kolumner definierade av (global byteindex % 4).
    """
    sums = [0, 0, 0, 0]
    col = 0

    for b in header0:
        sums[col] += b
        col = (col + 1) % 4

    for b in header2:
        sums[col] += b
        col = (col + 1) % 4

    for wp in wps:
        for b in wp:
            sums[col] += b
            col = (col + 1) % 4

    return sums

def render_waypoint_file(data: bytes) -> List[str]:
    out: List[str] = []
    if len(data) < 16:
        return out

    header0, header2, wps = split_waypoints(data)

    # Skriv ut första 12 bytes (0..11)
    out.append(f"{RÖD}---WAYPOINT.P01 header (0..11)---{VIT}")
    out.extend(format_chunk_lines(header0, per_row=4))

    # Skriv ut checksum-headern (12..15)
    out.append(f"{RÖD}---WAYPOINT.P01 checksum header---{VIT}")
    out.extend(format_chunk_lines(header2, per_row=4))

    # Waypoints
    for i, wp in enumerate(wps):
        lat_b, lng_b, name_b, flags_b, id_b = wp[0:4], wp[4:8], wp[8:20], wp[20:24], wp[24:28]

        try:
            lat, lng = be_float32(lat_b), be_float32(lng_b)
        except Exception:
            lat, lng = float('nan'), float('nan')

        try:
            name_txt = sixbits_to_text(unpack_6bit_groups_from_12_name_bytes(name_b))
        except Exception:
            name_txt = ""
        try:
            id_txt = sixbits_to_text(unpack_6bit_groups_from_id_bytes(id_b))
        except Exception:
            id_txt = ""

        route_txt = decode_route(flags_b[1]) if len(flags_b) >= 2 else "0"

        out.append(
            f"{RÖD}---Wpt {i+1}--------------------------------- "
            f"name: {VIT}{name_txt}{RÖD} id: {VIT}{id_txt}{RÖD} lat: {VIT}{lat:.6f}{RÖD} long: {VIT}{lng:.6f}{RÖD} route: {VIT}{route_txt}{VIT}"
        )

        out.extend(format_chunk_lines(lat_b,  per_row=4))
        out.extend(format_chunk_lines(lng_b,  per_row=4))
        out.extend(format_chunk_lines(name_b, per_row=4))
        out.extend(format_chunk_lines(flags_b, per_row=4))
        out.extend(format_chunk_lines(id_b,   per_row=4))

    return out

# ==============================
# Skanning av kataloger
# ==============================

def title_line(dirname: str, suffix: str = "", total_len: int = 77) -> str:
    plain = f"***{dirname}{suffix}"
    stars = "*" * max(0, total_len - len(plain))
    return f"{RÖD}{plain}{VIT}{stars}"

def process_dir(d: Path, min_wpts: int, max_wpts: int) -> List[str]:
    files = {p.name.lower(): p for p in sorted(d.iterdir()) if p.is_file()}
    cfile = files.get("caracter.p01")
    wfile = files.get("waypoint.p01")
    if not (cfile and wfile):
        return []

    try:
        wdata = wfile.read_bytes()
    except Exception as e:
        return [title_line(d.name), f"[Fel vid läsning av {wfile}: {e}]", ""]

    if len(wdata) < 16:
        return [title_line(d.name), "[Fel: WAYPOINT.P01 är kortare än 16 bytes]", ""]

    header2 = wdata[12:16]
    wp_count = parse_waypoint_count(header2)
    if wp_count > max_wpts or wp_count < min_wpts:
        return []

    # Suffix med enbart antal waypoints
    suffix = f" ({wp_count}st waypoints)"
    out: List[str] = [title_line(d.name, suffix=suffix)]

    # 1) CARACTER-byten
    try:
        out += render_caracter_waypoint_only(cfile.read_bytes())
    except Exception as e:
        out.append(f"[Fel vid läsning av {cfile}: {e}]")

    # 2) MODULO-rad för WAYPOINT (ovanför waypointlistningen)
    #    Summerar header0 + header2 + alla waypoints i 4 kolumner.
    header0, header2, wps = split_waypoints(wdata)
    if header0 or header2:
        sums4 = compute_four_column_sums_all(header0, header2, wps)
        sums4_modulo256 = [s & 0xFF for s in sums4]
        counts_mod = [s // 256 for s in sums4]

        out.append("- kolumnsumma")
        out.append(format_decimal_line(sums4, color=GUL))

        # NY RAD: antal 256-block (sum // 256) per kolumn
        out.append("-antal modulo")
        out.append(format_decimal_line(counts_mod, color=GUL))

    # 3) WAYPOINT-detaljer
    try:
        out += render_waypoint_file(wdata)
    except Exception as e:
        out.append(f"[Fel vid render av {wfile}: {e}]")

    out.append("")
    return out

# ==============================
# Sammanfattning
# ==============================

def render_summary_entry(dirname: str, wp_count: int, caracter_chunk: Optional[bytes]) -> List[str]:
    out = [f"{RÖD}***{dirname}***{VIT}---CARACTER.P01--- {wp_count}st waypoints"]
    if caracter_chunk:
        # Sammanfattningen: 8 bytes per rad (bin/dec)
        out.extend(format_chunk_lines(caracter_chunk, per_row=8))
    return out

def build_summary(root: Path, min_wpts: int, max_wpts: int) -> List[str]:
    lines = ["Sammanfattning av waypointraden i caracterfilerna:", ""]
    for dirpath, _, _ in sorted(os.walk(root), key=lambda x: x[0].lower()):
        d = Path(dirpath)
        files = {p.name.lower(): p for p in sorted(d.iterdir()) if p.is_file()}
        cfile, wfile = files.get("caracter.p01"), files.get("waypoint.p01")
        if not (cfile and wfile):
            continue
        try:
            wdata = wfile.read_bytes()
        except Exception:
            continue
        if len(wdata) < 16:
            continue
        header2 = wdata[12:16]
        wp_count = parse_waypoint_count(header2)
        if wp_count > max_wpts or wp_count < min_wpts:
            continue
        try:
            chunk = extract_caracter_waypoint_chunk(cfile.read_bytes())
        except Exception:
            chunk = None
        lines.extend(render_summary_entry(d.name, wp_count, chunk))
    while lines and lines[-1] == "":
        lines.pop()
    return lines

# ==============================
# Utskrift & Main
# ==============================

def join_lines(lines: List[str]) -> str:
    return "\n".join(lines)

def ansi_to_html(ansi_text: str) -> str:
    out = []
    i = 0
    open_spans = 0
    s = ansi_text

    def open_span(cls):
        nonlocal open_spans
        out.append(f'<span class="{cls}">')
        open_spans += 1

    def close_span():
        nonlocal open_spans
        if open_spans > 0:
            out.append('</span>')
            open_spans -= 1

    ESC = '\033['
    code_map = {'91m': 'red', '92m': 'green', '93m': 'yellow', '94m': 'blue', '0m': None}

    while i < len(s):
        if s.startswith(ESC, i):
            j = i + 2
            while j < len(s) and s[j] != 'm':
                j += 1
            if j < len(s):
                code = s[i+2:j+1]
                if code in code_map:
                    if code == '0m': close_span()
                    else: open_span(code_map[code])
                i = j + 1
                continue
        out.append(html.escape(s[i]))
        i += 1

    while open_spans > 0:
        close_span()

    style = """
    <style>
      body { background: #111; color: #ddd; }
      pre { font: 13px/1.3 ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; }
      .red { color: #ff5555; }
      .green { color: #50fa7b; }
      .blue { color: #61afef; }
      .yellow { color: #e5c07b; }
    </style>
    """
    return f"<!doctype html><meta charset='utf-8'>{style}<pre>{''.join(out)}</pre>"

def write_output(lines: List[str], out_path: str, fmt: str):
    text = join_lines(lines)
    if fmt == 'ansi':
        Path(out_path).write_text(text, encoding='utf-8')
    elif fmt == 'html':
        Path(out_path).write_text(ansi_to_html(text), encoding='utf-8')
    else:
        raise ValueError("Okänt format: använd 'ansi' eller 'html'.")

DEFAULT_MIN_WPTS = 0
DEFAULT_MAX_WPTS = 120

def main():
    ap = argparse.ArgumentParser(description="Sammanställ CARACTER.P01 + WAYPOINT.P01 med färger och klartext.")
    ap.add_argument("root", help="Rotkatalog att skanna")
    ap.add_argument("--out", help="Skriv utdata till fil")
    ap.add_argument("--format", choices=["ansi", "html"], default="ansi")
    ap.add_argument(
        "--maxwpts",
        nargs="?",
        const=8,
        type=int,
        help="ta endast med filer med högst N waypoints (implicit 8 om inget värde anges)"
    )
    ap.add_argument(
        "--minwpts",
        nargs="?",
        const=0,
        type=int,
        help="ta endast med filer med minst N waypoints (implicit 0 om inget värde anges)"
    )
    args = ap.parse_args()

    root = Path(args.root)
    if not root.exists() or not root.is_dir():
        print(f"Fel: {root} är ingen katalog.", file=sys.stderr)
        sys.exit(1)

    min_wpts = args.minwpts if args.minwpts is not None else DEFAULT_MIN_WPTS
    max_wpts = args.maxwpts if args.maxwpts is not None else DEFAULT_MAX_WPTS

    # 1) Sammanfattning
    summary_lines = build_summary(root, min_wpts, max_wpts)

    # Ta bort släpande tomrader och lägg till rubriken
    while summary_lines and summary_lines[-1] == "":
        summary_lines.pop()
    summary_lines += [
        "",
        "",
        f"{VIT}Listning av waypointrad i caracterfilen, samt dess tillhörande waypointfil:{VIT}",
        ""
    ]

    # 2) Detaljer per katalog (alfabetisk ordning)
    detail_lines = []
    for dirpath, _, _ in sorted(os.walk(root), key=lambda x: x[0].lower()):
        detail_lines.extend(process_dir(Path(dirpath), min_wpts, max_wpts))

    all_lines = summary_lines + detail_lines

    # 3) Utskrift eller fil
    if not args.out:
        print("\n".join(all_lines))
    else:
        write_output(all_lines, args.out, args.format)
        print(f"Skrev utdata till {args.out} ({args.format}).")

if __name__ == "__main__":
    main()
