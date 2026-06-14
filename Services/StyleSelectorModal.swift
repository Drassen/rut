import SwiftUI

struct StyleSelectorModal: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedStyleId: Euronav5StyleClass
    var geometry: VectorGeometry? = nil  // Optional: filter by geometry type
    var onStyleChange: ((Style) -> Void)? = nil  // Callback when style is selected
    @State private var selectedCategoryIndex = 0
    @State private var categories: [StyleCategory] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var previewStyle: Style? = nil

    private var initialPreviewStyle: Style? {
        if case .custom(let id) = selectedStyleId {
            return categories
                .flatMap { $0.styles }
                .first { $0.styleId == id }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category dropdown at top — only for points; lines/polygons/
                // circles use one flat list (categories are noise there).
                if !usesFlatList {
                    HStack {
                        Text("Category:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Category", selection: $selectedCategoryIndex) {
                            ForEach(0..<categories.count, id: \.self) { idx in
                                Text(categories[idx].name).tag(idx)
                            }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                }

                // Main content area
                if isLoading {
                    VStack {
                        ProgressView()
                            .padding()
                        Text("Loading styles...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else if let error = loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            loadStyles()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxHeight: .infinity)
                } else if categories.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text("No styles loaded")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        // Left: Style list
                        VStack(spacing: 0) {
                            let filtered = filterStyles()
                            if filtered.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text("No styles found")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxHeight: .infinity)
                            } else {
                                List(filtered, id: \.id) { style in
                                    StyleRow(
                                        style: style,
                                        isSelected: (previewStyle ?? initialPreviewStyle)?.styleId == style.styleId,
                                        geometry: geometry
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        previewStyle = style
                                        onStyleChange?(style)
                                    }
                                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                                }
                                .listStyle(.plain)
                            }
                        }
                        .frame(maxWidth: 280)

                        Divider()

                        // Right: Preview
                        if let style = previewStyle ?? initialPreviewStyle {
                            VStack(alignment: .leading, spacing: 12) {
                                if style.symbolId > 0 {
                                    Text("Symbol")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    GlyphDisplayView(
                                        symbolId: UInt16(style.symbolId),
                                        primaryColor: style.primaryColor,
                                        secondaryColor: style.secondaryColor
                                    )
                                    .frame(height: 100)
                                } else if case .circle = geometry, let lineColor = style.lineColor {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Circle")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(String(format: "%.1f", style.lineWeight))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Canvas { context, size in
                                            let minDim = min(size.width, size.height)
                                            let rect = CGRect(x: (size.width - minDim) / 2, y: (size.height - minDim) / 2, width: minDim, height: minDim)
                                            let circlePath = Path(ellipseIn: rect)
                                            let circleTicks = tickedLinePath(points: ellipsePerimeterPoints(in: rect), closed: true)
                                            let strokeWidth = CGFloat(max(1, style.lineWeight))
                                            let isLineTick = isTickDashPattern(style.lineDashPattern)
                                            context.stroke(isLineTick ? circleTicks : circlePath, with: .color(lineColor),
                                                           style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round,
                                                                              dash: isLineTick ? [] : euronavDashArray(style.lineDashPattern)))

                                            if let outlineColor = style.outlineColor, style.outlineWeight > 0 {
                                                let outlineStrokeWidth = CGFloat(style.outlineWeight)
                                                let isOutlineTick = isTickDashPattern(style.outlineDashPattern)
                                                context.stroke(isOutlineTick ? circleTicks : circlePath, with: .color(outlineColor),
                                                               style: StrokeStyle(lineWidth: outlineStrokeWidth, lineCap: .round, lineJoin: .round,
                                                                                  dash: isOutlineTick ? [] : euronavDashArray(style.outlineDashPattern)))
                                            }
                                        }
                                        .frame(height: 60)
                                        .aspectRatio(1, contentMode: .fit)
                                    }
                                } else if let lineColor = style.lineColor {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Line")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text("\(style.lineWeight)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        LinePreviewView(
                                            color: lineColor,
                                            dashPattern: style.lineDashPattern,
                                            weight: style.lineWeight,
                                            outlineColor: style.outlineColor,
                                            outlineWeight: style.outlineWeight,
                                            isZigzag: isTickDashPattern(style.outlineDashPattern) || isTickDashPattern(style.lineDashPattern)
                                        )
                                        .frame(height: 60)
                                    }
                                } else if let fillColor = style.polygonFillColor, !isPolyline(geometry) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Polygon")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text("\(style.lineWeight)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        PolygonPreviewView(
                                            fillColor: fillColor,
                                            lineColor: style.lineColor,
                                            dashPattern: style.lineDashPattern,
                                            weight: style.lineWeight,
                                            outlineColor: style.outlineColor,
                                            outlineDashPattern: style.outlineDashPattern,
                                            outlineWeight: style.outlineWeight
                                        )
                                        .frame(height: 60)
                                    }
                                }

                                if let textColor = style.textColor {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Label")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        HStack {
                                            Text("Sample Text")
                                                .font(.system(size: CGFloat(style.fontSize), weight: style.textBold ? .bold : .regular))
                                                .foregroundStyle(textColor)
                                                .padding(4)
                                                .background(style.textBackgroundColor ?? Color.clear)
                                                .cornerRadius(2)
                                            Spacer()
                                        }
                                        .padding(8)
                                        .background(Color(.systemGray6))
                                        .cornerRadius(4)
                                    }
                                }

                                Spacer()
                            }
                            .padding(12)
                            .frame(maxWidth: 160)
                        } else {
                            VStack {
                                Image(systemName: "paintbrush.fill")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text("Select a style")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .navigationTitle("Select Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if previewStyle ?? initialPreviewStyle != nil {
                        Button("Select") {
                            if let style = previewStyle ?? initialPreviewStyle {
                                if let knownStyle = KnownStyleClass(rawValue: style.styleId) {
                                    selectedStyleId = .known(knownStyle)
                                } else {
                                    selectedStyleId = .custom(style.styleId)
                                }
                            }
                            dismiss()
                        }
                        .bold()
                    }
                }
            }
        }
        .onAppear {
            loadStyles()
        }
    }

    // MARK: - Private Methods

    private func isPolyline(_ geometry: VectorGeometry?) -> Bool {
        if case .polyline = geometry {
            return true
        }
        return false
    }
    private func loadStyles() {
        isLoading = true
        loadError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            if let loaded = loadAppMatrixCategories() {
                DispatchQueue.main.async {
                    self.categories = loaded
                    // Default to Aviation category if it exists, otherwise first category
                    if let aviationIndex = loaded.firstIndex(where: { $0.name.contains("Aviation") }) {
                        self.selectedCategoryIndex = aviationIndex
                    } else {
                        self.selectedCategoryIndex = 0
                    }
                    self.isLoading = false

                    // Set initial preview
                    if self.previewStyle == nil {
                        if case .custom(let id) = self.selectedStyleId {
                            self.previewStyle = loaded.flatMap { $0.styles }.first { $0.styleId == id }
                            print("📌 Preview set to selected style: \(id), found: \(self.previewStyle != nil)")
                        }
                        if self.previewStyle == nil {
                            self.previewStyle = loaded.first?.styles.first
                            if let preview = self.previewStyle {
                                print("📌 Preview set to first style: \(preview.name)")
                            } else {
                                print("❌ Preview could not be set - no styles loaded")
                            }
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load appMatrix.json"
                    self.isLoading = false
                }
            }
        }
    }

    private func loadAppMatrixCategories() -> [StyleCategory]? {
        guard let url = Bundle.main.url(
            forResource: "appMatrix",
            withExtension: "json",
            subdirectory: "euronav5"
        ) else {
            print("❌ appMatrix.json not found in bundle")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let members = json["member"] as? [[Any]] else {
                print("❌ Invalid JSON structure")
                return nil
            }

            var categories: [String: [Style]] = [:]

            // appMatrix lists each style once per appearance scheme
            // (ids[0] = scheme 0–4: DAG/NATT/DIM…). Compute which schemes
            // each style id is defined in.
            var schemeCoverage: [UInt16: Set<Int>] = [:]
            for member in members {
                if let ids = member[0] as? [Int], ids.count >= 2 {
                    schemeCoverage[UInt16(ids[1]), default: []].insert(ids[0])
                }
            }
            let allSchemes: Set<Int> = [0, 1, 2, 3, 4]
            // The helicopter renders the iOS USER database in appearance
            // scheme 2/3/4 (NOT scheme 0 — scheme-0-only styles don't show).
            // Read each style's colours from that active scheme so the
            // preview AND the colored-line/fill filter match what the
            // helicopter actually draws (e.g. 247 LINE WRN 2 is blue there,
            // not the red it shows in scheme 0). Point symbols are
            // scheme-independent, so styles with no active-scheme entry
            // (e.g. scheme-1-only) fall back to their lowest scheme.
            let activeScheme = 2
            var repScheme: [UInt16: Int] = [:]
            for (sid, schemes) in schemeCoverage {
                repScheme[sid] = schemes.contains(activeScheme) ? activeScheme : (schemes.min() ?? 0)
            }

            for member in members {
                guard member.count >= 2,
                      let ids = member[0] as? [Int],
                      ids.count >= 2,
                      let info = member[1] as? [Any],
                      info.count >= 1,
                      let name = info[0] as? String else {
                    continue
                }

                let styleId = UInt16(ids[1])

                // Take exactly one entry per style id.
                guard ids[0] == repScheme[styleId] else { continue }
                // Scheme coverage drives the geometry filter: line/fill COLOR
                // is scheme-dependent (only all-5 styles render colored as a
                // line/area), but a point's symbol renders regardless of
                // scheme (on-hardware: all 183 glyphs appeared). See
                // filterStyles().
                let isAllSchemes = schemeCoverage[styleId] == allSchemes
                let categoryName = categorizeStyle(styleId: styleId)

                // Extract all style parameters from first rendering state
                var symbolId: Int = 0
                var primaryColor: Color? = nil
                var secondaryColor: Color? = nil
                var lineColor: Color? = nil
                var lineDashPattern: UInt16 = 65535
                var lineWeight: Int = 1
                var outlineColor: Color? = nil
                var outlineDashPattern: UInt16 = 65535
                var outlineWeight: Int = 0
                var polygonFillColor: Color? = nil
                var textColor: Color? = nil
                var textBackgroundColor: Color? = nil
                var textPosition: String = "ePosTop"
                var textType: String = "eTextOnly"
                var fontSize: Int = 11
                var textBold: Bool = false
                var lineRGBA: [Int]? = nil
                var fillRGBA: [Int]? = nil

                if info.count >= 3, let renderingData = info[2] as? [[Any]], renderingData.count >= 2 {

                    // Extract colors and symbol from renderingData[0]
                    let colors = renderingData[0]
                    if colors.count >= 2 {
                        if let primaryColorArray = colors[0] as? [Int], primaryColorArray.count >= 3 {
                            primaryColor = arrayToColor(primaryColorArray)
                        }
                        if let secondaryColorArray = colors[1] as? [Int], secondaryColorArray.count >= 3 {
                            secondaryColor = arrayToColor(secondaryColorArray)
                        }
                    }

                    // Extract symbol ID from renderingData[0][2] (POI glyph)
                    if colors.count > 2, let symbol = colors[2] as? Int {
                        symbolId = symbol
                    }

                    // Extract line styling from renderingData[1]
                    if let lineStyles = renderingData[1] as? [[Any]], lineStyles.count >= 2 {
                        // Primary line
                        let primaryLine = lineStyles[0]
                        if let lc = primaryLine[0] as? [Int] { lineColor = arrayToColor(lc); lineRGBA = lc }
                        if let dash = primaryLine[1] as? [Int], dash.count >= 2 {
                            let dashVal = dash[1]
                            lineDashPattern = UInt16(dashVal & 0xFFFF)
                        }
                        if let weight = primaryLine[2] as? Int { lineWeight = weight }
                        // Outline line
                        let outlineLine = lineStyles[1]
                        if let oc = outlineLine[0] as? [Int] { outlineColor = arrayToColor(oc) }
                        if let dash = outlineLine[1] as? [Int], dash.count >= 2 {
                            let dashVal = dash[1]
                            outlineDashPattern = UInt16(dashVal & 0xFFFF)
                        }
                        if let weight = outlineLine[2] as? Int { outlineWeight = weight }
                    }

                    // Extract polygon fill from renderingData[2]
                    if renderingData.count > 2, let fillArray = renderingData[2] as? [[Int]], !fillArray.isEmpty, fillArray[0].count >= 3 {
                        polygonFillColor = arrayToColor(fillArray[0])
                        fillRGBA = fillArray[0]
                    }

                    // Extract text styling from renderingData[3]
                    let textStyle = renderingData[3]
                    if textStyle.count >= 7 {
                        if let pos = textStyle[0] as? String { textPosition = pos }
                        if let type = textStyle[1] as? String { textType = type }
                        if let tc = textStyle[2] as? [Int] { textColor = arrayToColor(tc) }
                        if let bg = textStyle[3] as? [Int] { textBackgroundColor = arrayToColor(bg) }
                        if let size = textStyle[5] as? Int { fontSize = size }
                        if let bold = textStyle[6] as? Bool { textBold = bold }
                    }
                }

                // Visibility of line/fill (for the geometry filter): a
                // channel is "colored" when it is opaque-ish and not white.
                // White-on-white symbol styles and transparent fills are
                // treated as not contributing a visible line/area.
                func colored(_ c: [Int]?) -> Bool {
                    guard let c = c, c.count >= 3 else { return false }
                    let alpha = c.count >= 4 ? c[3] : 255
                    guard alpha > 0 else { return false }
                    return !(c[0] >= 249 && c[1] >= 249 && c[2] >= 249)
                }
                let hasColoredLine = colored(lineRGBA)
                let hasVisibleFill = colored(fillRGBA)

                let styleItem = StyleItem(
                    id: UUID(),
                    styleId: styleId,
                    name: name,
                    hexId: String(format: "0x%04X", styleId),
                    highByte: UInt8((styleId >> 8) & 0xFF),
                    symbolId: symbolId,
                    primaryColor: primaryColor,
                    secondaryColor: secondaryColor,
                    lineColor: lineColor,
                    lineDashPattern: lineDashPattern,
                    lineWeight: lineWeight,
                    outlineColor: outlineColor,
                    outlineDashPattern: outlineDashPattern,
                    outlineWeight: outlineWeight,
                    polygonFillColor: polygonFillColor,
                    textColor: textColor,
                    textBackgroundColor: textBackgroundColor,
                    textPosition: textPosition,
                    textType: textType,
                    fontSize: fontSize,
                    textBold: textBold,
                    hasColoredLine: hasColoredLine,
                    hasVisibleFill: hasVisibleFill,
                    isAllSchemes: isAllSchemes
                )
                let style = Style(from: styleItem)

                if categories[categoryName] == nil {
                    categories[categoryName] = []
                }
                categories[categoryName]?.append(style)
            }

            let result = categories
                .map { StyleCategory(name: $0.key, styles: $0.value) }
                .sorted { $0.name < $1.name }

            print("✓ Loaded \(result.count) categories with \(members.count) styles")
            return result

        } catch {
            print("❌ Failed to parse appMatrix.json: \(error)")
            return nil
        }
    }

    /// Curated style ids for polygons and circles — the subset the user
    /// kept after reviewing the full polygon catalog rendered on the
    /// helicopter (32 of 131). Edit this list to re-curate.
    private static let curatedAreaStyleIds: Set<UInt16> = [
        37, 38, 39, 40, 41, 42,                          // AREA WRN1–6
        47, 48, 49, 50, 51, 52,                          // AREA 7–12
        617, 618,                                        // CTR CTZ, MCTR
        635, 637,                                        // RESTR UNSPEC, RUNWAY TAXIWAY
        798, 799,                                        // KOSIF RESTR RESTRICTED/VHT
        961, 962, 964, 965, 967,                         // CONTEXT MENU/HIGHLIGHTED/INTERVIS/MAP BG
    ]

    /// Lines/polygons/circles show one flat, un-categorised list (sorted by
    /// style id); points keep the category dropdown.
    private var usesFlatList: Bool {
        switch geometry {
        case .polyline, .polygon, .circle: return true
        default: return false
        }
    }

    private func filterStyles() -> [Style] {
        var categoryStyles: [Style]
        if usesFlatList {
            categoryStyles = categories.flatMap { $0.styles }
                .sorted { $0.styleId < $1.styleId }
        } else {
            guard selectedCategoryIndex < categories.count else { return [] }
            categoryStyles = categories[selectedCategoryIndex].styles
        }

        // Filter by geometry type so the picker only offers styles that
        // actually render for that geometry on the helicopter (see the
        // test-card findings: symbol styles are white as areas/lines but
        // show an icon as points; white-on-white styles render as nothing).
        if let geo = geometry {
            switch geo {
            case .point:
                // Points render their glyph regardless of appearance scheme
                // (on-hardware: all glyphs appeared), so any symbol style works.
                categoryStyles = categoryStyles.filter { $0.symbolId > 0 }
            case .polyline:
                // Lines → a visible colored stroke, no glyph (a symbol style
                // draws an icon at every vertex). Scheme filter intentionally
                // dropped for now so scheme-limited line styles (e.g.
                // KRAFTLEDNING) are offered too — pending hardware check of
                // whether they render.
                categoryStyles = categoryStyles.filter {
                    $0.symbolId <= 0 && $0.hasColoredLine
                }
            case .polygon, .circle:
                // Curated area palette — the subset kept after reviewing the
                // full polygon catalog on the helicopter (see
                // Self.curatedAreaStyleIds).
                categoryStyles = categoryStyles.filter {
                    Self.curatedAreaStyleIds.contains($0.styleId)
                }
            }
        }

        return categoryStyles
    }

    private func arrayToColor(_ array: [Int]) -> Color? {
        guard array.count >= 3 else { return nil }
        let r = CGFloat(array[0]) / 255.0
        let g = CGFloat(array[1]) / 255.0
        let b = CGFloat(array[2]) / 255.0
        let a = array.count >= 4 ? CGFloat(array[3]) / 255.0 : 1.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    /// Categorize style by semantic meaning for UI organization.
    /// Rendering layers (0-4) in appMatrix represent visualization modes, not export constraints.
    private func categorizeStyle(styleId: UInt16) -> String {
        switch styleId {
        case 0...99:
            return "🌍 Terrain (0-99)"
        case 100...199:
            return "🛣️ Infrastructure (100-199)"
        case 200...299:
            return "🏗️ Urban (200-299)"
        case 300...399:
            return "📍 Navigation (300-399)"
        case 400...499:
            return "⚠️ Hazards (400-499)"
        case 500...599:
            return "✈️ Aviation (500-599)"
        case 600...699:
            return "🌊 Water (600-699)"
        case 700...799:
            return "🛤️ Transportation (700-799)"
        case 800...899:
            return "🏛️ Cultural (800-899)"
        case 900...999:
            return "🔧 Industrial (900-999)"
        case 1000...1099:
            return "📡 Communications (1000-1099)"
        case 1100...1199:
            return "🌳 Vegetation (1100-1199)"
        case 1200...1299:
            return "⚡ Utilities (1200-1299)"
        case 1300...1399:
            return "🏥 Services (1300-1399)"
        case 1400...1499:
            return "🎯 Military (1400-1499)"
        case 1500...1599:
            return "📊 Special (1500-1599)"
        case 1600...1699:
            return "🔹 Miscellaneous (1600-1699)"
        default:
            return "📍 Other"
        }
    }
}

// MARK: - Data Models

struct StyleCategory {
    let name: String
    var styles: [Style]
}

struct StyleItem: Identifiable {
    let id: UUID
    let styleId: UInt16
    let name: String
    let hexId: String
    let highByte: UInt8

    // Primary rendering state (first state)
    let symbolId: Int            // POI symbol/glyph ID (0 = no symbol)
    let primaryColor: Color?
    let secondaryColor: Color?
    let lineColor: Color?
    let lineDashPattern: UInt16  // 16-bit bitmask
    let lineWeight: Int          // 0-9
    let outlineColor: Color?
    let outlineDashPattern: UInt16
    let outlineWeight: Int
    let polygonFillColor: Color?
    let textColor: Color?
    let textBackgroundColor: Color?
    let textPosition: String     // ePosTop, ePosBelow, eOnTrack
    let textType: String        // eTextOnly, eTextRectangle, eTextPolygon
    let fontSize: Int
    let textBold: Bool
    // Geometry suitability (computed from raw appMatrix colors): whether the
    // style draws a visible (non-white, opaque) line / polygon fill.
    var hasColoredLine: Bool = false
    var hasVisibleFill: Bool = false
    // True if the style is defined in all five appearance schemes. Required
    // for line/area COLOR to render; point symbols render regardless.
    var isAllSchemes: Bool = false
}

// MARK: - Style Row View

struct StyleRow: View {
    let style: Style
    let isSelected: Bool
    var geometry: VectorGeometry? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Use canonical preview view from Style object
            style.previewView(geometry: geometry)

            VStack(alignment: .leading, spacing: 2) {
                Text(style.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(style.hexId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("(\(style.styleId))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}

// MARK: - Line Preview Component

struct LinePreviewView: View {
    let color: Color
    let dashPattern: UInt16
    let weight: Int
    let outlineColor: Color?
    let outlineWeight: Int
    /// True for the perpendicular-tick (power-line) decoration.
    var isZigzag: Bool = false

    var body: some View {
        Canvas { context, size in
            let strokeWidth = CGFloat(max(1, weight))
            let centerY = size.height / 2
            let ends = [CGPoint(x: 0, y: centerY), CGPoint(x: size.width, y: centerY)]

            if isZigzag {
                // Power-line symbol: solid line with perpendicular ticks.
                let ticks = tickedLinePath(points: ends, closed: false)
                if let outlineColor = outlineColor, outlineWeight > 0 {
                    context.stroke(ticks, with: .color(outlineColor),
                                   style: StrokeStyle(lineWidth: CGFloat(outlineWeight), lineCap: .round))
                }
                context.stroke(ticks, with: .color(color),
                               style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            } else {
                var path = Path()
                path.move(to: ends[0]); path.addLine(to: ends[1])
                if let outlineColor = outlineColor, outlineWeight > 0 {
                    context.stroke(path, with: .color(outlineColor),
                                   style: StrokeStyle(lineWidth: CGFloat(outlineWeight)))
                }
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt,
                                                  dash: euronavDashArray(dashPattern)))
            }
        }
    }
}

// MARK: - Polygon Preview Component

struct PolygonPreviewView: View {
    let fillColor: Color
    let lineColor: Color?
    let dashPattern: UInt16
    let weight: Int
    let outlineColor: Color?
    let outlineDashPattern: UInt16
    let outlineWeight: Int

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            let ticks = tickedLinePath(points: rectPerimeterPoints(rect), closed: true)

            context.fill(path, with: .color(fillColor))

            if let lineColor = lineColor, weight > 0 {
                let isTick = isTickDashPattern(dashPattern)
                context.stroke(isTick ? ticks : path, with: .color(lineColor),
                               style: StrokeStyle(lineWidth: CGFloat(max(1, weight)), lineCap: .round, lineJoin: .round,
                                                  dash: isTick ? [] : euronavDashArray(dashPattern)))
            }

            if let outlineColor = outlineColor, outlineWeight > 0 {
                let isTick = isTickDashPattern(outlineDashPattern)
                context.stroke(isTick ? ticks : path, with: .color(outlineColor),
                               style: StrokeStyle(lineWidth: CGFloat(outlineWeight), lineCap: .round, lineJoin: .round,
                                                  dash: isTick ? [] : euronavDashArray(outlineDashPattern)))
            }
        }
    }
}

#Preview {
    StyleSelectorModal(selectedStyleId: .constant(.custom(0x0202)))
}
