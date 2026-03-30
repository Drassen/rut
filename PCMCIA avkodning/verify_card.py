#!/usr/bin/env python3
"""
A109 PCMCIA Card Verifier
=========================
Comprehensive verification of all 6 A109 PCMCIA files:
  PILOTE.HD, AIRPORT.P01, NAVAID.P01, WAYPOINT.P01, ROUTE.P01, CARACTER.P01

Usage:
  python3 verify_card.py <card_folder>

Exit code 0 = all checks passed, 1 = errors found.
"""

import struct
import sys
import os
import math


# ============================================================
# 6-BIT CODEC
# ============================================================

CHAR_TO_CODE = {
    '-': 11,
    '0': 14, '1': 15, '2': 16, '3': 17, '4': 18,
    '5': 19, '6': 20, '7': 21, '8': 22, '9': 23,
    'A': 30, 'B': 31, 'C': 32, 'D': 33, 'E': 34,
    'F': 35, 'G': 36, 'H': 37, 'I': 38, 'J': 39,
    'K': 40, 'L': 41, 'M': 42, 'N': 43, 'O': 44,
    'P': 45, 'Q': 46, 'R': 47, 'S': 48, 'T': 49,
    'U': 50, 'V': 51, 'W': 52, 'X': 53, 'Y': 54,
    'Z': 55
}
CODE_TO_CHAR = {v: k for k, v in CHAR_TO_CODE.items()}


def encode_6bit(text: str, max_chars: int, total_bytes: int) -> bytes:
    """Encode string into A109 6-bit packed format (5 chars per 4 bytes)."""
    upper = text.upper()
    codes = []
    for ch in upper:
        if len(codes) >= max_chars:
            break
        codes.append(CHAR_TO_CODE.get(ch, 0))
    while len(codes) < max_chars:
        codes.append(0)

    out = []
    for chunk_idx in range((max_chars + 4) // 5):
        start = chunk_idx * 5
        end = min(start + 5, max_chars)
        chunk = codes[start:end]
        val = 0
        for i, code in enumerate(chunk):
            val |= (code & 0x3F) << (26 - i * 6)
        out += [(val >> 24) & 0xFF, (val >> 16) & 0xFF, (val >> 8) & 0xFF, val & 0xFF]

    result = bytes(out[:total_bytes])
    if len(result) < total_bytes:
        result += b'\x00' * (total_bytes - len(result))
    return result


def decode_6bit(data: bytes) -> str:
    """Decode A109 6-bit packed bytes to string. Stops at code=0 (null terminator)."""
    result = ''
    i = 0
    while i + 4 <= len(data):
        val32 = struct.unpack('>I', data[i:i+4])[0]
        for s in [26, 20, 14, 8, 2]:
            code = (val32 >> s) & 0x3F
            if code == 0:
                return result
            ch = CODE_TO_CHAR.get(code)
            result += ch if ch else '?'
        i += 4
    return result


def encode_wpt_id(text: str) -> bytes:
    """Waypoint ID special encoding: standard encode, then shift right 1, MSB=1."""
    standard = encode_6bit(text, max_chars=5, total_bytes=4)
    val32 = struct.unpack('>I', standard)[0]
    shifted = (val32 >> 1) | 0x80000000
    return struct.pack('>I', shifted & 0xFFFFFFFF)


def decode_wpt_id(data: bytes) -> str:
    """Decode waypoint ID special encoding: remove MSB, shift left 1, then standard decode."""
    val32 = struct.unpack('>I', data[:4])[0]
    raw = val32 & 0x7FFFFFFF
    restored = (raw << 1) & 0xFFFFFFFF
    return decode_6bit(struct.pack('>I', restored))


# ============================================================
# CHECKSUM  (matches A109PCMCIAExportService.twoSigned16Sums)
# ============================================================

def compute_checksum(data: bytes):
    """
    Returns (sumLo, sumHi) as signed int32.
    Iterates in 4-byte steps; sumLo accumulates bytes[i:i+2] as int16 BE,
    sumHi accumulates bytes[i+2:i+4] as int16 BE. Wraps at 32 bits.
    """
    sum_lo = 0
    sum_hi = 0
    i = 0
    while i < len(data):
        if i + 1 < len(data):
            word = struct.unpack('>h', data[i:i+2])[0]
            sum_lo = (sum_lo + word) & 0xFFFFFFFF
        if i + 3 < len(data):
            word = struct.unpack('>h', data[i+2:i+4])[0]
            sum_hi = (sum_hi + word) & 0xFFFFFFFF
        i += 4
    # Convert unsigned 32-bit to signed int32
    if sum_lo >= 0x80000000:
        sum_lo -= 0x100000000
    if sum_hi >= 0x80000000:
        sum_hi -= 0x100000000
    return sum_lo, sum_hi


# ============================================================
# PRESENCE BITS
# ============================================================

def read_presence_count(header_13bytes: bytes) -> int:
    """Count how many presence bits (MSB-first, max 100) are set."""
    count = 0
    for i in range(100):
        byte_idx = i // 8
        bit_in_byte = 7 - (i % 8)
        if (header_13bytes[byte_idx] >> bit_in_byte) & 1:
            count += 1
    return count


def check_presence_bits(header_13bytes: bytes, expected_count: int):
    """
    Verify first N bits are 1, rest 0 (MSB-first across 13 bytes, max 100 records).
    Returns (ok: bool, message: str).
    """
    errors = []
    for i in range(100):
        byte_idx = i // 8
        bit_in_byte = 7 - (i % 8)
        bit = (header_13bytes[byte_idx] >> bit_in_byte) & 1
        expected_bit = 1 if i < expected_count else 0
        if bit != expected_bit:
            errors.append(f"bit{i}:got {bit} expected {expected_bit}")
    # Also check bits 100-103 (remaining bits in the 13th byte) are 0
    b12 = header_13bytes[12]
    if b12 & 0x0F:
        errors.append(f"byte12 lower nibble={b12 & 0x0F:#x} (should be 0)")
    if errors:
        return False, f"Presence bit errors ({len(errors)}): {'; '.join(errors[:5])}" + (" ..." if len(errors) > 5 else "")
    return True, f"All {expected_count} presence bits correct (first {expected_count} set, rest 0)"


# ============================================================
# REPORTER
# ============================================================

class Reporter:
    def __init__(self):
        self.errors = []
        self.warnings = []
        self._section = ""

    def section(self, title: str):
        self._section = title
        print(f"\n{'=' * 62}")
        print(f"  {title}")
        print(f"{'=' * 62}")

    def ok(self, msg: str):
        print(f"  [OK]   {msg}")

    def fail(self, msg: str):
        self.errors.append(f"{self._section}: {msg}")
        print(f"  [FAIL] {msg}")

    def warn(self, msg: str):
        self.warnings.append(f"{self._section}: {msg}")
        print(f"  [WARN] {msg}")

    def info(self, msg: str):
        print(f"         {msg}")

    def summary(self):
        print(f"\n{'=' * 62}")
        print(f"  VERIFICATION SUMMARY")
        print(f"{'=' * 62}")
        if not self.errors and not self.warnings:
            print("  RESULT: ALL CHECKS PASSED")
        elif not self.errors:
            print(f"  RESULT: PASSED WITH {len(self.warnings)} WARNING(S)")
        else:
            print(f"  RESULT: FAILED — {len(self.errors)} ERROR(S), {len(self.warnings)} WARNING(S)")

        if self.errors:
            print(f"\n  ERRORS ({len(self.errors)}):")
            for e in self.errors:
                print(f"    - {e}")
        if self.warnings:
            print(f"\n  WARNINGS ({len(self.warnings)}):")
            for w in self.warnings:
                print(f"    - {w}")
        print()


# ============================================================
# HELPERS
# ============================================================

def read_float_be(data: bytes, offset: int) -> float:
    return struct.unpack('>f', data[offset:offset+4])[0]


def is_valid_float(f: float) -> bool:
    return not math.isnan(f) and not math.isinf(f)


def parse_pilote_date_string(s: str):
    """
    Parse PILOTE date string in two formats:
      iOS format: "DTDd%02d%04d" e.g. "DTD6042026" (month zero-padded to 2 digits)
      DAP format: "DTDd%d%04d"  e.g. "DTD642026"  (month without leading zero)
    Returns (day, month, year) or None on failure.
    Year is always 4 digits. Month is 1-2 digits. Day is 1-2 digits.
    Algorithm: year = last 4 chars; try 2-digit month first, then 1-digit.
    """
    s = s.strip()
    if not s.startswith("DTD"):
        return None
    rest = s[3:]
    if len(rest) < 6:  # minimum: "1" + "1" + "2000" = 6 chars
        return None
    try:
        year = int(rest[-4:])
        remaining = rest[:-4]
        if not remaining:
            return None

        # Try 2-digit month first (iOS style, e.g. remaining="2503")
        if len(remaining) >= 3:
            month_try = int(remaining[-2:])
            day_try   = int(remaining[:-2]) if len(remaining) > 2 else 0
            if 1 <= month_try <= 12 and 1 <= day_try <= 31:
                return day_try, month_try, year

        # Try 1-digit month (DAP style, e.g. remaining="64" → day=6 month=4)
        if len(remaining) >= 2:
            month_try = int(remaining[-1:])
            day_try   = int(remaining[:-1])
            if 1 <= month_try <= 12 and 1 <= day_try <= 31:
                return day_try, month_try, year

        return None
    except ValueError:
        return None


def verify_db_header(data: bytes, count: int, r: Reporter):
    """Verify the 16-byte database file header common to AIRPORT/NAVAID/WAYPOINT/ROUTE."""
    ok, msg = check_presence_bits(data[:13], count)
    if ok:
        r.ok(msg)
    else:
        r.fail(msg)

    actual_count = read_presence_count(data[:13])
    if actual_count != count:
        r.fail(f"Presence bits set count={actual_count} but using claimed count={count}")

    expected_b13 = 128 if count == 100 else (129 + count)
    b13 = data[13]
    if b13 != expected_b13:
        r.fail(f"byte13={b13:#04x} expected {expected_b13:#04x} (for {count} records)")
    else:
        r.ok(f"byte13={b13:#04x} correct")

    expected_b14 = (count * 2) & 0xFF
    b14 = data[14]
    if b14 != expected_b14:
        r.fail(f"byte14={b14:#04x} expected {expected_b14:#04x} (count×2)")
    else:
        r.ok(f"byte14={b14:#04x} correct (count×2={count * 2})")

    b15 = data[15]
    if b15 != 0:
        r.fail(f"byte15={b15:#04x} expected 0x00")
    else:
        r.ok(f"byte15=0x00 correct")


# ============================================================
# VERIFY PILOTE.HD
# ============================================================

def verify_pilote(path: str, r: Reporter, file_sizes: dict):
    """
    PILOTE.HD format:
      bytes  0-11 : ASCII date string "DTDd+MM+YYYY" padded with spaces to 12 bytes
      bytes 12-15 : uint32 BE year
      bytes 16-19 : uint32 BE month
      bytes 20-23 : uint32 BE day
      bytes 24-27 : uint32 BE airport file size
      bytes 28-31 : uint32 BE navaid file size
      bytes 32-35 : uint32 BE waypoint file size
      bytes 36-39 : uint32 BE route file size
      bytes 40-43 : uint32 BE caracter file size
    Total: 44 bytes
    """
    r.section("PILOTE.HD")

    if not os.path.exists(path):
        r.fail(f"File not found: {path}")
        return None

    data = open(path, 'rb').read()
    r.info(f"File size: {len(data)} bytes  (expected 44)")

    if len(data) != 44:
        r.fail(f"Wrong size: {len(data)} (expected 44)")
        return None
    r.ok("File size = 44 bytes")

    try:
        date_str = data[:12].decode('ascii').rstrip()
    except UnicodeDecodeError:
        r.fail(f"Date field not ASCII: {data[:12].hex()}")
        return None

    r.info(f"ASCII date field: '{date_str}'")
    parsed = parse_pilote_date_string(date_str)
    if not parsed:
        r.fail(f"Cannot parse date string '{date_str}' (expected DTDd+MMddddYYYY)")
        return None

    day, month, year = parsed
    r.ok(f"ASCII date parsed: {day:02d}/{month:02d}/{year}")

    if not (1 <= month <= 12):
        r.fail(f"Invalid month: {month}")
    if not (1 <= day <= 31):
        r.fail(f"Invalid day: {day}")
    if not (2000 <= year <= 2099):
        r.warn(f"Unusual year: {year}")

    hd_year, hd_month, hd_day, apt_sz, nav_sz, wpt_sz, rte_sz, car_sz = struct.unpack('>8I', data[12:44])
    r.info(f"Binary fields: year={hd_year} month={hd_month} day={hd_day}")
    r.info(f"File sizes:    airport={apt_sz}  navaid={nav_sz}  waypoint={wpt_sz}  route={rte_sz}  caracter={car_sz}")

    if hd_year != year or hd_month != month or hd_day != day:
        r.fail(f"Binary date {hd_day}/{hd_month}/{hd_year} != ASCII date {day}/{month}/{year}")
    else:
        r.ok(f"Binary date matches ASCII date: {day:02d}/{month:02d}/{year}")

    for label, key, stored in [
        ('airport_size',  'AIRPORT.P01',  apt_sz),
        ('navaid_size',   'NAVAID.P01',   nav_sz),
        ('waypoint_size', 'WAYPOINT.P01', wpt_sz),
        ('route_size',    'ROUTE.P01',    rte_sz),
        ('caracter_size', 'CARACTER.P01', car_sz),
    ]:
        actual = file_sizes.get(key)
        if actual is None:
            r.warn(f"{label}={stored} — {key} not found, cannot verify")
        elif stored != actual:
            r.fail(f"{label}={stored} but actual {key}={actual} bytes")
        else:
            r.ok(f"{label}={stored} matches {key}")

    return {'day': day, 'month': month, 'year': year}


# ============================================================
# VERIFY AIRPORT.P01
# ============================================================

def verify_airport(path: str, r: Reporter) -> list:
    """
    AIRPORT.P01 format:
      Header (16 bytes):
        bytes  0-12 : presence bits, MSB-first, 1 bit per record
        byte    13  : 128 (if count=100) else 129+count
        byte    14  : count * 2
        byte    15  : 0x00
      Records (100 × 40 bytes = 4000 bytes):
        bytes  0-3  : ID, 6-bit encoded (5 chars, 4 bytes)
        bytes  4-11 : Name, 6-bit encoded (10 chars, 8 bytes)
        bytes 12-15 : rawUnknown1 (preserved verbatim on import)
        bytes 16-19 : usage flags  (byte17: 6=unused, 14=used×1, 30=used×2+)
        bytes 20-23 : latitude  float32 BE
        bytes 24-27 : longitude float32 BE
        bytes 28-31 : longest runway (preserved verbatim)
        bytes 32-35 : magnetic variation float32 BE
        bytes 36-39 : elevation float32 BE
      Total: 4020 bytes
    """
    r.section("AIRPORT.P01")

    if not os.path.exists(path):
        r.fail(f"File not found: {path}")
        return []

    data = open(path, 'rb').read()
    r.info(f"File size: {len(data)} bytes  (expected 4020)")

    if len(data) != 4020:
        r.fail(f"Wrong size: {len(data)}")
    else:
        r.ok("File size = 4020 bytes")

    count = read_presence_count(data[:13])
    r.info(f"Record count (from presence bits): {count}")
    verify_db_header(data, count, r)

    airports = []
    errors = 0

    for i in range(100):
        offset = 16 + i * 40
        if offset + 40 > len(data):
            break
        rec = data[offset:offset+40]

        if i < count:
            ap_id   = decode_6bit(rec[0:4]).strip()
            ap_name = decode_6bit(rec[4:12]).strip()
            usage_b17 = rec[17]
            lat  = read_float_be(rec, 20)
            lon  = read_float_be(rec, 24)
            magvar = read_float_be(rec, 32)
            elev = read_float_be(rec, 36)

            local_err = False
            if not ap_id:
                r.fail(f"Airport[{i}]: empty ID (bytes: {rec[0:4].hex()})")
                errors += 1; local_err = True

            if not is_valid_float(lat):
                r.fail(f"Airport[{i}] '{ap_id}': latitude is NaN/Inf")
                errors += 1; local_err = True
            elif not (-90.0 <= lat <= 90.0):
                r.fail(f"Airport[{i}] '{ap_id}': lat={lat:.6f} out of range [-90, 90]")
                errors += 1; local_err = True

            if not is_valid_float(lon):
                r.fail(f"Airport[{i}] '{ap_id}': longitude is NaN/Inf")
                errors += 1; local_err = True
            elif not (-180.0 <= lon <= 180.0):
                r.fail(f"Airport[{i}] '{ap_id}': lon={lon:.6f} out of range [-180, 180]")
                errors += 1; local_err = True

            # Known usage values: iOS=(6 unused, 14 used×1, 30 used×2+), DAP=(2, 10)
            if usage_b17 not in (2, 6, 10, 14, 30):
                r.warn(f"Airport[{i}] '{ap_id}': byte17={usage_b17} unknown (iOS:6/14/30, DAP:2/10)")

            if not is_valid_float(elev):
                r.warn(f"Airport[{i}] '{ap_id}': elevation is NaN/Inf")

            airports.append({'id': ap_id, 'name': ap_name, 'lat': lat, 'lon': lon})
            r.info(f"Airport[{i:3d}]  ID={ap_id:<6} Name={ap_name:<12} "
                   f"Lat={lat:9.4f} Lon={lon:10.4f} Usage={usage_b17:2d} Elev={elev:.0f}m "
                   f"MagVar={magvar:.1f}")
        else:
            if any(b != 0 for b in rec):
                r.warn(f"Airport[{i}]: inactive slot is not all zeros")

    if errors == 0:
        r.ok(f"All {count} airport records valid")
    else:
        r.fail(f"{errors} error(s) found across airport records")

    return airports


# ============================================================
# VERIFY NAVAID.P01
# ============================================================

def verify_navaid(path: str, r: Reporter) -> list:
    """
    NAVAID.P01 format (same header as AIRPORT, 100 × 40 byte records, total 4020):
      byte   0  : 0xE0 (always)
      byte   1  : 0x00
      byte   2  : usage (0x30=unused, 0x70=used×1, 0xF0=used×2+)
      byte   3  : 0x00
      bytes  4-7  : ID, 6-bit encoded (5 chars, 4 bytes)
      bytes  8-15 : Name, 6-bit encoded (10 chars, 8 bytes)
      bytes 20-23 : frequency float32 BE
      bytes 24-27 : longitude float32 BE   ← note: LON before LAT (opposite of airport!)
      bytes 28-31 : latitude  float32 BE
      bytes 32-35 : magnetic variation float32 BE
      bytes 36-39 : elevation float32 BE
    """
    r.section("NAVAID.P01")

    if not os.path.exists(path):
        r.fail(f"File not found: {path}")
        return []

    data = open(path, 'rb').read()
    r.info(f"File size: {len(data)} bytes  (expected 4020)")

    if len(data) != 4020:
        r.fail(f"Wrong size: {len(data)}")
    else:
        r.ok("File size = 4020 bytes")

    count = read_presence_count(data[:13])
    r.info(f"Record count (from presence bits): {count}")
    verify_db_header(data, count, r)

    navaids = []
    errors = 0
    zero_freq_ids = []

    for i in range(100):
        offset = 16 + i * 40
        if offset + 40 > len(data):
            break
        rec = data[offset:offset+40]

        if i < count:
            b0 = rec[0]
            b2 = rec[2]
            nv_id   = decode_6bit(rec[4:8]).strip()
            nv_name = decode_6bit(rec[8:16]).strip()
            freq = read_float_be(rec, 20)
            lon  = read_float_be(rec, 24)   # LON at 24 (navaid swaps lat/lon vs airport!)
            lat  = read_float_be(rec, 28)   # LAT at 28
            magvar = read_float_be(rec, 32)
            elev = read_float_be(rec, 36)

            if b0 != 0xE0:
                # Older DAP systems use byte0 values other than 0xE0 (e.g. 0xA8).
                # The helicopter accepts these. iOS always writes 0xE0.
                r.warn(f"Navaid[{i}] '{nv_id}': byte0={b0:#04x} (iOS writes 0xE0; older DAP may differ)")

            if b2 not in (0x30, 0x70, 0xF0):
                r.warn(f"Navaid[{i}] '{nv_id}': byte2={b2:#04x} unusual (expected 0x30/0x70/0xF0)")

            if not nv_id:
                r.fail(f"Navaid[{i}]: empty ID (bytes: {rec[4:8].hex()})")
                errors += 1

            if not is_valid_float(lat) or not (-90.0 <= lat <= 90.0):
                r.fail(f"Navaid[{i}] '{nv_id}': invalid lat={lat}")
                errors += 1

            if not is_valid_float(lon) or not (-180.0 <= lon <= 180.0):
                r.fail(f"Navaid[{i}] '{nv_id}': invalid lon={lon}")
                errors += 1

            if is_valid_float(freq) and freq <= 0.0:
                zero_freq_ids.append(nv_id)  # batched below

            navaids.append({'id': nv_id, 'name': nv_name, 'lat': lat, 'lon': lon, 'freq': freq})
            r.info(f"Navaid [{i:3d}]  ID={nv_id:<6} Name={nv_name:<12} "
                   f"Freq={freq:8.3f} Lat={lat:9.4f} Lon={lon:10.4f} Usage={b2:#04x}")
        else:
            if any(b != 0 for b in rec):
                r.warn(f"Navaid[{i}]: inactive slot is not all zeros")

    if zero_freq_ids:
        sample = ', '.join(zero_freq_ids[:5]) + (f" ... (+{len(zero_freq_ids)-5} more)" if len(zero_freq_ids) > 5 else "")
        r.warn(f"{len(zero_freq_ids)}/{count} navaid(s) have freq=0.0: {sample}")

    if errors == 0:
        r.ok(f"All {count} navaid records valid")
    else:
        r.fail(f"{errors} error(s) found across navaid records")

    return navaids


# ============================================================
# VERIFY WAYPOINT.P01
# ============================================================

def verify_waypoint(path: str, r: Reporter) -> list:
    """
    WAYPOINT.P01 format:
      Header (16 bytes): same as AIRPORT
      Records (100 × 28 bytes = 2800 bytes):
        bytes  0-3  : latitude  float32 BE
        bytes  4-7  : longitude float32 BE
        bytes  8-19 : name, 6-bit encoded (15 chars, 12 bytes)
        byte   20   : 0x00
        byte   21   : route membership (0=none, 8=route1, 16=route2, ...)
        bytes 22-23 : 0x00
        bytes 24-27 : ID, 6-bit SPECIAL encoding (standard encode → shift right 1, MSB=1)
      Total: 2820 bytes
    """
    r.section("WAYPOINT.P01")

    if not os.path.exists(path):
        r.fail(f"File not found: {path}")
        return []

    data = open(path, 'rb').read()
    r.info(f"File size: {len(data)} bytes  (expected 2820)")

    if len(data) != 2820:
        r.fail(f"Wrong size: {len(data)}")
    else:
        r.ok("File size = 2820 bytes")

    count = read_presence_count(data[:13])
    r.info(f"Record count (from presence bits): {count}")
    verify_db_header(data, count, r)

    waypoints = []
    errors = 0

    for i in range(100):
        offset = 16 + i * 28
        if offset + 28 > len(data):
            break
        rec = data[offset:offset+28]

        if i < count:
            lat  = read_float_be(rec, 0)
            lon  = read_float_be(rec, 4)
            name = decode_6bit(rec[8:20]).strip()
            membership = rec[21]
            wpt_id = decode_wpt_id(rec[24:28]).strip()

            if not wpt_id:
                r.fail(f"Waypoint[{i}]: empty ID (raw bytes: {rec[24:28].hex()})")
                errors += 1

            if not is_valid_float(lat) or not (-90.0 <= lat <= 90.0):
                r.fail(f"Waypoint[{i}] '{wpt_id}': invalid lat={lat}")
                errors += 1

            if not is_valid_float(lon) or not (-180.0 <= lon <= 180.0):
                r.fail(f"Waypoint[{i}] '{wpt_id}': invalid lon={lon}")
                errors += 1

            if membership != 0 and membership % 8 != 0:
                r.warn(f"Waypoint[{i}] '{wpt_id}': membership={membership} not a multiple of 8")

            # Round-trip verify the ID encoding
            expected_enc = encode_wpt_id(wpt_id)
            if expected_enc != bytes(rec[24:28]):
                r.warn(f"Waypoint[{i}] '{wpt_id}': re-encoding mismatch "
                       f"(stored={bytes(rec[24:28]).hex()} re-enc={expected_enc.hex()})")

            waypoints.append({'id': wpt_id, 'name': name, 'lat': lat, 'lon': lon,
                               'membership': membership})
            route_str = f"route{membership // 8}" if membership > 0 else "none"
            r.info(f"WPT   [{i:3d}]  ID={wpt_id:<6} Name={name:<15} "
                   f"Lat={lat:9.4f} Lon={lon:10.4f} Route={route_str}")
        else:
            if any(b != 0 for b in rec):
                r.warn(f"Waypoint[{i}]: inactive slot is not all zeros")

    if errors == 0:
        r.ok(f"All {count} waypoint records valid")
    else:
        r.fail(f"{errors} error(s) found across waypoint records")

    return waypoints


# ============================================================
# VERIFY ROUTE.P01
# ============================================================

TYPE_CODE_NAME = {0x0C: 'JEPPESEN', 0x5C: 'APT', 0x6C: 'WPT', 0x7C: 'NAV', 0x8C: 'EMPTY'}
TYPE_BITS_NAME = {0b010: 'none', 0b100: 'sys_apt', 0b101: 'usr_apt'}


def verify_route(path: str, r: Reporter,
                 airports: list, navaids: list, waypoints: list) -> list:
    """
    ROUTE.P01 format:
      Header (16 bytes): same pattern
      Records (100 × 500 bytes = 50000 bytes):
        Route header (20 bytes):
          bytes  0-7  : route name, 6-bit encoded (10 chars, 8 bytes)
          bytes  8-10 : logistical start airport ID (3 bytes, truncated 6-bit)
          byte   11   : start airport dbIdx  ((fileIndex+1)*2, or 0 for system)
          bytes 12-14 : logistical dest airport ID (3 bytes)
          byte   15   : dest airport dbIdx
          byte   16   : statusByte = (startTypeBits<<5) | (destTypeBits<<2)
                          typeBits: 010=none, 100=sys_apt, 101=usr_apt
                          default 0x48 when no logistical airports
          bytes 17-18 : ptCount encoded as  byte17=(count//8), byte18=(count%8)*32
          byte   19   : 0x00
        Fix points (40 × 12 bytes, bytes 20-499):
          byte   0    : dbIdx of referenced record ((fileIndex+1)*2, or 0)
          bytes  1-3  : 0x00 padding
          bytes  4-7  : point ID, standard 6-bit encoded
          bytes  8-10 : 0x00 padding (NOTE: older DAP systems may have non-zero here; helicopter ignores it)
          byte   11   : typeCode (0x5C=airport, 0x6C=waypoint, 0x7C=navaid, 0x8C=empty/terminator)
      Total: 50020 bytes
    dbIdx formula: (zero-based file index + 1) * 2
    """
    r.section("ROUTE.P01")

    if not os.path.exists(path):
        r.fail(f"File not found: {path}")
        return []

    data = open(path, 'rb').read()
    r.info(f"File size: {len(data)} bytes  (expected 50020)")

    if len(data) != 50020:
        r.fail(f"Wrong size: {len(data)}")
    else:
        r.ok("File size = 50020 bytes")

    count = read_presence_count(data[:13])
    r.info(f"Route count (from presence bits): {count}")
    verify_db_header(data, count, r)

    routes = []
    total_errors = 0

    for i in range(100):
        offset = 16 + i * 500
        if offset + 500 > len(data):
            break
        rec = data[offset:offset+500]

        if i < count:
            name = decode_6bit(rec[0:8]).strip()

            # Logistical header
            start_dbidx = rec[11]
            dest_dbidx  = rec[15]
            status_byte = rec[16]

            start_bits = (status_byte >> 5) & 0x07
            dest_bits  = (status_byte >> 2) & 0x07
            lower_bits = status_byte & 0x03

            # ptCount decode
            b17, b18 = rec[17], rec[18]
            pt_count = (b17 * 8) + (b18 >> 5)

            r.info(f"Route [{i:3d}]  Name={name:<12} pts={pt_count:2d}  "
                   f"status={status_byte:#04x} "
                   f"start={TYPE_BITS_NAME.get(start_bits, f'unk({start_bits})')} "
                   f"dest={TYPE_BITS_NAME.get(dest_bits, f'unk({dest_bits})')}")

            # Validate ptCount encoding
            if b18 & 0x1F != 0:
                r.fail(f"Route[{i}] '{name}': byte18={b18:#04x} lower 5 bits not zero (ptCount encoding error)")
                total_errors += 1

            if pt_count > 40:
                r.fail(f"Route[{i}] '{name}': ptCount={pt_count} exceeds maximum of 40")
                total_errors += 1

            # statusByte lower 2 bits should be 0
            if lower_bits != 0:
                r.warn(f"Route[{i}] '{name}': statusByte={status_byte:#04x} lower 2 bits={lower_bits:#x} (expected 0)")

            # Validate typeBits
            if start_bits not in (0b010, 0b100, 0b101):
                r.warn(f"Route[{i}] '{name}': startTypeBits={start_bits:#05b} unknown")
            if dest_bits not in (0b010, 0b100, 0b101):
                r.warn(f"Route[{i}] '{name}': destTypeBits={dest_bits:#05b} unknown")

            # Validate logistical airport dbIdx references (user airports only)
            for side, bits, dbidx in [('start', start_bits, start_dbidx),
                                       ('dest',  dest_bits,  dest_dbidx)]:
                if bits == 0b101:   # user airport
                    if dbidx == 0:
                        # DAP quirk: typeBits=101 (usr_apt) but dbIdx=0 — helicopter accepts this
                        r.warn(f"Route[{i}] '{name}': logistical {side} typeBits=usr_apt but dbIdx=0 "
                               f"(Jeppesen/system airport — DAP quirk, helikoptern accepterar)")
                    else:
                        rec_idx = (dbidx // 2) - 1
                        if rec_idx < 0 or rec_idx >= len(airports):
                            r.fail(f"Route[{i}] '{name}': logistical {side} usr_apt dbIdx={dbidx} "
                                   f"→ rec[{rec_idx}] out of range (airports={len(airports)})")
                            total_errors += 1
                        else:
                            r.info(f"  Logistical {side} (usr_apt): dbIdx={dbidx} "
                                   f"→ Airport[{rec_idx}]={airports[rec_idx]['id']}")
                elif bits == 0b100:  # system airport, dbIdx=0 expected
                    if dbidx != 0:
                        r.warn(f"Route[{i}] '{name}': logistical {side} sys_apt has dbIdx={dbidx} (expected 0)")
                    r.info(f"  Logistical {side} (sys_apt): dbIdx={dbidx}")

            # Fix points
            fix_errors = 0
            terminated = False

            for p in range(40):
                pt_off = 20 + p * 12
                pt = rec[pt_off:pt_off+12]
                db_idx   = pt[0]
                pt_id_raw = pt[4:8]
                type_code = pt[11]

                if type_code == 0x8C:
                    # Terminator: all remaining slots must also be 0x8C
                    for pp in range(p, 40):
                        ppt = rec[20 + pp * 12: 20 + pp * 12 + 12]
                        if ppt[11] != 0x8C:
                            r.fail(f"Route[{i}] '{name}': fix[{pp}] typeCode={ppt[11]:#04x} "
                                   f"after terminator at [{p}]")
                            fix_errors += 1
                    terminated = True
                    break

                if type_code == 0x0C:  # Jeppesen/system database point (dbIdx always 0)
                    pt_id = decode_6bit(pt_id_raw).strip()
                    r.info(f"  Fix[{p:2d}] JEPPESEN  dbIdx={db_idx} ID={pt_id} (system db, no local cross-ref)")
                    if db_idx != 0:
                        r.warn(f"Route[{i}] '{name}': fix[{p}] JEPPESEN point has dbIdx={db_idx} (expected 0)")
                    continue

                if type_code not in (0x5C, 0x6C, 0x7C):
                    r.fail(f"Route[{i}] '{name}': fix[{p}] unknown typeCode={type_code:#04x}")
                    fix_errors += 1
                    continue

                pt_id  = decode_6bit(pt_id_raw).strip()
                rec_idx = (db_idx // 2) - 1

                if type_code == 0x5C:  # Airport
                    if db_idx == 0:
                        r.info(f"  Fix[{p:2d}] APT  dbIdx=0 (system/no-db)  ID={pt_id}")
                    elif rec_idx < 0 or rec_idx >= len(airports):
                        r.fail(f"Route[{i}] '{name}': fix[{p}] APT dbIdx={db_idx} "
                               f"→ rec[{rec_idx}] out of range (airports={len(airports)})")
                        fix_errors += 1
                    else:
                        db_id = airports[rec_idx]['id']
                        if pt_id != db_id:
                            # Helicopter uses dbIdx for lookup; bytes 4-7 ID is display-only.
                            # DAP cards sometimes have display-ID ≠ db-ID. Not a structural error.
                            r.warn(f"Route[{i}] '{name}': fix[{p}] APT display-ID={pt_id} "
                                   f"!= Airport[{rec_idx}].id={db_id} (dbIdx={db_idx} still valid)")
                        r.info(f"  Fix[{p:2d}] APT  dbIdx={db_idx:3d} → Airport[{rec_idx:3d}]={db_id:<6}  ptID={pt_id}  "
                               + ("OK" if pt_id == db_id else "id-mismatch"))

                elif type_code == 0x6C:  # Waypoint
                    if rec_idx < 0 or rec_idx >= len(waypoints):
                        r.fail(f"Route[{i}] '{name}': fix[{p}] WPT dbIdx={db_idx} "
                               f"→ rec[{rec_idx}] out of range (waypoints={len(waypoints)})")
                        fix_errors += 1
                    else:
                        db_id = waypoints[rec_idx]['id']
                        if pt_id != db_id:
                            r.warn(f"Route[{i}] '{name}': fix[{p}] WPT display-ID={pt_id} "
                                   f"!= Waypoint[{rec_idx}].id={db_id} (dbIdx={db_idx} still valid)")
                        r.info(f"  Fix[{p:2d}] WPT  dbIdx={db_idx:3d} → WPT[{rec_idx:3d}]={db_id:<6}  ptID={pt_id}  "
                               + ("OK" if pt_id == db_id else "id-mismatch"))

                elif type_code == 0x7C:  # Navaid
                    if rec_idx < 0 or rec_idx >= len(navaids):
                        r.fail(f"Route[{i}] '{name}': fix[{p}] NAV dbIdx={db_idx} "
                               f"→ rec[{rec_idx}] out of range (navaids={len(navaids)})")
                        fix_errors += 1
                    else:
                        db_id = navaids[rec_idx]['id']
                        if pt_id != db_id:
                            r.warn(f"Route[{i}] '{name}': fix[{p}] NAV display-ID={pt_id} "
                                   f"!= Navaid[{rec_idx}].id={db_id} (dbIdx={db_idx} still valid)")
                        r.info(f"  Fix[{p:2d}] NAV  dbIdx={db_idx:3d} → NAV[{rec_idx:3d}]={db_id:<6}  ptID={pt_id}  "
                               + ("OK" if pt_id == db_id else "id-mismatch"))

            if not terminated and pt_count < 40:
                r.warn(f"Route[{i}] '{name}': no 0x8C terminator found within fix point area")

            if fix_errors == 0:
                r.ok(f"Route[{i}] '{name}': all {pt_count} fix point(s) valid")
            else:
                total_errors += fix_errors

            routes.append({'name': name, 'pt_count': pt_count})

        else:
            # Inactive route slot
            if rec[0] != 0:
                r.warn(f"Route[{i}]: inactive slot name byte0={rec[0]:#04x} (expected 0)")
            if rec[16] != 0x48:
                r.warn(f"Route[{i}]: inactive slot statusByte={rec[16]:#04x} (expected 0x48)")
            for p in range(40):
                pt_off = 20 + p * 12
                if rec[pt_off + 11] != 0x8C:
                    r.warn(f"Route[{i}]: inactive slot fix[{p}] typeCode={rec[pt_off+11]:#04x} "
                           f"(expected 0x8C)")
                    break

    if total_errors == 0:
        r.ok(f"All {count} route(s) valid")
    else:
        r.fail(f"{total_errors} error(s) found across routes")

    return routes


# ============================================================
# VERIFY CARACTER.P01
# ============================================================

def verify_caracter(path: str, r: Reporter, pilote_date: dict,
                    airport_data, navaid_data, waypoint_data, route_data):
    """
    CARACTER.P01 format (116 bytes, all others 0x00):
      bytes  0-3  : magic 0x55 0xAA 0x55 0xAA
      bytes  4-11 : date in 6-bit "DTDd+MMYYYY" encoding;
                    byte7 (index 3 of this field) LSB2 forced to 0b10
      bytes 12-13 : binary date:
                    b12 = (day << 3) | ((month-1) >> 1)
                    b13 = (((month-1) & 1) << 7) | ((year-2000) & 0x1F)
                    note: year offset is 5 bits → max representable year = 2031
      byte   14   : 0x40
      bytes 16,28,40,52 : 0x80
      Checksums (each = sumLo:int32BE + sumHi:int32BE, 8 bytes each):
        offset  68 : WAYPOINT.P01 checksum
        offset  80 : AIRPORT.P01 checksum
        offset  92 : NAVAID.P01  checksum
        offset 104 : ROUTE.P01   checksum
      All other bytes: 0x00
    """
    r.section("CARACTER.P01")

    if not os.path.exists(path):
        r.fail(f"File not found: {path}")
        return

    data = open(path, 'rb').read()
    r.info(f"File size: {len(data)} bytes  (expected 116)")

    if len(data) != 116:
        r.fail(f"Wrong size: {len(data)}")
        if len(data) < 116:
            return
    else:
        r.ok("File size = 116 bytes")

    # Magic
    if data[0:4] == b'\x55\xAA\x55\xAA':
        r.ok("Magic bytes 0x55 0xAA 0x55 0xAA correct")
    else:
        r.fail(f"Wrong magic: {data[0:4].hex()} (expected 55aa55aa)")

    # 6-bit date (bytes 4-11)
    date_field = bytes(data[4:12])
    b7 = date_field[3]
    if (b7 & 0x03) == 0x02:
        r.ok(f"byte7 (offset 7) LSB2=0b10 correct  (byte value={b7:#04x})")
    else:
        # iOS app forces LSB2=0b10; DAP does not set it. Helicopter accepts both.
        r.warn(f"byte7 LSB2={b7 & 0x03:#x} (iOS sets 0b10, DAP does not — helikoptern accepterar båda)  byte7={b7:#04x}")

    # Decode 6-bit date (mask off LSB2 for clean decode, they're padding bits)
    clean_field = bytearray(date_field)
    clean_field[3] = b7 & 0xFC
    date_str_6bit = decode_6bit(bytes(clean_field)).strip()
    r.info(f"6-bit date string: '{date_str_6bit}'")

    parsed_6bit = parse_pilote_date_string(date_str_6bit) if date_str_6bit.startswith("DTD") else None
    # NOTE: iOS format is "DTD{day}{month:02d}{year:04d}". When day≥10, the string is 11 chars
    # which exceeds the 10-char 6-bit field limit → last char of year is dropped, and the
    # resulting truncated string cannot reliably be parsed for day/month (ambiguous encoding).
    # The binary date (bytes 12-13) is the authoritative date check. The 6-bit date is advisory only.
    truncated_6bit = pilote_date is not None and pilote_date['day'] >= 10

    if parsed_6bit:
        day6, month6, year6 = parsed_6bit
        r.info(f"6-bit date decoded: {day6:02d}/{month6:02d}/{year6}")
        if pilote_date:
            pd = pilote_date
            year_ok = (2000 <= year6 <= 2099)
            if truncated_6bit:
                # When day≥10, string is 11 chars → 6-bit field truncates it → day/month parsing unreliable.
                r.info(f"6-bit date: day={pd['day']}≥10 → date string was truncated; "
                       f"decoded '{date_str_6bit}' is partial — binary date (bytes 12-13) is authoritative")
            elif day6 == pd['day'] and month6 == pd['month'] and year6 == pd['year']:
                r.ok(f"6-bit date matches PILOTE.HD: {day6:02d}/{month6:02d}/{year6}")
            elif not year_ok:
                r.info(f"6-bit year={year6} outside 2000-2099; likely truncation artifact. "
                       f"Binary date is authoritative.")
            else:
                r.fail(f"6-bit date {day6:02d}/{month6:02d}/{year6} "
                       f"!= PILOTE.HD {pd['day']:02d}/{pd['month']:02d}/{pd['year']}")
    else:
        if truncated_6bit:
            r.info(f"6-bit date string '{date_str_6bit}' — expected truncation (day={pilote_date['day']}≥10, "
                   f"string exceeds 10-char limit). Binary date is authoritative.")
        else:
            r.info(f"6-bit date string '{date_str_6bit}' partially truncated "
                   f"(iOS 10-char limit; year last digit may be cut when day ≥ 10)")

    # Re-encode date using iOS format and compare (round-trip check, iOS cards only)
    if parsed_6bit and pilote_date:
        pd = pilote_date
        date_string = f"DTD{pd['day']}{pd['month']:02d}{pd['year']:04d}"
        expected_6bit = bytearray(encode_6bit(date_string, max_chars=10, total_bytes=8))
        expected_6bit[3] = (expected_6bit[3] & 0xFC) | 0x02
        if bytes(expected_6bit) == date_field:
            r.ok("6-bit date re-encoding round-trip matches stored bytes (iOS format)")
        else:
            # DAP uses non-padded month format → re-encoding with iOS format will differ
            r.info(f"6-bit date re-encoding: stored={date_field.hex()} iOS-enc={bytes(expected_6bit).hex()} "
                   f"(mismatch normal for DAP-generated cards)")

    # Binary date (bytes 12-13)
    b12, b13 = data[12], data[13]
    bin_day        = b12 >> 3
    bin_mval       = ((b12 & 0x07) << 1) | (b13 >> 7)
    bin_month      = bin_mval + 1
    bin_year_off   = b13 & 0x1F
    bin_year       = 2000 + bin_year_off
    r.info(f"Binary date: b12={b12:#04x} b13={b13:#04x} → {bin_day:02d}/{bin_month:02d}/{bin_year}")

    if pilote_date:
        pd = pilote_date
        if bin_day == pd['day'] and bin_month == pd['month']:
            r.ok(f"Binary date day/month matches PILOTE.HD: {bin_day:02d}/{bin_month:02d}")
        else:
            r.fail(f"Binary date {bin_day:02d}/{bin_month:02d} != PILOTE.HD {pd['day']:02d}/{pd['month']:02d}")

        expected_off = pd['year'] - 2000
        if expected_off > 31:
            r.warn(f"Year {pd['year']}: offset={expected_off} exceeds 5-bit range (max 2031). "
                   f"Binary encodes year {2000 + (expected_off & 0x1F)} instead.")
        elif bin_year == pd['year']:
            r.ok(f"Binary date year matches: {bin_year}")
        else:
            r.fail(f"Binary date year={bin_year} != PILOTE.HD year={pd['year']}")

    # byte14
    if data[14] == 0x40:
        r.ok("byte14=0x40 correct")
    else:
        r.fail(f"byte14={data[14]:#04x} (expected 0x40)")

    # bytes 16, 28, 40, 52
    for idx in [16, 28, 40, 52]:
        if data[idx] == 0x80:
            r.ok(f"byte[{idx}]=0x80 correct")
        else:
            r.fail(f"byte[{idx}]={data[idx]:#04x} (expected 0x80)")

    # Checksums
    for chk_offset, label, file_data in [
        (68,  "WAYPOINT.P01", waypoint_data),
        (80,  "AIRPORT.P01",  airport_data),
        (92,  "NAVAID.P01",   navaid_data),
        (104, "ROUTE.P01",    route_data),
    ]:
        stored_lo = struct.unpack('>i', data[chk_offset:chk_offset+4])[0]
        stored_hi = struct.unpack('>i', data[chk_offset+4:chk_offset+8])[0]

        if file_data is None:
            r.warn(f"Checksum @{chk_offset} ({label}): cannot verify (file not loaded)")
            continue

        comp_lo, comp_hi = compute_checksum(file_data)
        if stored_lo == comp_lo and stored_hi == comp_hi:
            r.ok(f"Checksum {label} @{chk_offset}: lo={stored_lo} hi={stored_hi}  MATCH")
        else:
            r.fail(f"Checksum {label} @{chk_offset}: "
                   f"stored lo={stored_lo} hi={stored_hi}  "
                   f"computed lo={comp_lo} hi={comp_hi}  MISMATCH")

    # Verify all unused bytes are zero
    used = (set(range(0, 15))         # magic + 6-bit date + binary date + byte14
            | {16, 28, 40, 52}        # 0x80 markers
            | set(range(68, 76))      # wpt checksum
            | set(range(80, 88))      # airport checksum
            | set(range(92, 100))     # navaid checksum
            | set(range(104, 112)))   # route checksum

    non_zero = [(i, data[i]) for i in range(116) if i not in used and data[i] != 0]
    if non_zero:
        r.warn(f"Non-zero byte(s) at unexpected offsets: "
               + ", ".join(f"[{i}]={v:#04x}" for i, v in non_zero[:10])
               + (" ..." if len(non_zero) > 10 else ""))
    else:
        r.ok("All 116 bytes: unused positions are zero")


# ============================================================
# MAIN
# ============================================================

def find_file(folder: str, name: str) -> str:
    """Locate file case-insensitively."""
    for f in os.listdir(folder):
        if f.upper() == name.upper():
            return os.path.join(folder, f)
    return os.path.join(folder, name)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <card_folder>")
        print("  card_folder: path containing PILOTE.HD, AIRPORT.P01, etc.")
        sys.exit(1)

    folder = sys.argv[1]
    if not os.path.isdir(folder):
        print(f"ERROR: Not a directory: {folder}")
        sys.exit(1)

    print(f"\nA109 PCMCIA Card Verifier")
    print(f"Card folder : {os.path.abspath(folder)}")

    file_names = ['PILOTE.HD', 'AIRPORT.P01', 'NAVAID.P01',
                  'WAYPOINT.P01', 'ROUTE.P01', 'CARACTER.P01']

    file_map = {}
    print(f"\nFile inventory:")
    for fname in file_names:
        path = find_file(folder, fname)
        exists = os.path.exists(path)
        size = os.path.getsize(path) if exists else 0
        file_map[fname] = path
        status = f"found  ({size:,} bytes)" if exists else "MISSING"
        print(f"  {fname:<15} {status}")

    file_sizes = {fn: os.path.getsize(file_map[fn])
                  for fn in file_names if os.path.exists(file_map[fn])}

    def load(fname):
        p = file_map[fname]
        return open(p, 'rb').read() if os.path.exists(p) else None

    airport_raw  = load('AIRPORT.P01')
    navaid_raw   = load('NAVAID.P01')
    waypoint_raw = load('WAYPOINT.P01')
    route_raw    = load('ROUTE.P01')

    r = Reporter()

    pilote_date = verify_pilote(file_map['PILOTE.HD'], r, file_sizes)
    airports    = verify_airport(file_map['AIRPORT.P01'], r)
    navaids     = verify_navaid(file_map['NAVAID.P01'], r)
    waypoints   = verify_waypoint(file_map['WAYPOINT.P01'], r)
    routes      = verify_route(file_map['ROUTE.P01'], r, airports, navaids, waypoints)
    verify_caracter(file_map['CARACTER.P01'], r, pilote_date,
                    airport_raw, navaid_raw, waypoint_raw, route_raw)

    r.summary()
    sys.exit(0 if not r.errors else 1)


if __name__ == '__main__':
    main()
