# Euronav5 DMG Database Format – Complete Specification

**Status**: ✓ COMPLETE (May 24, 2026)  
**Scope**: Vector object storage in USER*.tbl binary database  
**Record size**: 256 bytes (fixed)  
**Character encoding**: 6-bit custom (see EURONAV5_FORMAT_MAIN.md)

---

## Record Structure (256 bytes)

### Record Header (0x00 – 0x10)

| Offset | Size | Field | Type | Description |
|--------|------|-------|------|-------------|
| 0x00 | 1 | RecordType | u8 | Record classification: `0x00` (data), `0x10` (circle geometry), `0x4e` (area) |
| 0x01 | 1 | Unknown | u8 | Varies; context-dependent |
| 0x02 | 1 | PointIndex | u8 | Point number within figure (0=header, 1+=geometry points) |
| 0x03 | 5 | Padding | — | Unused |

### Figure Metadata (0x08 – 0xb9)

| Offset | Size | Field | Type | Description |
|--------|------|-------|------|-------------|
| 0x08 | 8 | Name | 6-bit* | Figure/object name (max 8 chars encoded) |
| 0x10 | 4 | Unknown | u8[4] | Rendering hints or metadata flags |
| 0x14 | 1 | Unknown | u8 | Varies; context-dependent |
| 0x15 – 0xaa | Variable | — | — | Metadata and color fields (see below) |

### Data Fields (0x9a – 0xff)

| Offset | Size | Field | Type | Description |
|--------|------|-------|------|-------------|
| 0x9a | 2 | StyleClassID | u16 LE | Style Class ID (low, high bytes) = low \| (high << 8) |
| 0x9c | 2 | Latitude | f32 BE* | Geographic latitude (degrees, -90 to +90) |
| 0xa0 | 2 | Longitude | f32 BE* | Geographic longitude (degrees, -180 to +180) |
| 0xa4 | 1 | Radius/Type | — | For circles: radius code; for areas: geometry type |
| 0xa5 | 1 | Unknown | u8 | Context-dependent |
| 0xa6 | 1 | ZoneType | 6-bit* | Zone classification (RESTRICTEDZONE, DANGERZONE, etc.) |
| 0xa8 – 0xbb | — | — | — | Figure counter and metadata continuation |
| 0xad | 1 | LineColorOverride | u8 | Line color code (0x00=default, other=specific) |
| 0xae | 1 | RenderingFlag | u8 | Rendering context indicator |
| 0xb0–0xb3 | 4 | FigureCounter | u32 BE | Sequential figure number across entire file |
| 0xb4 | 16 | ZoneName | 6-bit* | Zone or area name (null-terminated, 6-bit encoded) |
| 0xdb | 1 | GeometryType | u8 | Geometry classifier: ≤0x7f=line, >0x7f=polygon |
| 0xdd–0xde | 2 | PointClassification | u16 | Point type code (reserved field) |
| 0xdf | 1 | VersionFlag | u8 | Format version: 0x00=test, 0x09=production |
| 0xec | 1 | PolygonStrokeColor | u8 | Polygon stroke color code (0x00=none) |
| 0xed | 1 | PolygonFillColor | u8 | Polygon fill color code (0x00=none) |
| 0xc2–0xd6 | — | Reference | — | Figure/geometry reference field (context-dependent) |
| 0xe3–0xef | 7 | Metadata | u8[7] | Padding and status; byte 0xeb=status flag |

**\* = 6-bit character encoding or special type**

---

## Record Types

### Type 0x00 – Data Record (DRAWING or Figure Header)

Used for lines, polylines, and figure initialization.

```
RecordType: 0x00
PointIndex: 0 (header) or 1+ (geometry points)
Coordinates: 0x9c (lat), 0xa0 (lon)
StyleClassID: 0x9a-0x9b
FigureCounter: 0xb0-0xb3 (auto-increment)
```

**Figure Header (PointIndex=0)**:
- Initializes a new figure
- Sets name, style, and other metadata
- FigureCounter increments

**Geometry Points (PointIndex=1+)**:
- One point per record
- Continues FigureCounter from header
- Coordinate pair (lat, lon)

### Type 0x10 – Geometry Record (CIRCLE POINT or AREA METADATA)

Used for circle radii or area zone metadata.

```
RecordType: 0x10
PointIndex: 0 (metadata) or 1+ (radius/geometry points)
Coordinates: Center (lat, lon) or geometry metadata
```

In multi-record area figures:
- Separates figure header from radius/zone records
- Used to mark circle center and define radius

### Type 0x4e – Area Record (ZONE BOUNDARY)

Used exclusively for area/zone objects.

```
RecordType: 0x4e
PointIndex: 0 (header) or 1+ (boundary points)
ZoneType: 0xa6 (6-bit: RESTRICTEDZONE, DANGERZONE, etc.)
ZoneName: 0xb4 (null-terminated, 6-bit encoded)
```

---

## Coordinate System

### Geographic Coordinates

Stored as 32-bit IEEE 754 big-endian floats:

```
Latitude (0x9c):  -90.0 to +90.0 degrees
Longitude (0xa0): -180.0 to +180.0 degrees

Example: 59.3293°N, 18.0686°E
  lat = 59.3293 (stored as big-endian float)
  lon = 18.0686 (stored as big-endian float)
```

### Area Geometry

For area (type 0x4e) records:

**Circle**:
- Header (PointIndex=0): Sets name, style, zone type
- Point 1 (PointIndex=1): Center coordinates (lat, lon)
- Point 2 (PointIndex=2): Radius point; distance determines circle size

**Polygon**:
- Header (PointIndex=0): Sets name, style, zone type
- Points 1–N (PointIndex=1+): Boundary vertices (auto-closed)
- Recognized by GeometryType (0xdb > 0x7f)

---

## Style Class ID Mapping

### Encoding

```
bytes_0x9a-0x9b = [low, high]
styleClassID = low | (high << 8)

Example:
  byte_0x9a = 0x44
  byte_0x9b = 0x02
  styleClassID = 0x44 | (0x02 << 8) = 0x0244
```

### Decoding

```c
uint16_t low = data[0x9a];
uint16_t high = data[0x9b];
uint16_t styleClassID = low | (high << 8);
```

The Style Class ID is used to look up rendering properties in `appMatrix.json`.

---

## Figure Counter (0xb0-0xb3)

**Type**: 32-bit big-endian unsigned integer  
**Scope**: Sequential across entire file  
**Purpose**: Uniquely identify multi-record figures

```
Record 0: FigureCounter = 0x00000000
Record 1: FigureCounter = 0x00000000 (same figure)
Record 2: FigureCounter = 0x00000001 (new figure)
Record 3: FigureCounter = 0x00000001 (same figure)
...
```

**Usage**:
- Group records with identical FigureCounter to reconstruct a single shape
- A figure may span 1–3 records depending on geometry

---

## Zone Types (6-bit Encoded at 0xa6)

Zone types classify area objects for aviation planning:

| Zone Type | 6-bit Code | Purpose |
|-----------|-----------|---------|
| RESTRICTEDZONE | 0x1F (31) | Restricted airspace |
| DANGERZONE | 0x1E (30) | High-hazard area |
| NAVIGATIONALZONE | 0x1B (27) | Navigation reference |
| PROHIBITEDZONE | 0x18 (24) | Prohibited airspace |
| OBSTACLE | 0x10 (16) | Ground obstacle or terrain hazard |

Zone name (0xb4) provides a human-readable label, null-terminated and 6-bit encoded.

---

## Color Overrides (0xad, 0xec-0xed)

### Line Color (0xad)

Overrides line color from style (appMatrix):

```
0x00: Use style default
Other: Specific color code from appMatrix palette
```

Applied to DRAWING (lines) and area boundaries.

### Polygon Colors (0xec-0xed)

Override polygon rendering from style:

```
0xec (Polygon Stroke): Border color code
  0x00 = no border (or use default)
  Other = specific color

0xed (Polygon Fill): Fill color code
  0x00 = no fill (or use default)
  Other = specific color
```

Applied only to area records with polygon geometry (0xdb > 0x7f).

---

## Geometry Type (0xdb)

Determines whether area uses line or polygon rendering:

```
0xdb ≤ 0x7f: Line rendering (e.g., boundary is a polyline)
0xdb > 0x7f: Polygon rendering (e.g., filled area)
```

**Production validation**: Confirmed via 25,736 line records (≤0x7f) and 507 polygon records (>0x7f).

---

## 6-Bit Character Encoding

Text fields (Name, ZoneType, ZoneName) use custom 6-bit encoding:

### Character Map

```
Code   Char   Code   Char   Code   Char   Code   Char
----   ----   ----   ----   ----   ----   ----   ----
0      [pad]  11     '-'    14-23  '0'-'9'  30-55  'A'-'Z'
```

### Packing (5 chars per 4 bytes)

Each 4-byte block stores 5 characters (30 bits used, 2 padding bits):

```
Byte layout: [char0:6bit][char1:6bit][char2:6bit][char3:6bit][char4:6bit][pad:2bit]
             [bits 0-5]  [bits 6-11] [bits 12-17][bits 18-23][bits 24-29][bits 30-31]
```

**Example**: Name "RUNWAY01"
```
Encoded as 6-bit values: R(48) U(50) N(43) W(54) A(30) Y(54) 0(14) 1(15)
Packed into 2 blocks (8 bytes total, since 8 chars requires 2×4 bytes for 10 char capacity)
```

---

## Multi-Record Figures

Some objects require 2-3 records to fully specify geometry:

### Single-Record Figure
```
Record 0:
  RecordType: 0x00 (DRAWING)
  PointIndex: 0 (header)
  FigureCounter: N
  Coordinates: (lat, lon) — single point
  Result: Point object
```

### Multi-Record Figure (2 records)
```
Record 0:
  RecordType: 0x00 (DRAWING)
  PointIndex: 0 (header)
  FigureCounter: N
  Coordinates: (lat, lon) — start

Record 1:
  RecordType: 0x00 (DRAWING)
  PointIndex: 1 (point 2)
  FigureCounter: N (same)
  Coordinates: (lat, lon) — end
  Result: 2-point line segment
```

### Multi-Record Figure (3+ records)
```
Record 0:
  RecordType: 0x00 or 0x4e
  PointIndex: 0 (header)
  FigureCounter: N
  Coordinates: (lat, lon) — point 1

Record 1:
  RecordType: 0x10 (geometry marker)
  PointIndex: 1
  FigureCounter: N (same)
  Coordinates: (lat, lon) — point 2

Record 2:
  RecordType: 0x10 (geometry continuation)
  PointIndex: 2
  FigureCounter: N (same)
  Coordinates: (lat, lon) — point 3 or radius
  Result: Multi-point polyline or circle
```

---

## Parsing Algorithm

```pseudo
figures = {}
for each 256-byte record in file:
    recordType = record[0x00]
    pointIndex = record[0x02]
    figureCounter = record[0xb0:0xb3] as uint32_be
    
    if figureCounter not in figures:
        figures[figureCounter] = {
            type: 'DRAWING' or 'AREA' (from recordType),
            name: decode_6bit(record[0x08]),
            styleClassID: record[0x9a] | (record[0x9b] << 8),
            points: [],
            zoneType: decode_6bit(record[0xa6]) if AREA,
            zoneName: decode_6bit(record[0xb4]) if AREA
        }
    
    # Add geometry point
    if pointIndex > 0:
        lat = record[0x9c:0xa0] as float32_be
        lon = record[0xa0:0xa4] as float32_be
        figures[figureCounter].points.append((lat, lon))

return list(figures.values())
```

---

## Version Flags (0xdf)

| Value | Meaning | Context |
|-------|---------|---------|
| 0x00 | Test database | Used in development/test datasets |
| 0x09 | Production | Used in production vector maps |
| Other | Reserved | Undefined behavior |

---

## Decoding Example

**Raw bytes**:
```
0x00: 0x00 (RecordType = DRAWING)
0x08: 0x93 0x84 0x24 0x00 0x00 0x00 0x00 0x00 (Name = "RUNWAY" in 6-bit)
0x9a: 0x34 (StyleID low)
0x9b: 0x00 (StyleID high)
0x9c: 0x42 0x70 0x27 0x00 (Latitude = 60.502...)
0xa0: 0x42 0x70 0x27 0x00 (Longitude = 60.502... — shifted for clarity)
0xb0: 0x00 0x00 0x00 0x01 (FigureCounter = 1)
```

**Decoded**:
```
RecordType: DRAWING (0x00)
StyleClassID: 0x0034
Coordinates: (60.502°, 60.502°)
FigureCounter: 1 (figures with counter=1 form a single shape)
```

---

## Worked Examples – Creating Records

### Example 1: Create a Single-Point DRAWING

**Goal**: Create a point marker at 59.3293°N, 18.0686°E named "WAYPOINT01" with Style Class 0x0034 (default).

**Bytes to construct** (256-byte record):

```python
import struct

record = bytearray(256)

# Header
record[0x00] = 0x00                          # RecordType: DRAWING
record[0x02] = 0x00                          # PointIndex: 0 (header)

# Name (8 bytes, 6-bit encoded "WAYPOINT")
# W=54, A=30, Y=54, P=45, O=44, I=34, N=43, T=53
# Encode: 54*1 + 30*64 + 54*4096 + 45*262144 + 44*16777216 + 34*1073741824 + 43*68719476736 + 53*4398046511104
# Simpler: use 6-bit packing function (see 6-bit encoding section)
record[0x08:0x10] = encode_6bit("WAYPOINT")

# Style Class ID (bytes 0x9a-0x9b)
record[0x9a] = 0x34                          # Low byte
record[0x9b] = 0x00                          # High byte
# styleClassID = 0x34 | (0x00 << 8) = 0x0034

# Coordinates (IEEE 754 big-endian floats)
lat_bytes = struct.pack('>f', 59.3293)
lon_bytes = struct.pack('>f', 18.0686)
record[0x9c:0xa0] = lat_bytes
record[0xa0:0xa4] = lon_bytes

# Figure Counter (bytes 0xb0-0xb3, big-endian)
figure_counter = 0  # First figure
record[0xb0:0xb4] = struct.pack('>I', figure_counter)

# Version flag (byte 0xdf)
record[0xdf] = 0x09                          # Production

return bytes(record)
```

**Result**: 256-byte record representing a single point.

---

### Example 2: Create a Multi-Point DRAWING (2 Records)

**Goal**: Create a line from (59.0°, 18.0°) to (59.5°, 18.5°) named "ROUTE01", Style 0x0244.

**Record 1 (Header)**:
```python
record1 = bytearray(256)
record1[0x00] = 0x00                         # RecordType: DRAWING
record1[0x02] = 0x00                         # PointIndex: 0 (header)
record1[0x08:0x10] = encode_6bit("ROUTE01")

record1[0x9a] = 0x44                         # Style low byte
record1[0x9b] = 0x02                         # Style high byte (0x0244)

record1[0x9c:0xa0] = struct.pack('>f', 59.0)  # Start lat
record1[0xa0:0xa4] = struct.pack('>f', 18.0)  # Start lon

record1[0xb0:0xb4] = struct.pack('>I', 0)   # FigureCounter: 0
record1[0xdf] = 0x09

return bytes(record1)
```

**Record 2 (Point 2)**:
```python
record2 = bytearray(256)
record2[0x00] = 0x00                         # RecordType: DRAWING
record2[0x02] = 0x01                         # PointIndex: 1 (second point)
record2[0x08:0x10] = encode_6bit("ROUTE01") # Same name

record2[0x9a] = 0x44                         # Same style
record2[0x9b] = 0x02

record2[0x9c:0xa0] = struct.pack('>f', 59.5)  # End lat
record2[0xa0:0xa4] = struct.pack('>f', 18.5)  # End lon

record2[0xb0:0xb4] = struct.pack('>I', 0)   # FigureCounter: 0 (same figure!)
record2[0xdf] = 0x09

return bytes(record2)
```

**Key**: Both records have identical FigureCounter (0), so they form a single 2-point line.

---

### Example 3: Create an AREA (Circle)

**Goal**: Create a restricted zone circle at (59.2°, 18.1°) with name "ZONE01", type RESTRICTEDZONE.

**Record 1 (Header)**:
```python
record1 = bytearray(256)
record1[0x00] = 0x4e                         # RecordType: AREA
record1[0x02] = 0x00                         # PointIndex: 0

record1[0x08:0x10] = encode_6bit("ZONE01")

# Style for area (typically contains fill/stroke)
record1[0x9a] = 0x50
record1[0x9b] = 0x03  # 0x0350

# Zone type (0xa6, 6-bit: RESTRICTEDZONE = 0x1F = 31)
record1[0xa6] = 31

# Zone name (0xb4, 6-bit encoded)
record1[0xb4:0xb4+16] = encode_6bit("RESTRICTEDZONE")

record1[0xb0:0xb4] = struct.pack('>I', 100)  # FigureCounter: 100
record1[0xdf] = 0x09

return bytes(record1)
```

**Record 2 (Center Point)**:
```python
record2 = bytearray(256)
record2[0x00] = 0x10                         # RecordType: GEOMETRY/CIRCLE
record2[0x02] = 0x01                         # PointIndex: 1

record2[0x9c:0xa0] = struct.pack('>f', 59.2)   # Center lat
record2[0xa0:0xa4] = struct.pack('>f', 18.1)   # Center lon

record2[0xb0:0xb4] = struct.pack('>I', 100)  # FigureCounter: 100 (same figure)
record2[0xdf] = 0x09

return bytes(record2)
```

**Record 3 (Radius Point)**:
```python
record3 = bytearray(256)
record3[0x00] = 0x10                         # RecordType: GEOMETRY
record3[0x02] = 0x02                         # PointIndex: 2

# Radius point (distance from center determines radius)
# If center is (59.2, 18.1) and radius point is (59.25, 18.1),
# distance ≈ 0.05 degrees ≈ 5.5 km
record3[0x9c:0xa0] = struct.pack('>f', 59.25)  # Radius lat
record3[0xa0:0xa4] = struct.pack('>f', 18.1)   # Radius lon (same as center)

record3[0xb0:0xb4] = struct.pack('>I', 100)  # FigureCounter: 100 (same figure)
record3[0xdf] = 0x09

return bytes(record3)
```

**Result**: 3-record figure representing a circle with FigureCounter=100.

---

### 6-Bit Encoding Helper

```python
def encode_6bit(text, length=8):
    """Encode text to 6-bit format, 5 chars per 4 bytes."""
    char_map = {
        '-': 11, '0': 14, '1': 15, '2': 16, '3': 17, '4': 18,
        '5': 19, '6': 20, '7': 21, '8': 22, '9': 23,
        'A': 30, 'B': 31, 'C': 32, 'D': 33, 'E': 34, 'F': 35,
        'G': 36, 'H': 37, 'I': 38, 'J': 39, 'K': 40, 'L': 41,
        'M': 42, 'N': 43, 'O': 44, 'P': 45, 'Q': 46, 'R': 47,
        'S': 48, 'T': 49, 'U': 50, 'V': 51, 'W': 52, 'X': 53,
        'Y': 54, 'Z': 55
    }
    
    # Pad to multiple of 5
    text = text.upper().ljust(5 * ((len(text) + 4) // 5), '\x00')
    result = bytearray()
    
    for i in range(0, len(text), 5):
        chunk = text[i:i+5]
        c0 = char_map.get(chunk[0], 0)
        c1 = char_map.get(chunk[1], 0)
        c2 = char_map.get(chunk[2], 0)
        c3 = char_map.get(chunk[3], 0)
        c4 = char_map.get(chunk[4], 0)
        
        # Pack 5 × 6-bit chars into 4 bytes (30 bits + 2 padding)
        value = c0 | (c1 << 6) | (c2 << 12) | (c3 << 18) | (c4 << 24)
        result.extend(struct.pack('>I', value))
    
    return result[:length]
```

---

## Appendix: Field Reference Table

Complete field offsets and interpretations:

| Offset | Size | Common Name | Type | Notes |
|--------|------|-------------|------|-------|
| 0x00 | 1 | RecordType | u8 | 0x00, 0x10, 0x4e |
| 0x02 | 1 | PointIndex | u8 | 0+ (0=header) |
| 0x08 | 8 | Name | 6-bit* | Figure name |
| 0x9a–0x9b | 2 | StyleClassID | u16 LE | Lookup in appMatrix |
| 0x9c | 4 | Latitude | f32 BE | Degrees |
| 0xa0 | 4 | Longitude | f32 BE | Degrees |
| 0xa6 | 1 | ZoneType | 6-bit* | AREA only |
| 0xad | 1 | LineColor | u8 | Override |
| 0xb0–0xb3 | 4 | FigureCounter | u32 BE | Multi-record grouping |
| 0xb4 | 16 | ZoneName | 6-bit* | AREA only |
| 0xdb | 1 | GeometryType | u8 | ≤0x7f=line, >0x7f=polygon |
| 0xec | 1 | PolyStroke | u8 | Override |
| 0xed | 1 | PolyFill | u8 | Override |
| 0xdf | 1 | VersionFlag | u8 | 0x00=test, 0x09=prod |
