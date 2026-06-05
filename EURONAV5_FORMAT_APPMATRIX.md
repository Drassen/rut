# Euronav5 appMatrix Format – Complete Specification

**Status**: ✓ COMPLETE (June 4, 2026)  
**Scope**: Style definition database for rendering objects  
**Format**: JSON array structure  
**System database**: **1,675 predefined style classes** (verified from production database)  
**Architecture**: 5 rendering layers (0-4) with layer-specific style ID ranges  
**Per-layer databases**: Optional extensions to system styles

---

## File Locations

```
System styles (primary database):
  /db/settings/system/appMatrix.json  (~1.0 MB, 1,675 total styles)

Operator-specific variants:
  /db/settings/system-setups/LUHS/appMatrix.json        (Swedish operator variant)
  /db/settings/system-setups/LUHS_EOS/appMatrix.json    (EOS variant)
  /db/settings/Factory/system-setups/Factory/appMatrix.json (fallback)

Layer-specific styles (optional):
  /db/vector/{LayerName}/appMatrix.json
  Examples:
    /db/vector/Flyginfo/appMatrix.json
    /db/vector/HinderNATO/appMatrix.json
    /db/vector/Kraftledningar/appMatrix.json
    /db/vector/Ovningar/appMatrix.json
    /db/vector/jeppesen/appMatrix.json
```

---

## 5-Layer Rendering Architecture

The appMatrix uses a **5-layer rendering system** with independent style ID ranges per layer:

| Layer | Styles | Valid ID Range | Purpose |
|-------|--------|----------------|---------|
| **Layer 0** | 336 | 0–335 | Overview/base features |
| **Layer 1** | 523 | 0–522 | Detailed rendering (LARGEST) |
| **Layer 2** | 272 | 0–271 | Specialized overlay 1 |
| **Layer 3** | 272 | 0–271 | Specialized overlay 2 |
| **Layer 4** | 272 | 0–271 | Specialized overlay 3 |

**Total**: 1,675 styles

**Important**: Style IDs are **layer-specific**. A style ID valid in Layer 1 may be invalid in Layer 2. When exporting or rendering, validate style IDs against the selected layer's bounds.

---

## Top-Level JSON Structure

```javascript
{
  "version": 1,
  "member": [
    // Array of 1,675 style class definitions
    // Organized by layer (Layer 0, 1, 2, 3, 4)
    // Style IDs are layer-specific and should be validated against layer bounds
  ]
}
```

---

## Style Class Definition – Member Array Entry

Each style class occupies **one index** in the `member` array:

```javascript
[
  [styleClassID_low, styleClassID_high],    // [0] Style Class ID (16-bit LE)
  [
    "STYLE_NAME",                           // [0] Human-readable name
    [visibility_flags],                     // [1] Visibility per state
    
    // RENDERING STATE 1 (default/normal)
    [STATE_1_COMPONENTS],                   // [2] Colors, lines, symbols, text
    
    // RENDERING STATE 2 (hover/selected)
    [STATE_2_COMPONENTS],                   // [3] ...
    
    // RENDERING STATE 3 (optional: active/editing)
    [STATE_3_COMPONENTS],                   // [4] ...
    
    // RENDERING STATE 4 (optional: secondary state)
    [STATE_4_COMPONENTS]                    // [5] ...
  ]
]
```

---

## Style Class ID (First Element)

```javascript
[styleClassID_low, styleClassID_high]
```

**Decoding**:
```
styleClassID = styleClassID_low | (styleClassID_high << 8)

Example:  [0x44, 0x02] → 0x44 | (0x02 << 8) = 0x0244
```

Used by DMG records (bytes 0x9a-0x9b) to reference rendering style.

---

## Visibility Flags (Second Element, Index 1)

Array of 4 booleans indicating which rendering states are active:

```javascript
[
  visibility_state_1,   // State 1 (default) visible?
  visibility_state_2,   // State 2 (hover) visible?
  visibility_state_3,   // State 3 (active) visible?
  visibility_state_4    // State 4 (secondary) visible?
]

Example: [0, 1, 1, 0] → State 1 hidden, States 2-3 visible, State 4 hidden
```

**Typical patterns**:
- `[1, 1, 1, 1]` – All states used (rare)
- `[1, 1, 0, 0]` – Two states (common)
- `[1, 0, 0, 0]` – Single state (simple styles)

---

## Rendering States

Each style defines **2–4 rendering states** for different UI contexts:

| State | Context | Use |
|-------|---------|-----|
| **State 1** | Default/normal | Object appears normally on map |
| **State 2** | Hover/selected | Object is mouse-over or selected |
| **State 3** | Active/editing | Object is being edited |
| **State 4** | Secondary | Reserved for future use |

Each state is an array of **4 rendering components**:

```javascript
[
  POINT_STYLING,       // [0] Symbol/glyph rendering
  LINE_STYLING,        // [1] Line/stroke rendering
  POLYGON_STYLING,     // [2] Polygon fill rendering
  LABEL_STYLING        // [3] Text rendering
]
```

A state may use alternative compressed formats (see below).

---

## Rendering Component Formats

### POINT Styling (Symbol/Glyph Rendering)

Used when object should render as a **point-of-interest (POI) with a glyph/symbol**.

```javascript
[
  [R, G, B, Alpha],              // [0] Primary color (RGBA, 0-255 each)
  [R, G, B, Alpha],              // [1] Secondary color (outline/effect)
  symbolId,                       // [2] Symbol ID: -1=hidden, 0=none, >0=glyph
  "alignmentMode",               // [3] "eRelativeToScreen" or "eRelativeToMap"
  scale                           // [4] Size multiplier (0-255, typically 50-150)
]
```

**Symbol ID Values**:
- `0`: No POI symbol (style is for lines/polygons only)
- `-1`: Hidden/disabled symbol (don't render)
- `-2`: Undefined/default (fallback behavior)
- `1–800+`: Actual glyph ID from symbol fonts
  - Range `1–27`: Symbols from 3.sym
  - Range `32768–32800+`: Extended symbol fonts

**Alignment Modes**:
- `"eRelativeToScreen"`: Symbol always faces viewer (billboard/orthographic)
- `"eRelativeToMap"`: Symbol rotates with map (projected)

**Example**:
```javascript
[
  [30, 150, 255, 255],           // Blue primary
  [0, 0, 0, 255],                // Black outline
  37,                            // Glyph ID 37 from 3.sym
  "eRelativeToScreen",
  100                            // 1.0x scale
]
```

### LINE Styling (Line/Polyline Rendering)

```javascript
[
  [R, G, B, Alpha],              // [0] Stroke color (RGBA)
  lineWeight,                     // [1] Weight: 0=none, 1-10=pixel width
  lineDashPattern,                // [2] Dash pattern: 0/65535=solid, other=bitmask
  [R, G, B, Alpha],              // [3] Outline color (secondary stroke)
  outlineWeight,                  // [4] Outline weight
  outlineDashPattern,             // [5] Outline dash pattern
  scale                           // [6] Size multiplier (typically 100)
]
```

**Line Weight**:
- `0`: No line (hidden)
- `1–10`: Pixel width (1=1px, 10=10px)

**Dash Pattern** (16-bit bitmask):
- `0` or `65535`: Solid line
- Other: Bits represent on/off pixel pairs (MSB to LSB)
  - Example: `0xAAAA` (binary 1010101010101010) = 1px on, 1px off, etc.

**Example**:
```javascript
[
  [200, 100, 50, 255],           // Orange stroke
  3,                             // 3 pixels wide
  65535,                         // Solid line
  [0, 0, 0, 255],                // Black outline
  1,                             // 1 pixel outline
  0,                             // No dash on outline
  100
]
```

### POLYGON Styling (Fill/Area Rendering)

```javascript
[
  [R, G, B, Alpha],              // [0] Fill color (RGBA)
  [R, G, B, Alpha],              // [1] Stroke color (outline)
  lineWeight,                     // [2] Stroke weight: 0=none, 1-10=px
  [R, G, B, Alpha],              // [3] Secondary outline color
  outlineWeight,                  // [4] Secondary stroke weight
  scale                           // [5] Size multiplier (typically 100)
]
```

**Example**:
```javascript
[
  [255, 200, 100, 128],          // Light orange fill (semi-transparent)
  [200, 100, 50, 255],           // Dark orange border
  2,                             // 2 pixel border
  [0, 0, 0, 255],                // Black secondary outline
  1,                             // 1 pixel secondary
  100
]
```

### LABEL Styling (Text Rendering)

```javascript
[
  [R, G, B, Alpha],              // [0] Text color (RGBA)
  fontSize,                       // [1] Font size (pixels, typically 10-20)
  textPosition,                   // [2] Position code ("eOnTrack", "eAboveTrack", etc.)
  textType,                       // [3] Background type ("eTextOnly", "eTextBox", etc.)
  [R, G, B, Alpha],              // [4] Background color
  fontStyle,                      // [5] Style bitmask (0=normal, 1=bold, etc.)
  scale                           // [6] Size multiplier (typically 100)
]
```

**Text Positions**:
- `"eOnTrack"`: Placed on the line/boundary
- `"eAboveTrack"`: Above/north of object
- `"eAboveLeft"`: Upper-left corner
- Custom codes for other alignments

**Text Types**:
- `"eTextOnly"`: No background
- `"eTextBox"`: Rectangular box background
- `"eTextPolygon"`: Polygon background
- `"eTextCircle"`: Circular background

**Font Styles**:
- `0`: Normal
- `1`: Bold
- `2`: Italic
- `3`: Bold + Italic

**Example**:
```javascript
[
  [0, 0, 0, 255],                // Black text
  12,                            // 12px font
  "eOnTrack",
  "eTextBox",
  [255, 255, 200, 200],          // Light yellow background
  1,                             // Bold
  100
]
```

### Alternative State Format (Compressed)

Some states use a simplified 3-element format:

```javascript
[
  0,                             // [0] Placeholder (unused)
  [LINE_STYLING],                // [1] Line configuration (see LINE Styling)
  scale                          // [2] Scale factor
]
```

This format is equivalent to:
```javascript
[
  [0, 0, 0, 0],                  // No point styling
  ...LINE_STYLING...,
  [0, 0, 0, 0],                  // No polygon styling
  [0, 0, 0, 0]                   // No label styling
]
```

---

## Complete Style Example

```javascript
[
  [0x2A, 0x01],                  // Style ID: 0x012A (298)
  [
    "POWER LINE (SINGLE)",       // Name
    [1, 1, 1, 0],                // States 1-3 visible
    
    // State 1: Default
    [
      [0, 0, 0, 0],              // No symbol
      [139, 69, 19, 255],        // Brown line
      2,                         // 2px weight
      65535,                     // Solid
      [0, 0, 0, 0],              // No outline
      0,
      [0, 0, 0, 0],              // No polygon
      [0, 0, 0, 0],              // No label
      [0, 0, 0, 0],
      0,
      100
    ],
    
    // State 2: Selected
    [
      [0, 0, 0, 0],
      [200, 100, 50, 255],       // Orange line
      3,                         // 3px weight
      65535,
      [255, 255, 255, 255],      // White outline
      1,
      [0, 0, 0, 0],
      [0, 0, 0, 0],
      [0, 0, 0, 0],
      0,
      100
    ],
    
    // State 3: Editing
    [
      [0, 0, 0, 0],
      [100, 200, 100, 255],      // Green line
      4,                         // 4px weight
      0xAAAA,                    // Dashed
      [0, 0, 0, 0],
      0,
      [0, 0, 0, 0],
      [0, 0, 0, 0],
      [0, 0, 0, 0],
      0,
      100
    ]
  ]
]
```

---

## Complete Working JSON Example

**File**: appMatrix.json  
**Purpose**: Define a simple navigation symbol style

```javascript
{
  "version": 1,
  "member": [
    // Style Index 0: Simple waypoint marker (Symbol ID 0x0100)
    [
      [0x00, 0x01],                           // Style Class ID: 0x0100
      [
        "WAYPOINT (STANDARD)",                // Name
        [1, 1, 0, 0],                         // Visibility: States 1-2 visible
        
        // STATE 1: Default
        [
          // POINT: Blue circle with black outline
          [100, 150, 255, 255],               // Primary (blue)
          [0, 0, 0, 255],                     // Secondary (black outline)
          1,                                  // Symbol ID: 1 (from 3.sym)
          "eRelativeToScreen",                // Always face viewer
          100,                                // Scale 1.0x
          
          // LINE: Not used for points
          [0, 0, 0, 0], 0, 0, [0, 0, 0, 0], 0, 0, 100,
          
          // POLYGON: Not used
          [0, 0, 0, 0], [0, 0, 0, 0], 0, [0, 0, 0, 0], 0, 100,
          
          // LABEL: Small text below
          [0, 0, 0, 255], 9, "eOnTrack", "eTextOnly", [0, 0, 0, 0], 0, 100
        ],
        
        // STATE 2: Selected/Hover
        [
          // POINT: Larger, yellow highlight
          [255, 255, 100, 255],               // Primary (yellow)
          [200, 200, 0, 255],                 // Secondary (darker yellow)
          1,                                  // Same symbol
          "eRelativeToScreen",
          150,                                // 1.5x scale (larger when selected)
          
          // LINE: Not used
          [0, 0, 0, 0], 0, 0, [0, 0, 0, 0], 0, 0, 100,
          
          // POLYGON: Not used
          [0, 0, 0, 0], [0, 0, 0, 0], 0, [0, 0, 0, 0], 0, 100,
          
          // LABEL: Same, but white text
          [255, 255, 255, 255], 10, "eOnTrack", "eTextBox", [0, 0, 0, 180], 1, 100
        ]
      ]
    ],
    
    // Style Index 1: Power line style (Style ID 0x0244)
    [
      [0x44, 0x02],                           // Style Class ID: 0x0244
      [
        "POWER LINE (HIGH VOLTAGE)",
        [1, 1, 1, 0],                         // States 1-3 visible
        
        // STATE 1: Default (brown line, solid)
        [
          // POINT: Not used
          [0, 0, 0, 0], [0, 0, 0, 0], 0, "", 0,
          
          // LINE: Brown stroke, solid
          [139, 69, 19, 255],                 // Brown
          3,                                  // 3 pixel width
          65535,                              // Solid (0xFFFF)
          [0, 0, 0, 0],                       // No outline
          0, 0,
          100,
          
          // POLYGON: Not used
          [0, 0, 0, 0], [0, 0, 0, 0], 0, [0, 0, 0, 0], 0, 100,
          
          // LABEL: "PWR" text
          [80, 40, 10, 255], 8, "eAboveTrack", "eTextOnly", [0, 0, 0, 0], 0, 100
        ],
        
        // STATE 2: Hover (orange, thicker)
        [
          [0, 0, 0, 0], [0, 0, 0, 0], 0, "", 0,
          
          [220, 100, 20, 255],                // Orange
          4,                                  // 4 pixels (thicker)
          65535,                              // Solid
          [255, 255, 255, 255],               // White outline
          1, 0,
          100,
          
          [0, 0, 0, 0], [0, 0, 0, 0], 0, [0, 0, 0, 0], 0, 100,
          [200, 100, 20, 255], 9, "eAboveTrack", "eTextBox", [255, 255, 200, 150], 1, 100
        ],
        
        // STATE 3: Editing (dashed outline)
        [
          [0, 0, 0, 0], [0, 0, 0, 0], 0, "", 0,
          
          [100, 200, 100, 255],               // Green
          2,                                  // 2 pixels
          0xAAAA,                             // Dashed (alternating on/off)
          [0, 0, 0, 255],                     // Black outline
          1, 0,
          100,
          
          [0, 0, 0, 0], [0, 0, 0, 0], 0, [0, 0, 0, 0], 0, 100,
          [0, 0, 0, 255], 8, "eOnTrack", "eTextOnly", [0, 0, 0, 0], 0, 100
        ]
      ]
    ],
    
    // Style Index 2: Restricted zone (polygon) (Style ID 0x0350)
    [
      [0x50, 0x03],                           // Style Class ID: 0x0350
      [
        "RESTRICTED AIRSPACE",
        [1, 1, 0, 0],
        
        // STATE 1: Default (light red fill, red border)
        [
          // POINT: Not used
          [0, 0, 0, 0], [0, 0, 0, 0], 0, "", 0,
          
          // LINE: Not used
          [0, 0, 0, 0], 0, 0, [0, 0, 0, 0], 0, 0, 100,
          
          // POLYGON: Light red fill, dark red border
          [255, 200, 200, 100],               // Light red fill (semi-transparent)
          [200, 0, 0, 255],                   // Dark red border
          2,                                  // 2 pixel border
          [0, 0, 0, 0],                       // No secondary outline
          0,
          100,
          
          // LABEL: "RESTRICTED" text in red
          [200, 0, 0, 255], 10, "eAboveTrack", "eTextBox", [255, 255, 200, 180], 1, 100
        ],
        
        // STATE 2: Selected (darker fill, thicker border)
        [
          [0, 0, 0, 0], [0, 0, 0, 0], 0, "", 0,
          [0, 0, 0, 0], 0, 0, [0, 0, 0, 0], 0, 0, 100,
          
          [255, 100, 100, 150],               // Darker red fill
          [150, 0, 0, 255],                   // Darker border
          3,                                  // Thicker border
          [255, 255, 255, 255],               // White secondary outline
          1,
          100,
          
          [150, 0, 0, 255], 11, "eAboveTrack", "eTextBox", [255, 255, 200, 200], 1, 100
        ]
      ]
    ]
  ]
}
```

**Key observations**:
- Each member entry is `[styleID, [name, visibility, state1, state2, state3, ...]]`
- Points use POINT component; lines use LINE; polygons use POLYGON
- Unused components are `[0,0,0,0]` or 0
- Visibility array controls which states render (e.g., `[1,1,0,0]` = states 1-2 only)
- Scale is typically 100 (1.0x multiplier); larger values = bigger rendering

---

## Rendering Hierarchy

When rendering an object:

1. **Look up Style Class ID** (from DMG record bytes 0x9a-0x9b)
2. **Find in appMatrix** using ID as index
3. **Determine visibility** (check visibility flags for desired state)
4. **Get components** (point, line, polygon, label from that state)
5. **Apply overrides** (DMG record may override colors via 0xad, 0xec-0xed)
6. **Render**:
   - Symbol: Load glyph from *.sym files, colorize with primary/secondary
   - Line: Stroke with color, weight, dash pattern
   - Polygon: Fill with color, add stroke if weight > 0
   - Label: Place text with font, size, position

---

## Color Values (RGBA Quadruplet)

All colors are **4-element arrays** `[R, G, B, Alpha]`:

```javascript
[255, 0, 0, 255]       // Fully opaque red
[100, 100, 255, 128]   // Semi-transparent light blue
[0, 0, 0, 0]           // Fully transparent black
```

**Range**: 0–255 per channel

---

## Layer-Specific Styles

Layer-specific appMatrix files may extend or override system styles:

```
/db/vector/Kraftledningar/appMatrix.json  (Power lines)
  → Contains style definitions for power line rendering
  → Overrides system styles with layer-specific appearance

/db/vector/HinderNATO/appMatrix.json      (NATO obstacles)
  → Contains style definitions for military obstacles
  → Unique symbol IDs or rendering properties
```

**Loading priority**:
1. Load system appMatrix (/db/settings/system/appMatrix.json)
2. Load layer-specific appMatrix (if exists)
3. Layer-specific styles override system styles with same ID

---

## Category Encoding (Style Naming Conventions)

While style names are free-form, they follow patterns indicating category:

**Examples**:
```
"NAVIGATIONAL AID (VOR)"           → Navigation category
"RUNWAY (ACTIVE)"                  → Aerodrome category
"OBSTACLE (BUILDING)"              → Ground hazard category
"POWER LINE (SINGLE)"              → Utility/infrastructure
"TRAINING AREA"                    → Military/training zones
"RESTRICTED AIRSPACE"              → Airspace restrictions
```

No formal encoding; names are human-readable strings.

---

## Parsing Algorithm

```pseudo
function loadAppMatrix(filePath):
    json = parseJSON(filePath)
    version = json["version"]
    
    styles = {}
    for each entry in json["member"]:
        [styleID_low, styleID_high] = entry[0]
        styleID = styleID_low | (styleID_high << 8)
        
        styleData = entry[1]
        name = styleData[0]
        visFlags = styleData[1]
        states = styleData[2:]  // Elements [2] onward
        
        styles[styleID] = {
            name: name,
            visibility: visFlags,
            states: states
        }
    
    return styles

function renderObject(dmgRecord, styles, glyphManager):
    styleID = dmgRecord[0x9a] | (dmgRecord[0x9b] << 8)
    style = styles[styleID]
    
    state = style.states[desiredState]  // E.g., state 0 (default)
    
    if state.symbol && state.symbol[2] > 0:  // symbolId
        glyph = glyphManager.getGlyph(state.symbol[2])
        colorize(glyph, state.symbol[0], state.symbol[1])  // Primary, secondary
        render(glyph, objectCoordinates)
    
    if state.line && state.line[1] > 0:     // lineWeight
        strokeStyle = createStroke(state.line[0], state.line[1], state.line[2])
        render(lineGeometry, strokeStyle)
    
    if state.polygon && state.polygon[0] != [0,0,0,0]:  // fillColor
        fillStyle = createFill(state.polygon[0])
        render(polygonGeometry, fillStyle)
    
    if state.label && state.label[0] != [0,0,0,0]:     // textColor
        labelStyle = createLabel(state.label)
        render(labelGeometry, labelStyle)
```

---

## Data Validation

**Style Class ID**:
- Must be 16-bit unsigned (0–65535)
- Common ranges: 0x0000–0x0699 (system), varies for custom

**Visibility Flags**:
- Array of exactly 4 booleans (or 0/1 integers)

**Symbol ID**:
- Range: -2 to 65535+
- Values 1–27: Standard glyphs from 3.sym
- Values 32768–32774: Extended symbols

**Colors**:
- Each channel: 0–255
- Alpha: 0 (transparent) to 255 (opaque)

**Font Size**:
- Range: 1–100 pixels (typical 10–20)

**Line Weight**:
- Range: 0–10 pixels (0 = hidden)

---

## Appendix: Standard Category Ranges

**Indicative Style ID Ranges** (not absolute; system contains 1,686 entries):

| Category | ID Range | Notes |
|----------|----------|-------|
| Navigation | 0x0100–0x0199 | VOR, NDB, waypoints |
| Aerodrome | 0x0200–0x0299 | Runways, taxiways |
| Airspace | 0x0300–0x0399 | CTR, restricted zones |
| Obstacles | 0x0400–0x0499 | Buildings, terrain, towers |
| Infrastructure | 0x0500–0x0599 | Power lines, roads |
| Training | 0x0600–0x0699 | Exercise areas, ranges |
| Military | 0x0700–0x0799 | NATO symbols, tactical |

Ranges are approximate; consult actual appMatrix for definitive mapping.
