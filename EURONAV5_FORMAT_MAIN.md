# Euronav5 Format – Complete Specification

**Status**: ✓ COMPLETE (May 24, 2026)  
**Scope**: AgustaWestland A109 PCMCIA vector database format  
**Target audience**: Developers implementing import/export and rendering

---

## Overview

The Euronav5 format is a vector database system used for helicopter mission planning. It consists of three primary components:

| Component | File | Purpose | Size |
|-----------|------|---------|------|
| **DMG Database** | `USER*.tbl` | Vector shapes (drawings, areas, circles) with properties | Variable (256-byte records) |
| **Style Database** | `appMatrix.json` | Rendering templates for objects (colors, lines, symbols, text) | ~1 MB system + per-layer |
| **Symbol Glyphs** | `*.sym` | Bitmap fonts for point-of-interest symbols | Varies (28 glyphs per file) |

---

## Architecture

### Data Flow

```
appMatrix.json (style definitions)
       ↓
   Assigns Style Class IDs (0x9a-0x9b)
       ↓
USER*.tbl (object data)
       ↓
   References Style Class IDs
   + Shape geometry (coordinates, type)
   + Properties (name, zone type, colors, line weight)
       ↓
   Rendering:
   - Look up Style Class ID in appMatrix
   - Get rendering template (symbol, line, polygon, text)
   - For symbols: load glyph from *.sym file
   - Apply colors, scaling, visibility

```

### Style Class ID Assignment

Objects store their rendering style via a 16-bit Style Class ID:

```
Byte 0x9a (low byte):  Subcategory / priority
Byte 0x9b (high byte): Primary category

styleClassID = byte_0x9a | (byte_0x9b << 8)
Example: 0x44 | (0x02 << 8) = 0x0244
```

The system contains 1,686 predefined style classes covering aviation, terrain, obstacles, navigational aids, etc.

---

## Component Specifications

### 1. DMG Database Format (`USER*.tbl`)

**See**: [EURONAV5_FORMAT_DMG.md](EURONAV5_FORMAT_DMG.md)

- **256-byte fixed records** with typed fields
- **Two object types**:
  - DRAWING: Lines and polylines (1-N points)
  - AREA: Closed regions (circles or polygons)
- **Fields**: Geometry, zone type, Style Class ID, name, coordinates, property metadata
- **Encoding**: Custom 6-bit character encoding for text

Key structures:
- Record header: Type markers (0x00, 0x10, 0x4e)
- Geometry reference: Multi-record figures (Figure = 1+ Records)
- Figure counter: Sequential numbering across entire file

### 2. Style Database Format (`appMatrix.json`)

**See**: [EURONAV5_FORMAT_APPMATRIX.md](EURONAV5_FORMAT_APPMATRIX.md)

- **JSON array** of style class definitions
- **1,686 system styles** + layer-specific extensions
- **Per-style**: Name, visibility flags, 2–4 rendering states
- **Per-state**: Point styling (symbol), line styling, polygon styling, text styling
- **Styling includes**:
  - Colors (stroke, fill, outline, text)
  - Line properties (weight, dash pattern)
  - Symbol properties (ID, scale, alignment)
  - Text properties (font, size, position, style)

### 3. Symbol Glyph Format (`*.sym`)

**See**: [EURONAV5_FORMAT_3SYM.md](EURONAV5_FORMAT_3SYM.md)

- **28 glyphs per file** (variable across files)
- **Metadata**: Glyph ID, bounding box (16-byte records, 0x0000–0x01BF)
- **Bitmap**: 256×256 pixels, 2 bytes per pixel (grayscale)
  - Byte 0 (even): Primary color (fill)
  - Byte 1 (odd): Secondary color (outline/stroke)
- **Extraction**: Bounding box defines region; pixel values interpolated into color range

---

## Common Workflows

### Loading a Vector Database

1. **Parse DMG (USER\*.tbl)**:
   - Read 256-byte records sequentially
   - Identify record type (0x00 = header, 0x10 = point/circle, 0x4e = area)
   - Group records by Figure counter (0xb0-0xb3) to reconstruct multi-record shapes
   - Extract coordinates, zone type, Style Class ID, name

2. **Load appMatrix.json**:
   - Parse JSON to extract 1,686 style definitions
   - Index by Style Class ID for O(1) lookup
   - Pre-load visibility flags and rendering states

3. **Load Symbol Files**:
   - Scan directory for all `*.sym` files
   - Index glyph metadata by Symbol ID
   - Record file path for later extraction

### Rendering an Object

1. **Get Style Class ID** from object record (bytes 0x9a-0x9b)
2. **Look up in appMatrix**:
   - Find style definition
   - Get appropriate rendering state (normal, selected, etc.)
3. **Render based on state**:
   - **Symbol**: Load glyph from indexed `*.sym` file, apply primary/secondary colors
   - **Line**: Stroke coordinates with color, weight, dash pattern
   - **Polygon**: Fill area with color, optionally add stroke
   - **Text**: Place label with font, size, position

---

## Design Patterns

### Record Organization in DMG

Records are sequentially numbered but logically grouped:

```
Figure 1 (Lines)
  Record 0: 0x00 (type=DRAWING, Pt=0)
  Record 1: 0x00 (Pt=1, start coords)
  Record 2: 0x00 (Pt=2, line point)
  Record 3: 0x00 (Pt=3, line point)
  Record 4: 0x01 (Pt=0, closing point)

Figure 2 (Area)
  Record 5: 0x4e (type=AREA, Pt=0)
  Record 6: 0x10 (Pt=1, zone metadata)
  Record 7: 0x10 (Pt=2, center/radius)

...
```

The Figure counter (0xb0-0xb3) continues incrementing across all records in the file.

### Style Inheritance and Overrides

- **System style**: Loaded from appMatrix (default rendering)
- **Object overrides**: Some bytes in object record override style
  - Bytes 0xec-0xed: Polygon fill/stroke colors
  - Bytes 0xad: Line color override
  - Bytes 0xdb: Geometry type (line vs polygon)
- **Rendering priority**: Object overrides > Style defaults

### Character Encoding (6-bit)

Text fields (name, zone type) use 6-bit character encoding:

```
Mapping:
  0: padding
  11: '-'
  14-23: '0'-'9'
  30-55: 'A'-'Z'

Packing: 5 characters per 4 bytes (30 bits used, 2 padding bits)
```

Names are typically 8-12 bytes of 6-bit encoded text.

---

## Files Reference

- **EURONAV5_FORMAT_DMG.md** – Detailed DMG database format specification (256-byte record layout)
- **EURONAV5_FORMAT_APPMATRIX.md** – JSON style definition format and rendering component specs
- **EURONAV5_FORMAT_SYM.md** – Symbol glyph bitmap format, metadata, and extraction

---

## Related Code

- **Services/Import/A109ImportService.swift** – DMG parsing and 6-bit decoding
- **Services/Export/DMGExportService.swift** – DMG record construction
- **Services/Style.swift** – Style object with rendering logic
- **Services/GlyphManager.swift** – Symbol indexing and loading
- **Services/GlyphBitmapExtractor.swift** – Glyph bitmap extraction and coloring

---

## Version History

| Date | Status | Notes |
|------|--------|-------|
| May 24, 2026 | ✓ FINAL | Consolidated documentation from DMG, appMatrix, and 3.sym |
| May 22, 2026 | ✓ COMPLETE | 3.sym format fully reverse-engineered |
| May 22, 2026 | ✓ COMPLETE | appMatrix format fully documented |
| May 14, 2026 | ✓ COMPLETE | DMG database format all unknowns resolved |
