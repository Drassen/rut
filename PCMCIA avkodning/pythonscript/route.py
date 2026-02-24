import struct
import os
import sys
from typing import Tuple, List, Dict, Any

# --- KONSTANTER OCH ANTANGANDEN ---

WP_LINK_LOGICAL_SIZE = 12 # De meningsfulla bytena (Byte 0-11)
ROUTE_LINK_SIZE = 12 # Storleken på blocket vi läser från filen (för att hantera padding)
FILE_HEADER_SIZE = 16 # Byte 0-15
ROUTE_START_OFFSET = 16 # Byte 16 där Rutt Namn börjar
ROUTE_NAME_BYTES = 8 # Storlek på Master Namn
ROUTE_TOTAL_SIZE = 500 # Den fasta buffertstorleken per rutt

# 6-BITARS TECKENMAPPNING FÖR THALES FMS 2000
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

# ANSI-färgkoder
RÖD = '\033[91m'
GRÖN = '\033[92m'
GUL = '\033[93m'
BLÅ = '\033[94m'
VIT = '\033[0m' # Återställer färg och format till standard


def decode_6bit_char(code: int) -> str:
    """Avkodar en 6-bitars kod till ett ASCII-tecken."""
    return THALES_6BIT_MAP.get(code, f'[?{code:06b}?]')


def extract_6bit_fields(data: bytes, num_chars: int) -> str:
    """
    Extraherar och avkodar 6-bitars fält (WP-ID/Namn) från data som kan innehålla intern padding.
    data: Bytes att avkoda.
    num_chars: Totalt antal tecken att extrahera (t.ex. 5, 10, 15, 30).
    """
    result_chars = []
    
    # Beräkna hur många 32-bitars block som potentiellt innehåller data.
    # Exempel: 15 tecken = 90 bitar. 90/30 = 3 block behövs (3 * 4 byte = 12 byte).
    # Vi beräknar hur många 4-byte block vi måste iterera över.
    # Använder ceil((num_chars * 6) / 30) för att få antalet 4-byte block.
    num_32bit_blocks = (num_chars * 6 + 29) // 30 
    
    current_char_count = 0
    
    for i in range(num_32bit_blocks):
        if current_char_count >= num_chars:
            break
            
        # Läs nästa 4 byte (32 bitar) från indata
        set_bytes = data[i*4 : i*4 + 4]
        if len(set_bytes) < 4:
            break # Slut på data

        # Gör om 4 byte till 32 bitar
        bin_data = ''.join(f'{b:08b}' for b in set_bytes)
        
        # Bestäm hur många bitar som ska läsas från detta block (max 30)
        # Vi läser alltid 30 bitar (5 tecken) och ignorerar de sista 2 bitarna (padding)
        # Om detta är det första blocket, beakta skip_bits_start
        
        bits_to_read = 30
        
        relevant_bits = bin_data[0 : 0 + bits_to_read]
        
        # Tolka 6 bitar i taget
        for k in range(0, len(relevant_bits), 6):
            if current_char_count >= num_chars:
                break
                
            six_bit_code = relevant_bits[k:k+6]
            if len(six_bit_code) == 6:
                code = int(six_bit_code, 2)
                result_chars.append(decode_6bit_char(code))
                current_char_count += 1

    return "".join(result_chars).strip()

def decode_route_link(data: bytes, link_index: int) -> Dict[str, Any]:


    # Vi skapar en vy över de meningsfulla 12 bytena (Byte 0-11)
    meaningful_data = data[0:WP_LINK_LOGICAL_SIZE] 
    
    # --- 1. WP LÖPNUMMER/INDEX (Byte 0) ---
    sequence_byte = meaningful_data[0] 
    
    # --- 2. WP ID/NAMN REFERENS (Byte 4-7) ---
    wp_id = extract_6bit_fields(meaningful_data[4:8], num_chars=5)


    return {
        'Index': link_index,
        'Löpnummer_Byte_0': sequence_byte,
        'WP_ID': wp_id,
    }


def count_routes_from_header(header_bytes: bytes) -> int:
    """Räknar antalet rutter från Byte 13 i filheadern."""
    if len(header_bytes) < 16:
        return 0
    
    byte_13_val = header_bytes[13]
    count_from_byte_13 = byte_13_val - 129
    
    return count_from_byte_13

def show_bits(byte_data: bytes) -> str:
    """
    Tar in en bytesekvens och returnerar en sträng med binära värden
    och deras motsvarande decimala värden i parentes.
    
    Exempel: b'\x48\x01' -> '01001000 (72) 00000001 (1)'
    """
    output_parts = []
    
    for b in byte_data:
        # 1. Konvertera byten till 8-bitars binär sträng
        bin_str = f'{b:08b}'
        
        # 2. Decimalt värde
        decimal_val = b
        
        # 3. Kombinera formatet: "binär (decimal)"
        output_parts.append(f'{bin_str} ({RÖD}{decimal_val}{VIT})')
        
    return ' '.join(output_parts)


def process_route_file(file_path: str) -> List[Dict[str, Any]]:
    
    if not os.path.exists(file_path):
        print(f"Fel: Filen hittades inte på {file_path}")
        return []

    routes_data = []

    with open(file_path, 'rb') as f:
        
        # 1. FIL-NIVÅ: Läs Headern (Byte 0-15)
        
        # Vi läser de första 16 bytena för headern
        file_header_data = f.read(FILE_HEADER_SIZE)
        
        if len(file_header_data) < FILE_HEADER_SIZE:
             print("Fel: Filen är för kort för att innehålla en komplett filheader.")
             return []
             
        total_routes_expected = count_routes_from_header(file_header_data)
        
        
        # Vi sätter läspekaren till Byte 16, som är starten på Rutt 1 (och Master Namnet)
        f.seek(ROUTE_START_OFFSET)
        
        # Huvudet för Rutt 1 (Byte 16-39) har redan lästs i master_name_bytes, 
        # men i din nya modell fortsätter ruttdatan efter Byte 39.

        # Vi sätter startpunkten för varje rutt till Byte 16 + N * 500
        start_of_route_data = ROUTE_START_OFFSET
        
        # För att förenkla och följa din modell: Vi ignorerar Master Namn läst från f.read(24) ovan
        # och läser in det igen i Rutt 1's block.
        
        for route_num in range(total_routes_expected):
            
            route_start_offset = start_of_route_data + (route_num * ROUTE_TOTAL_SIZE)
            f.seek(route_start_offset)
            
            route_links = []
            link_index = 1
            bytes_read_in_waypoints = 0
            
            # Läs den 20-byte Rutt-headern (Byte 0-19 i det 500-byte blocket)
            ROUTE_BLOCK_HEADER_SIZE = 20 # Sätts till 20 här för funktionen
            route_header_data = f.read(ROUTE_BLOCK_HEADER_SIZE)
            
            if len(route_header_data) < ROUTE_BLOCK_HEADER_SIZE:
                break 

            # Avkoda Ruttnamnet från de första 8 bytena av Rutt-Headern
            current_route_name = extract_6bit_fields(route_header_data[0:8], num_chars=10)

            # visa headerstart och destination
            current_route_start = extract_6bit_fields(route_header_data[8:12], num_chars=4)
            current_route_dest = extract_6bit_fields(route_header_data[12:16], num_chars=4)

            # visa headerbits
            current_route_header = show_bits(route_header_data[8:16])

            # visa kontrollbitsen
            current_route_controlbits = show_bits(route_header_data[16:20])

            # Starten för wpts är efter Rutt-Headern (Byte 20 i blocket)
            waypoint_data_start_offset = route_start_offset + ROUTE_BLOCK_HEADER_SIZE 
            f.seek(waypoint_data_start_offset)

            # Loopa genom det återstående utrymmet i 500-byte blocket
            while bytes_read_in_waypoints < (ROUTE_TOTAL_SIZE - ROUTE_BLOCK_HEADER_SIZE):
                link_data = f.read(ROUTE_LINK_SIZE)
                
                if len(link_data) < ROUTE_LINK_SIZE:
                    break
                
                # Snabbkoll för att ignorera rena paddingblock
                if link_data[0:4] == b'\x00\x00\x00\x00' and link_data[24:28] == b'\x8c\x00\x00\x00': 
                     break 

                link_record = decode_route_link(link_data, link_index)
                
                # Filtrera bort tomma wpts (Löpnummer 0 OCH ingen WP ID)
                if link_record['Löpnummer_Byte_0'] != 0 or link_record['WP_ID']:
                    route_links.append(link_record)
                
                link_index += 1
                bytes_read_in_waypoints += ROUTE_LINK_SIZE
            
            routes_data.append({
                'Ruttnummer': route_num + 1,
                'RuttNamn': current_route_name, 
                'RuttStart': current_route_start,
                'RuttDest': current_route_dest,
                'RuttHeader': current_route_header,
                'RuttKontrollbitar': current_route_controlbits,
                'Wpts': route_links,
                'Totalt_antal_wpts_hittade': len(route_links)
            })

    return routes_data

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Användning: python ditt_skriptnamn.py <ruttfil>")
        sys.exit(1)

    file_to_parse = sys.argv[1] 
    
    all_routes_data = process_route_file(file_to_parse)

    if all_routes_data:
        print("\n" + "=" * 80)
        print(f"AVKODNING RESULTAT: {file_to_parse}")
        print("=" * 80)
        
        for route in all_routes_data:
            num_links = len(route['Wpts'])
            
            print(f"\n{GUL}--- {route['Ruttnummer']} {route['RuttNamn']} ---{VIT}")
            if route['RuttStart'] or route['RuttDest']: 
                print(f"{GRÖN}Start: {route['RuttStart']} Destination: {route['RuttDest']} {VIT}")
            print(f"header: {route['RuttHeader']}")
            print(f"Kontrollbitar: {route['RuttKontrollbitar']}   Hittade {num_links} wpts.")
            
            if num_links > 0:
                for link in route['Wpts']:
                    print(f"  Index {link['Index']}: ID='{link['WP_ID']}' | Löpnummer={link['Löpnummer_Byte_0']}")
            else:
                print("  Inga giltiga wpts hittades (Block troligen fyllda med noll-padding).")
    else:
        print("Kunde inte tolka ruttdata.")
