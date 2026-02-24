import struct
import os
import sys
from typing import Tuple, List, Dict, Any

# --- KONSTANTER OCH ANTANGANDEN ---

WAYPOINT_BLOCK_SIZE = 28 
HEADER_SIZE = 16 
COORD_FORMAT = '>f' 

# 6-BITARS TECKENMAPPNING FÖR THALES FMS 2000 (Ooförändrad)
THALES_6BIT_MAP = {
    30: 'A', 31: 'B', 32: 'C', 33: 'D', 34: 'E', 35: 'F', 36: 'G', 
    37: 'H', 38: 'I', 39: 'J', 40: 'K', 41: 'L', 42: 'M', 43: 'N', 
    44: 'O', 45: 'P', 46: 'Q', 47: 'R', 48: 'S', 49: 'T', 50: 'U', 
    51: 'V', 52: 'W', 53: 'X', 54: 'Y', 55: 'Z',
    14: '0', 15: '1', 16: '2', 17: '3', 18: '4', 19: '5', 
    20: '6', 21: '7', 22: '8', 23: '9',
    0: ' ',     
    11: '-',    
}


def decode_6bit_char(code: int) -> str:
    """Avkodar en 6-bitars kod till ett ASCII-tecken med hjälp av Thales mappning."""
    return THALES_6BIT_MAP.get(code, f'[?{code:06b}?]')


def extract_id_fields(data: bytes, num_chars: int, skip_bits_start=1) -> str:
    """Extraherar ID-fältet."""
    bin_data = ''.join(f'{b:08b}' for b in data)
    
    start_index = skip_bits_start
    total_bits_needed = num_chars * 6
    end_index = start_index + total_bits_needed
    
    relevant_bits = bin_data[start_index:end_index]

    result_chars = []
    
    for i in range(0, len(relevant_bits), 6):
        six_bit_code = relevant_bits[i:i+6]
        if len(six_bit_code) == 6:
            code = int(six_bit_code, 2)
            result_chars.append(decode_6bit_char(code))

    return "".join(result_chars).strip()


def extract_name_fields(data: bytes, num_chars: int) -> str:
    """
    Extraherar Namn-fältet (15 tecken, 12 byte) baserat på den 3-set strukturen
    med 2 bitars intern padding i slutet av varje 4-byte-set.
    """
    if len(data) != 12:
        return "[FEL: Namnfältet är inte 12 byte]"

    result_chars = []
    
    # 3 set om 4 byte vardera
    for i in range(0, 12, 4):
        set_bytes = data[i:i+4]
        bin_data = ''.join(f'{b:08b}' for b in set_bytes)
        
        # Vi läser de första 30 bitarna (5 tecken * 6 bitar), ignorerar de sista 2 bitarna (padding)
        relevant_bits = bin_data[0:30]
        
        # Tolka 5 tecken från 30 bitar
        for j in range(0, 30, 6):
            six_bit_code = relevant_bits[j:j+6]
            if len(six_bit_code) == 6:
                code = int(six_bit_code, 2)
                result_chars.append(decode_6bit_char(code))
        
    return "".join(result_chars).strip()


def decode_route_flags(flag_bytes: bytes) -> Tuple[str, str]:
    """Tolkar byte 20-23 som en 32-bitars ruttflagga (Little-Endian antas)."""
    try:
        # Läs som Little-Endian Unsigned Int för att tolka flaggor
        flags, = struct.unpack('<I', flag_bytes) 
    except struct.error:
        return "Okänt format", "00000000"

    routes = []
    
    # Kända ruttflaggor
    if flags & 0x08: routes.append("Rutt 1")
    if flags & 0x10: routes.append("Rutt 2")
    if flags & 0x20: routes.append("Rutt 3")
    if flags & 0x40: routes.append("Rutt 4")
    
    if routes:
        route_status = ", ".join(routes)
    elif flags == 0:
        route_status = "Ingen rutt"
    else:
        route_status = f"Okänd flagga (Dec {flags})"
        
    # Byte 21 är den andra byten i fältet (index 1)
    byte_21 = flag_bytes[1]
    byte_21_bin = f'{byte_21:08b}'
    
    return route_status, byte_21_bin


def count_waypoints_from_header(header_bytes: bytes) -> Dict[str, Any]:
    """
    Räknar antalet waypoints med hjälp av tre metoder från headern (Byte 0-11, Byte 13, Byte 14).
    """
    if len(header_bytes) < 16:
        return {'expected_count': 0, 'validation_status': 'FEL: För kort header'}

    status = {}
    
    # Metod 1: Antal '1'-bitar i Byte 0-11
    bit_count = 0
    for byte in header_bytes[0:12]:
        bit_count += bin(byte).count('1')
    status['expected_count'] = bit_count
    
    # Metod 2: Byte 13 (Decimal 137 i exemplet)
    byte_13_val = header_bytes[13]
    count_from_byte_13 = byte_13_val - 129
    status['byte_13_val'] = byte_13_val
    status['count_from_byte_13'] = count_from_byte_13
    
    # Metod 3: Byte 14 (Decimal 16 i exemplet)
    byte_14_val = header_bytes[14]
    count_from_byte_14 = byte_14_val // 2
    status['byte_14_val'] = byte_14_val
    status['count_from_byte_14'] = count_from_byte_14
    
    # Validering
    counts = {bit_count, count_from_byte_13, count_from_byte_14}
    if len(counts) == 1 and bit_count == count_from_byte_13 and bit_count == count_from_byte_14:
        status['validation_status'] = "Validerad"
        status['expected_count'] = bit_count
    else:
        status['validation_status'] = f"Avvikelse hittad! Bit-Count={bit_count}, Byte 13={count_from_byte_13}, Byte 14={count_from_byte_14}"
        status['expected_count'] = bit_count # Fortsätt med bit-count som primär gissning

    return status


def parse_waypoint(data: bytes, waypoint_index: int) -> Dict[str, Any]:
    """Tolkar ett 28-byte waypoint-block."""
    if len(data) != WAYPOINT_BLOCK_SIZE:
        raise ValueError(f"Block {waypoint_index} har fel storlek: {len(data)} byte. Förväntat: {WAYPOINT_BLOCK_SIZE}.")

    # --- 1. LATITUD & LONGITUD (Byte 0-7) ---
    try:
        latitude, = struct.unpack(COORD_FORMAT, data[0:4])
        longitude, = struct.unpack(COORD_FORMAT, data[4:8])
    except struct.error:
        latitude = float('NaN')
        longitude = float('NaN')

    # --- 2. NAMN (Byte 8-19) ---
    name_bytes = data[8:20]
    name = extract_name_fields(name_bytes, num_chars=15)

    # --- 3. RUTTFLAGGOR (Byte 20-23) ---
    route_flags_bytes = data[20:24]
    routes, byte_21_bin = decode_route_flags(route_flags_bytes)

    # --- 4. ID (Byte 24-27) ---
    id_bytes = data[24:28]
    waypoint_id = extract_id_fields(id_bytes, num_chars=5, skip_bits_start=1)

    return {
        'Index': waypoint_index + 1,
        'Latitude': latitude,
        'Longitude': longitude,
        'Name': name,
        'ID': waypoint_id,
        'Routes': routes,
        'Byte_21_Bin': byte_21_bin
    }

def process_waypoint_file(file_path: str) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """Läser en binär fil, tolkar waypoints och filtrerar bort tomma."""
    all_waypoints = []
    header_status = {}
    
    if not os.path.exists(file_path):
        print(f"Fel: Filen hittades inte på {file_path}")
        return {}, []

    print(f"Börjar tolka fil: {file_path}...")

    with open(file_path, 'rb') as f:
        # Läs hela headern
        header_data = f.read(HEADER_SIZE)
        
        # 1. Tolka Header
        header_status = count_waypoints_from_header(header_data)
        
        # Gå till början av första waypointen
        f.seek(HEADER_SIZE)
        
        waypoint_index = 0
        while True:
            block_data = f.read(WAYPOINT_BLOCK_SIZE)
            
            if len(block_data) == WAYPOINT_BLOCK_SIZE:
                try:
                    waypoint_data = parse_waypoint(block_data, waypoint_index)
                    all_waypoints.append(waypoint_data)
                    waypoint_index += 1
                except ValueError as e:
                    print(f"FEL: Avbröt tolkningen vid waypoint {waypoint_index + 1}: {e}")
                    break
            elif len(block_data) > 0:
                print(f"VARNING: Ofullständigt waypoint-block i slutet av filen ({len(block_data)} byte läst). Avbryter.")
                break
            else:
                break
                
    valid_waypoints = []
    
    for wp in all_waypoints:
        name_clean = wp['Name'].replace('-', '').strip()
        id_clean = wp['ID'].replace('-', '').strip()
        
        if not name_clean and not id_clean:
            continue
        
        valid_waypoints.append(wp)
                
    return header_status, valid_waypoints

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Användning: python ditt_skriptnamn.py <waypoint_fil>")
        sys.exit(1)

    file_to_parse = sys.argv[1] 
    
    header_status, parsed_data = process_waypoint_file(file_to_parse)

    if parsed_data:
        print("\n" + "=" * 50)
        print(f"RESULTAT: Tolkade {len(parsed_data)} giltiga waypoints från {file_to_parse}")
        
        # Header-information
        print("\n--- Header-analys ---")
        print(f"Förväntade waypoints (Bit-Count): {header_status.get('expected_count', 'N/A')}")
        print(f"Valideringsstatus: {header_status.get('validation_status', 'N/A')}")
        if 'count_from_byte_13' in header_status:
            print(f"  - Byte 13 (Dec {header_status['byte_13_val']}): Antal = {header_status['count_from_byte_13']} (129 + N)")
        if 'count_from_byte_14' in header_status:
            print(f"  - Byte 14 (Dec {header_status['byte_14_val']}): Antal = {header_status['count_from_byte_14']} (N * 2)")
        print("=" * 50)
        
        for wp in parsed_data:
            print(f"Waypoint {wp['Index']}: {wp['Name']} (ID: {wp['ID']})")
            print(f"  Koordinater: Lat={wp['Latitude']:.4f}, Lon={wp['Longitude']:.4f}")
            print(f"  Rutter: {wp['Routes']}")
            print(f"  Byte 21 (Rå Bin): {wp['Byte_21_Bin']}")
            print("-" * 50)
    else:
        print("Inga giltiga waypoints hittades. Kontrollera filnamn, sökväg och struktur.")
