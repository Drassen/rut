import struct
from datetime import datetime
import os

# -- Definiera datastrukturer för att representera en rutt --
# (Motsvarar dina Swift-modeller)
class RoutePoint:
    def __init__(self, ident, latitude, longitude):
        self.ident = ident
        self.latitude = latitude
        self.longitude = longitude

class Route:
    def __init__(self, name, points):
        self.name = name
        self.points = points

# -- Konstanter för filformatet --
SIZE_AIRPORT = 4020
SIZE_NAVAID = 4020
SIZE_WAYPOINT = 2820
SIZE_ROUTE = 50020
SIZE_CARACTER = 116

RECORD_LENGTH = 60
ROUTE_RECORD_LENGTH = 48
MAX_FIXES_PER_ROUTE = 15

# -- Binära hjälpfunktioner --

def pad_string(s, length, padding_char=b'\x00'):
    """Paddar en sträng till en fast längd med en specifik byte."""
    encoded_s = s.encode('ascii')
    return encoded_s.ljust(length, padding_char)

def pack_be_float(f):
    """Packar ett flyttal till 4 bytes, Big Endian."""
    return struct.pack('>f', f)

def pack_be_u32(i):
    """Packar ett 32-bitars heltal till 4 bytes, Big Endian."""
    return struct.pack('>I', i)

def pack_be_u16(i):
    """Packar ett 16-bitars heltal till 2 bytes, Big Endian."""
    return struct.pack('>H', i)

# -- Funktioner för att bygga varje fil --

def determine_point_type(ident):
    """Avgör om en punkt är en flygplats eller waypoint baserat på ID."""
    if len(ident) == 4 and ident.isalpha():
        return 'airport'
    return 'waypoint'

def create_table_data(points, total_size):
    """Skapar binärdata för WAYPOINT.P01 och AIRPORT.P01."""
    max_records = (total_size - 4) // RECORD_LENGTH
    if len(points) > max_records:
        raise ValueError(f"För många punkter ({len(points)}). Max är {max_records}.")

    file_data = bytearray(total_size)

    # 1. Skriv fil-headern (antalet poster)
    file_data[0:4] = pack_be_u32(len(points))
    
    # 2. Skriv varje 60-bytes post
    current_offset = 4
    for point in points:
        record_data = bytearray(RECORD_LENGTH)

        # Bytes 0-3: Latitude (Float32, Big Endian)
        record_data[0:4] = pack_be_float(point.latitude)
        
        # Bytes 4-7: Longitude (Float32, Big Endian)
        record_data[4:8] = pack_be_float(point.longitude)
        
        # Bytes 8-15: Kort ID (8 bytes, NULL-paddat)
        record_data[8:16] = pad_string(point.ident.upper(), 8)
        
        # Bytes 16-39: Långt Namn (24 bytes, NULL-paddat)
        record_data[16:40] = pad_string(point.ident.upper(), 24)
        
        # Resten är metadata (nollor)
        
        file_data[current_offset:current_offset + RECORD_LENGTH] = record_data
        current_offset += RECORD_LENGTH
        
    return bytes(file_data)

def create_route_data(route, airport_index_map, waypoint_index_map):
    """Skapar binärdata för ROUTE.P01."""
    file_data = bytearray(SIZE_ROUTE)
    
    if not route.points:
        return bytes(file_data) # Returnera en tom fil om rutten är tom

    if len(route.points) > MAX_FIXES_PER_ROUTE:
        raise ValueError(f"Rutten har för många punkter ({len(route.points)}). Max är {MAX_FIXES_PER_ROUTE}.")

    record_data = bytearray(ROUTE_RECORD_LENGTH)

    # Bytes 0-7: Ruttens namn, NULL-paddad
    record_data[0:8] = pad_string(route.name.upper(), 8)

    # Hitta start- och slutpunktens index och typ
    first_point = route.points[0]
    last_point = route.points[-1]

    if determine_point_type(first_point.ident) == 'airport':
        from_type_id, from_index = 4, airport_index_map[first_point.ident.upper()]
    else:
        from_type_id, from_index = 6, waypoint_index_map[first_point.ident.upper()]
        
    if determine_point_type(last_point.ident) == 'airport':
        to_type_id, to_index = 4, airport_index_map[last_point.ident.upper()]
    else:
        to_type_id, to_index = 6, waypoint_index_map[last_point.ident.upper()]

    # Bytes 8-15: Från/Till information (UInt16, Big Endian)
    record_data[8:10] = pack_be_u16(from_type_id)
    record_data[10:12] = pack_be_u16(from_index)
    record_data[12:14] = pack_be_u16(to_type_id)
    record_data[14:16] = pack_be_u16(to_index)
    
    # Bytes 16-17: Antalet punkter i rutten (UInt16, Big Endian)
    record_data[16:18] = pack_be_u16(len(route.points))
    
    # Bytes 18-47: Listan med fixar
    fix_offset = 18
    for point in route.points:
        if determine_point_type(point.ident) == 'airport':
            point_type_id, point_index = 4, airport_index_map[point.ident.upper()]
        else:
            point_type_id, point_index = 6, waypoint_index_map[point.ident.upper()]
            
        record_data[fix_offset:fix_offset + 2] = struct.pack('>BB', point_type_id, point_index)
        fix_offset += 2
        
    # Skriv posten till fil-datan
    file_data[4:4 + ROUTE_RECORD_LENGTH] = record_data
    
    return bytes(file_data)

def create_pilot_header(sizes):
    """Skapar binärdata för PILOTE.HD."""
    header_data = bytearray(44)
    
    # Bytes 0-11: Databasnamn, space-paddad
    now = datetime.now()
    dtd_string = f"DTD{now.day}{now.month}{now.year}"
    header_data[0:12] = pad_string(dtd_string, 12, padding_char=b' ')
    
    # Bytes 24-43: Filstorlekar (UInt32, Big Endian)
    header_data[24:28] = pack_be_u32(sizes['AIRPORT.P01'])
    header_data[28:32] = pack_be_u32(sizes['NAVAID.P01'])
    header_data[32:36] = pack_be_u32(sizes['WAYPOINT.P01'])
    header_data[36:40] = pack_be_u32(sizes['ROUTE.P01'])
    header_data[40:44] = pack_be_u32(sizes['CARACTER.P01'])
    
    return bytes(header_data)

def export_dataset(route):
    """Huvudfunktion som skapar ett helt dataset från ett Route-objekt."""
    
    airport_list = []
    waypoint_list = []
    airport_index_map = {}
    waypoint_index_map = {}

    for point in route.points:
        ident = point.ident.upper()
        if determine_point_type(ident) == 'airport':
            if ident not in airport_index_map:
                airport_index_map[ident] = len(airport_list)
                airport_list.append(point)
        else:
            if ident not in waypoint_index_map:
                waypoint_index_map[ident] = len(waypoint_list)
                waypoint_list.append(point)

    # Skapa binärdata för varje fil
    airport_data = create_table_data(airport_list, SIZE_AIRPORT)
    waypoint_data = create_table_data(waypoint_list, SIZE_WAYPOINT)
    
    # Skapa tomma filer med korrekt header (count=0)
    navaid_data = bytearray(SIZE_NAVAID)
    navaid_data[0:4] = pack_be_u32(0)
    
    caracter_data = bytearray(SIZE_CARACTER)
    
    route_data = create_route_data(route, airport_index_map, waypoint_index_map)
    
    file_sizes = {
        'AIRPORT.P01': len(airport_data),
        'NAVAID.P01': len(navaid_data),
        'WAYPOINT.P01': len(waypoint_data),
        'ROUTE.P01': len(route_data),
        'CARACTER.P01': len(caracter_data)
    }
    
    header_data = create_pilot_header(file_sizes)

    return {
        "PILOTE.HD": header_data,
        "AIRPORT.P01": airport_data,
        "NAVAID.P01": bytes(navaid_data),
        "WAYPOINT.P01": waypoint_data,
        "ROUTE.P01": route_data,
        "CARACTER.P01": bytes(caracter_data)
    }


# -- EXEMPEL PÅ ANVÄNDNING --
if __name__ == "__main__":
    # 1. Definiera en rutt med några punkter
    #    Använder kända punkter från de tidigare loggfilerna.
    
    # Rutt från MRP-01 till MRP-02, via flygplatsen ESCF
    example_route = Route(
        name="TEST1",
        points=[
            RoutePoint(ident="MRP01", latitude=58.46851, longitude=15.47884),
            RoutePoint(ident="ESCF", latitude=58.39611, longitude=15.52194),
            RoutePoint(ident="MRP00", latitude=58.44341, longitude=15.41739),
        ]
    )

    # 2. Anropa exportfunktionen
    try:
        dataset_files = export_dataset(example_route)
        
        # 3. Spara filerna till disk i en mapp
        output_dir = "dataset_output"
        os.makedirs(output_dir, exist_ok=True)
        
        for filename, data in dataset_files.items():
            filepath = os.path.join(output_dir, filename)
            with open(filepath, "wb") as f:
                f.write(data)
            print(f"Sparade {filename} ({len(data)} bytes) i mappen '{output_dir}'")
            
        print("\nDataset genererat utan fel.")

    except ValueError as e:
        print(f"Ett fel inträffade: {e}")
