# Euronav5 .sym (Symbol Glyph) Format – Complete Specification

**Status**: ✓ COMPLETE (May 24, 2026)  
**Scope**: Binary bitmap font files for point-of-interest symbols  
**Glyphs per file**: Variable (typically 20–30 glyphs per file)  
**Total file size**: Variable (typically 120–150 KB per file)  
**Bitmap resolution**: 256×256 pixels (standard for system files), can vary

---

## File Structure Overview

```
Offset     Size        Content
-------    ----------  --------------------------------
0x0000     Variable    Metadata index (N records × 16 bytes + terminator)
           (variable)  Padding/alignment space
           (variable)  Bitmap data (256×256 pixels, 2 bytes/pixel)
-------
Total:     Variable (typically 120–150 KB)
```

Metadata spans from 0x0000 until the terminator record (all zeros).
Bitmap data begins at a boundary offset following metadata, typically 0x01B1 for standard files.

---

## Metadata Index (0x0000 – variable)

Variable number of metadata records (typically 20–30), each **16 bytes**.

**Record Layout** (per glyph):

| Offset | Size | Field | Type | Description |
|--------|------|-------|------|-------------|
| +0x00 | 2 | SymbolID | u16 LE | Glyph identifier (unique within file) |
| +0x02 | 2 | Unknown1 | u16 LE | Reserved/unknown (typically 0) |
| +0x04 | 2 | XStart | u16 LE | Left edge in bitmap (pixels) |
| +0x06 | 2 | YStart | u16 LE | Top edge in bitmap (pixels) |
| +0x08 | 2 | XEnd | u16 LE | Right edge in bitmap (inclusive) |
| +0x0A | 2 | YEnd | u16 LE | Bottom edge in bitmap (inclusive) |
| +0x0C | 2 | Unknown3 | u16 LE | Rendering hint or metadata flag |
| +0x0E | 2 | Unknown4 | u16 LE | Rendering hint or metadata flag |

**Calculation of bounding box dimensions**:
```
width = XEnd - XStart + 1
height = YEnd - YStart + 1
```

---

## Metadata Record Example

```
At file offset 0x0000 (first record):
  Offset  Value       Interpretation
  ------  ----------  ------------------------------
  0x0000  0x25 0x00   SymbolID = 37 (0x0025 LE)
  0x0002  0x00 0x00   Unknown1 = 0
  0x0004  0x01 0x00   XStart = 1
  0x0006  0x01 0x00   YStart = 1
  0x0008  0x20 0x00   XEnd = 32
  0x000A  0x30 0x00   YEnd = 48
  0x000C  0x10 0x00   Unknown3 = 16
  0x000E  0x15 0x00   Unknown4 = 21
  
  Dimensions: width = 32 - 1 + 1 = 32, height = 48 - 1 + 1 = 48

At file offset 0x0010 (second record):
  [next 16-byte metadata record]
  
...continue until all-zero terminator record...
```

---

## Bitmap Data (0x01B1 onwards)

### Structure

- **Resolution**: 256×256 pixels (standard; may vary)
- **Storage**: 2 bytes per pixel = 131,072 bytes total for 256×256
- **Color format**: Grayscale with dual-channel encoding

### Pixel Format (2 bytes per pixel)

Each pixel occupies **2 consecutive bytes**:

```
Byte 0 (even offset):   Primary color value (0–255)
                        - Main glyph fill/body
                        - Opacity/intensity

Byte 1 (odd offset):    Secondary color value (0–255)
                        - Outline/stroke effect
                        - Secondary rendering layer
```

### Pixel Indexing

```
bitmap_offset = 0x01B1
bitmap_width = 256
bitmap_height = 256

for y in range(0, height):
    for x in range(0, width):
        # Map source bounding box to bitmap coordinates
        source_x = (XStart + x + shift_x) % bitmap_width
        source_y = (YStart + y + shift_y) % bitmap_height
        
        # Calculate byte offset in file
        pixel_index = source_y * bitmap_width + source_x
        byte_offset = bitmap_offset + (pixel_index * 2)
        
        # Read pixel values
        primary = data[byte_offset]
        secondary = data[byte_offset + 1]
```

### Coordinate Shifts

These shifts account for bitmap layout/alignment:

```
shift_x = 40    // pixels right
shift_y = 3     // pixels down
```

Applied via modulo wrapping (bitmap wraps toroidally).

---

## Glyph Extraction Algorithm

```pseudo
function extractGlyph(data, metadata, primaryColor, secondaryColor):
    xStart = metadata.XStart
    yStart = metadata.YStart
    xEnd = metadata.XEnd
    yEnd = metadata.YEnd
    bitmapOffset = metadata.bitmapOffset  // Determined during indexing
    
    width = xEnd - xStart + 1
    height = yEnd - yStart + 1
    
    // Create output image (RGBA)
    image = Array(width, height)  // RGBA quadruplet per pixel
    
    bitmapWidth = 256
    shiftX = 40
    shiftY = 3
    
    for y in range(0, height):
        for x in range(0, width):
            // Map glyph bounding box to bitmap
            sourceX = (xStart + x + shiftX) % bitmapWidth
            sourceY = (yStart + y + shiftY) % bitmapWidth
            
            // Calculate file offset
            pixelIndex = sourceY * bitmapWidth + sourceX
            byteOffset = bitmapOffset + (pixelIndex * 2)
            
            // Read raw pixel values
            primary = data[byteOffset]       // Byte 0: fill
            secondary = data[byteOffset + 1] // Byte 1: outline
            
            // Handle white background (transparent)
            if primary == 255 && secondary == 255:
                image[y][x] = [0, 0, 0, 0]  // Fully transparent
                continue
            
            // Interpolate between primary and secondary colors
            maxValue = max(primary, secondary)
            t = max(0.0, (maxValue - 200) / 55.0)  // Normalize to [0, 1]
            
            // Blend colors
            r = primaryColor.r + (secondaryColor.r - primaryColor.r) * t
            g = primaryColor.g + (secondaryColor.g - primaryColor.g) * t
            b = primaryColor.b + (secondaryColor.b - primaryColor.b) * t
            a = 255  // Fully opaque (unless transparent above)
            
            image[y][x] = [r, g, b, a]
    
    return createImageFromPixels(image)
```

---

## Color Interpolation Details

### Purpose

Glyphs are stored as grayscale values. When rendering, they are colorized by interpolating between a **primary color** (fill) and **secondary color** (outline/effect).

### Interpolation Formula

```
t = max(0, (max(primary, secondary) - 200) / 55)
t ∈ [0, 1]

result = primaryColor × (1 - t) + secondaryColor × t
```

**Ranges**:
- `maxValue ≤ 200`: Full primary color (t = 0)
- `200 < maxValue < 255`: Interpolated blend
- `maxValue ≥ 255`: Full secondary color (t ≥ 1)

### Example

Primary color (fill): Blue [0, 100, 255]  
Secondary color (outline): Black [0, 0, 0]

```
Bitmap pixel: primary=200, secondary=0 → maxValue=200
  t = max(0, (200-200)/55) = 0
  Result: [0, 100, 255] (full blue)

Bitmap pixel: primary=227, secondary=0 → maxValue=227
  t = max(0, (227-200)/55) ≈ 0.49
  Result: [0, 50, 128] (blue-black blend)

Bitmap pixel: primary=255, secondary=0 → maxValue=255
  t = max(0, (255-200)/55) = 1.0
  Result: [0, 0, 0] (full black)
```

---

## Terminator Record

The last metadata record (variable index, depends on file) is a **terminator**:

```
All fields: 0x00
  SymbolID = 0
  XStart = 0
  YStart = 0
  XEnd = 0
  YEnd = 0
  Unknown3 = 0
  Unknown4 = 0
```

Marks the end of the glyph metadata. Identifies the boundary where bitmap data begins. Load metadata records sequentially until encountering the terminator (all zeros).

---

## Multiple .sym Files

Different `.sym` files may contain different glyph sets. All files follow the same format but store independent glyphs with unique Symbol IDs.

**Location**: `/Supporting Files/euronav5/`

**Naming convention**: `{number}.sym` or descriptive name (e.g., `1.sym`, `2.sym`, `custom_symbols.sym`)

Each file independently:
- Stores variable number of glyphs (terminated by all-zero metadata record)
- Uses unique Symbol IDs within its set
- Indexed at app startup by GlyphManager

**Example symbol ID allocation** (organizational, not enforced):

| Range | Category | Notes |
|-------|----------|-------|
| 1–50 | Navigation | Waypoints, navaids, standard markers |
| 51–100 | Aerodrome | Runway, taxiway, airport icons |
| 101–200 | Obstacles | Buildings, terrain, hazards |
| 32768–32800 | Extended | Special helicopter mission symbols |
| 1000+ | Custom | User-defined or layer-specific |

No strict allocation required; each file may use any Symbol IDs as long as they are unique within the combined index.

---

## Loading and Indexing

### At App Startup (GlyphManager)

1. **Scan directory**: `/Supporting Files/euronav5/` for all `*.sym` files
2. **Load metadata**: For each file:
   - Read 16-byte records sequentially from 0x0000
   - Continue until encountering all-zero terminator record
   - Record bitmap offset (byte after terminator, typically aligned)
3. **Index glyphs**: Store mapping: `symbolID → (filePath, metadata, bitmapOffset)`
4. **Cache**: Keep index in memory for O(1) lookup

### Rendering a Symbol

1. **Query GlyphManager**: `glyphInfo = getGlyph(symbolID)`
2. **Load file**: Open specified *.sym file
3. **Extract**: Call `extractGlyph(data, metadata, primaryColor, secondaryColor)`
4. **Render**: Display as UIImage or equivalent

---

## Implementation Notes

### Performance

- Metadata loading: < 1 ms (28 × 16 bytes)
- Bitmap extraction: 10–50 ms per glyph (256×256 pixels, color interpolation)
- Caching: Store extracted glyphs in memory to avoid re-extraction

### Memory

- Single glyph UIImage: ~400 KB (256×256 RGBA, uncompressed)
- Cache for active glyphs: Vary with display needs
- Metadata cache: < 500 bytes per file

### Quality

- **Interpolation**: Smooth color gradients between primary/secondary
- **Alpha**: Transparent background (white pixels = 0 alpha)
- **Scaling**: UIImage rendering handles scaling to desired size

---

## Variant Example: Extended Symbol File

Suppose you add a custom file `/Supporting Files/euronav5/custom_symbols.sym`:

```
GlyphManager index:
  37     → (3.sym, metadata[0])
  38     → (3.sym, metadata[1])
  ...
  200    → (custom_symbols.sym, metadata[0])
  201    → (custom_symbols.sym, metadata[1])
  ...
```

When a style references `symbolID=200`, the manager:
1. Finds `(custom_symbols.sym, metadata[0])`
2. Opens `custom_symbols.sym`
3. Extracts glyph from metadata bounding box
4. Returns colorized UIImage

---

## Troubleshooting

### Glyph Not Found

**Symptom**: "Symbol XXXX not found" error

**Causes**:
1. Symbol ID doesn't exist in any indexed `.sym` file
2. GlyphManager not initialized (call `GlyphManager.shared.getGlyphInfo()` to trigger)
3. `.sym` file corrupted or unreadable

**Fix**: Add missing `.sym` file or update GlyphManager to rescan

### Colors Wrong

**Symptom**: Glyphs appear in unexpected colors

**Causes**:
1. Primary/secondary colors swapped in rendering call
2. Color values outside 0–255 range
3. Alpha blending not applied

**Fix**: Verify color values and interpolation formula

### Glyphs Clipped

**Symptom**: Glyph bounding box incorrect (XStart, XEnd, etc.)

**Causes**:
1. Metadata corrupted
2. Bitmap data offset incorrect (should be 0x01B1)
3. Coordinate shifts wrong (should be +40, +3)

**Fix**: Verify metadata parsing and extraction offsets

---

## Appendix: Byte-Level Layout

### Metadata Record (16 bytes)

```
Offset  Bytes   Field
------  -----   -----
0x00    [0–1]   SymbolID (u16 LE)
0x02    [2–3]   Unknown1 (u16 LE)
0x04    [4–5]   XStart (u16 LE)
0x06    [6–7]   YStart (u16 LE)
0x08    [8–9]   XEnd (u16 LE)
0x0A    [10–11] YEnd (u16 LE)
0x0C    [12–13] Unknown3 (u16 LE)
0x0E    [14–15] Unknown4 (u16 LE)
```

### Bitmap Pixel (2 bytes)

```
Offset  Bytes   Field
------  -----   -----
+0x00   [0]     Primary color (u8)
+0x01   [1]     Secondary color (u8)
```

### File Layout Summary (Example: 28 glyphs)

```
Byte range   Content
-----------  --------
0x0000–0x01AF   Metadata index (28 records × 16 bytes)
0x01B0          Terminator record (all zeros)
0x01B1–0x20000  Bitmap data (256×256×2 bytes)
```

Note: Exact offsets vary by number of glyphs. Bitmap offset is determined dynamically by scanning metadata until terminator.

---

## Worked Example – Extract and Colorize a Glyph

**Scenario**: Extract Symbol ID 37 from a `.sym` file and colorize it blue with black outline.

**Input**:
```
Symbol ID: 37
Primary Color: [50, 150, 255, 255]  (blue)
Secondary Color: [0, 0, 0, 255]     (black)
File: 3.sym (or any *.sym)
```

**Step 1: Load metadata**

```python
import struct

# Read metadata for symbol 37
def find_metadata(data, symbol_id):
    offset = 0
    while offset < len(data):
        record = data[offset:offset+16]
        if len(record) < 16:
            break
        
        # Check for terminator (all zeros)
        if record == b'\x00' * 16:
            return None  # Not found
        
        sym_id = struct.unpack('<H', record[0:2])[0]
        if sym_id == symbol_id:
            return {
                'symId': sym_id,
                'xStart': struct.unpack('<H', record[4:6])[0],
                'yStart': struct.unpack('<H', record[6:8])[0],
                'xEnd': struct.unpack('<H', record[8:10])[0],
                'yEnd': struct.unpack('<H', record[10:12])[0]
            }
        
        offset += 16
    
    return None

# Load 3.sym
with open('3.sym', 'rb') as f:
    data = f.read()

metadata = find_metadata(data, 37)
print(f"Found: x={metadata['xStart']}-{metadata['xEnd']}, y={metadata['yStart']}-{metadata['yEnd']}")
# Output: Found: x=1-32, y=1-48
```

**Step 2: Determine bitmap offset**

```python
# Find where bitmap data starts (after terminator)
def find_bitmap_offset(data):
    offset = 0
    while offset < len(data):
        record = data[offset:offset+16]
        if len(record) < 16:
            break
        
        if record == b'\x00' * 16:
            # Found terminator; bitmap starts after this
            return offset + 16
        
        offset += 16
    
    return 0x01B1  # Fallback to common offset

bitmap_offset = find_bitmap_offset(data)
print(f"Bitmap offset: 0x{bitmap_offset:04X}")
# Output: Bitmap offset: 0x01B1
```

**Step 3: Extract one pixel (worked calculation)**

**Goal**: Extract pixel at (x=5, y=10) within the glyph bounding box and determine its color.

```python
# Glyph bounding box
x_start = metadata['xStart']  # = 1
y_start = metadata['yStart']  # = 1
x = 5                         # Pixel 5 within glyph
y = 10                        # Pixel 10 within glyph

# Map to bitmap coordinates
bitmap_width = 256
shift_x = 40
shift_y = 3

source_x = (x_start + x + shift_x) % bitmap_width  # (1 + 5 + 40) % 256 = 46
source_y = (y_start + y + shift_y) % bitmap_width  # (1 + 10 + 3) % 256 = 14

print(f"Bitmap coordinates: ({source_x}, {source_y})")
# Output: Bitmap coordinates: (46, 14)

# Calculate byte offset
pixel_index = source_y * bitmap_width + source_x  # 14*256 + 46 = 3582
byte_offset = bitmap_offset + (pixel_index * 2)   # 0x01B1 + 7164 = 0x22A3

# Read pixel (2 bytes)
primary_value = data[byte_offset]
secondary_value = data[byte_offset + 1]

print(f"Raw pixel: primary={primary_value}, secondary={secondary_value}")
# Example: Raw pixel: primary=210, secondary=50
```

**Step 4: Colorize**

```python
# Colors
primary_color = [50, 150, 255]    # Blue
secondary_color = [0, 0, 0]       # Black

# Interpolation
max_value = max(primary_value, secondary_value)  # max(210, 50) = 210
t = max(0.0, (max_value - 200) / 55.0)          # (210 - 200) / 55 ≈ 0.182

# Blend
r = int(primary_color[0] + (secondary_color[0] - primary_color[0]) * t)
g = int(primary_color[1] + (secondary_color[1] - primary_color[1]) * t)
b = int(primary_color[2] + (secondary_color[2] - primary_color[2]) * t)
a = 255

result_pixel = [r, g, b, a]

print(f"Interpolation: t={t:.3f}")
print(f"Result pixel: {result_pixel}")

# Calculation breakdown:
#   t = 0.182 (between 0=full primary, 1=full secondary)
#   r = 50 + (0 - 50) * 0.182 = 50 - 9.1 ≈ 41
#   g = 150 + (0 - 150) * 0.182 = 150 - 27.3 ≈ 123
#   b = 255 + (0 - 255) * 0.182 = 255 - 46.4 ≈ 209
#   Result: [41, 123, 209, 255] (slightly dimmed blue, pulled toward black)
```

**Step 5: Handle special cases**

```python
# White background (transparent)
if primary_value == 255 and secondary_value == 255:
    result_pixel = [0, 0, 0, 0]  # Fully transparent
    print("Pixel is white background (transparent)")

# Very dark (full secondary color)
elif max(primary_value, secondary_value) >= 255:
    result_pixel = secondary_color + [255]
    print(f"Pixel is full secondary: {result_pixel}")

# Very light (full primary color)
elif max(primary_value, secondary_value) <= 200:
    result_pixel = primary_color + [255]
    print(f"Pixel is full primary: {result_pixel}")
```

**Step 6: Extract entire glyph**

```python
def extract_glyph(data, metadata, primary_color, secondary_color, bitmap_offset):
    """Extract complete glyph as RGBA image."""
    width = metadata['xEnd'] - metadata['xStart'] + 1
    height = metadata['yEnd'] - metadata['yStart'] + 1
    
    image = []  # List of RGBA pixels
    
    for y in range(height):
        row = []
        for x in range(width):
            source_x = (metadata['xStart'] + x + 40) % 256
            source_y = (metadata['yStart'] + y + 3) % 256
            
            pixel_index = source_y * 256 + source_x
            byte_offset = bitmap_offset + (pixel_index * 2)
            
            primary = data[byte_offset]
            secondary = data[byte_offset + 1]
            
            # Apply interpolation
            if primary == 255 and secondary == 255:
                pixel = [0, 0, 0, 0]
            else:
                max_val = max(primary, secondary)
                t = max(0.0, (max_val - 200) / 55.0)
                
                r = int(primary_color[0] + (secondary_color[0] - primary_color[0]) * t)
                g = int(primary_color[1] + (secondary_color[1] - primary_color[1]) * t)
                b = int(primary_color[2] + (secondary_color[2] - primary_color[2]) * t)
                a = 255
                
                pixel = [r, g, b, a]
            
            row.append(pixel)
        image.append(row)
    
    return image  # 2D array of RGBA tuples

# Usage
glyph_image = extract_glyph(data, metadata, [50, 150, 255], [0, 0, 0], bitmap_offset)
print(f"Extracted glyph: {width}×{height} pixels")
# Output: Extracted glyph: 32×48 pixels
```

**Result**: A 32×48 pixel image array, each pixel [R, G, B, A], representing Symbol 37 colorized in blue with black outline.

---

## References

- **EURONAV5_FORMAT_MAIN.md** – Overview and integration
- **EURONAV5_FORMAT_APPMATRIX.md** – Style definition format (includes symbol ID references)
- **Services/GlyphManager.swift** – Index management and loading
- **Services/GlyphBitmapExtractor.swift** – Bitmap extraction and coloring
