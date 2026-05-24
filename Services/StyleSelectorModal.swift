import SwiftUI

struct StyleSelectorModal: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedStyleId: DMGStyleClass
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
                // Category dropdown at top
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
                                            let strokeWidth = CGFloat(max(1, style.lineWeight))
                                            let isLineZigzag = style.lineDashPattern == 49344
                                            let linePathToStroke = isLineZigzag ? self.createZigzagCirclePath(size: size) : circlePath
                                            let dashStyle = StrokeStyle(
                                                lineWidth: strokeWidth,
                                                lineCap: .round,
                                                lineJoin: .round,
                                                dash: isLineZigzag ? [] : self.dashPatternToDashArray(style.lineDashPattern)
                                            )
                                            context.stroke(linePathToStroke, with: .color(lineColor), style: dashStyle)

                                            if let outlineColor = style.outlineColor, style.outlineWeight > 0 {
                                                let outlineStrokeWidth = CGFloat(style.outlineWeight)
                                                let isOutlineZigzag = style.outlineDashPattern == 49344
                                                let outlinePathToStroke = isOutlineZigzag ? self.createZigzagCirclePath(size: size) : circlePath
                                                let outlineDashStyle = StrokeStyle(
                                                    lineWidth: outlineStrokeWidth,
                                                    lineCap: .round,
                                                    lineJoin: .round,
                                                    dash: isOutlineZigzag ? [] : self.dashPatternToDashArray(style.outlineDashPattern)
                                                )
                                                context.stroke(outlinePathToStroke, with: .color(outlineColor), style: outlineDashStyle)
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
                                            isZigzag: style.outlineDashPattern == 49344 || style.lineDashPattern == 49344
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

    private func createZigzagCirclePath(size: CGSize, amplitude: CGFloat = 5) -> Path {
        let centerX = size.width / 2
        let centerY = size.height / 2
        let baseRadius = min(size.width, size.height) / 2 - 2
        let stepAngle = CGFloat.pi / 3  // 60 degrees

        var points: [CGPoint] = []
        var isOutset = false

        var angle: CGFloat = 0
        while angle < 2 * CGFloat.pi {
            let radius = isOutset ? (baseRadius + amplitude) : (baseRadius - amplitude)
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            points.append(CGPoint(x: x, y: y))

            angle += stepAngle
            isOutset.toggle()
        }

        var zigzagPath = Path()
        if !points.isEmpty {
            zigzagPath.move(to: points[0])
            for point in points.dropFirst() {
                zigzagPath.addLine(to: point)
            }
            zigzagPath.closeSubpath()
        }

        return zigzagPath
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
                        if let lc = primaryLine[0] as? [Int] { lineColor = arrayToColor(lc) }
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
                    textBold: textBold
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

    private func filterStyles() -> [Style] {
        guard selectedCategoryIndex < categories.count else { return [] }

        var categoryStyles = categories[selectedCategoryIndex].styles

        // Filter by geometry type if provided
        if let geo = geometry {
            switch geo {
            case .point:
                // For points: only show styles with glyphs
                categoryStyles = categoryStyles.filter { $0.symbolId > 0 }
            case .polyline, .polygon, .circle:
                // For lines/polygons/circles: only show styles without glyphs
                categoryStyles = categoryStyles.filter { $0.symbolId <= 0 }
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

    private func dashPatternToDashArray(_ pattern: UInt16) -> [CGFloat] {
        if pattern == 0xFFFF {
            return []
        }
        var dashes: [CGFloat] = []
        var currentDash: CGFloat = 0
        var isDash = (pattern & 0x8000) != 0

        for i in (0..<16).reversed() {
            let bit = (pattern >> i) & 1
            let isBitSet = bit != 0

            if isBitSet == isDash {
                currentDash += 1
            } else {
                if currentDash > 0 {
                    dashes.append(currentDash)
                }
                isDash = isBitSet
                currentDash = 1
            }
        }
        if currentDash > 0 {
            dashes.append(currentDash)
        }

        return dashes.isEmpty ? [] : dashes
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

    private func dashPatternToDashArray(_ pattern: UInt16) -> [CGFloat] {
        if pattern == 0xFFFF {
            return []
        }
        var dashes: [CGFloat] = []
        var currentDash: CGFloat = 0
        var isDash = (pattern & 0x8000) != 0

        for i in (0..<16).reversed() {
            let bit = (pattern >> i) & 1
            let isBitSet = bit != 0

            if isBitSet == isDash {
                currentDash += 1
            } else {
                if currentDash > 0 {
                    dashes.append(currentDash)
                }
                isDash = isBitSet
                currentDash = 1
            }
        }
        if currentDash > 0 {
            dashes.append(currentDash)
        }

        return dashes.count <= 2 && dashes.allSatisfy({ $0 > 14 }) ? [] : dashes
    }
}

// MARK: - Line Preview Component

struct LinePreviewView: View {
    let color: Color
    let dashPattern: UInt16
    let weight: Int
    let outlineColor: Color?
    let outlineWeight: Int
    var isZigzag: Bool = false

    var body: some View {
        Canvas { context, size in
            let strokeWidth = CGFloat(max(1, weight))

            // Draw outline first (only if weight > 0)
            if let outlineColor = outlineColor, outlineWeight > 0 {
                let outlineStrokeWidth = CGFloat(outlineWeight)
                let outlinePath = createLinePath(size: size, isZigzag: isZigzag)
                context.stroke(outlinePath, with: .color(outlineColor), style: StrokeStyle(lineWidth: outlineStrokeWidth))
            }

            // Draw main line with dash pattern
            let linePath = createLinePath(size: size, isZigzag: isZigzag)

            let dashStyle = StrokeStyle(
                lineWidth: strokeWidth,
                lineCap: .round,
                lineJoin: .round,
                dash: dashPatternToDashArray(dashPattern)
            )
            context.stroke(linePath, with: .color(color), style: dashStyle)
        }
    }

    private func createLinePath(size: CGSize, isZigzag: Bool) -> Path {
        var path = Path()
        let centerY = size.height / 2
        let zigzagAmplitude = size.height / 4
        let segments = 4
        let segmentWidth = size.width / CGFloat(segments)

        if isZigzag {
            path.move(to: CGPoint(x: 0, y: centerY))
            for i in 1...segments {
                let x = segmentWidth * CGFloat(i)
                let offset = (i % 2 == 0) ? zigzagAmplitude : -zigzagAmplitude
                path.addLine(to: CGPoint(x: x, y: centerY + offset))
            }
        } else {
            path.move(to: CGPoint(x: 0, y: centerY))
            path.addLine(to: CGPoint(x: size.width, y: centerY))
        }
        return path
    }

    private func dashPatternToDashArray(_ pattern: UInt16) -> [CGFloat] {
        if pattern == 0xFFFF {
            return []
        }
        var dashes: [CGFloat] = []
        var currentDash: CGFloat = 0
        var isDash = (pattern & 0x8000) != 0

        for i in (0..<16).reversed() {
            let bit = (pattern >> i) & 1
            let isBitSet = bit != 0

            if isBitSet == isDash {
                currentDash += 1
            } else {
                if currentDash > 0 {
                    dashes.append(currentDash)
                }
                isDash = isBitSet
                currentDash = 1
            }
        }
        if currentDash > 0 {
            dashes.append(currentDash)
        }

        return dashes.count <= 2 && dashes.allSatisfy({ $0 > 14 }) ? [] : dashes
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

            // Fill polygon
            context.fill(path, with: .color(fillColor))

            // Draw main line stroke first
            if let lineColor = lineColor, weight > 0 {
                let strokeWidth = CGFloat(max(1, weight))
                let isZigzag = dashPattern == 49344
                let pathToStroke = isZigzag ? createZigzagPath(for: path, size: size) : path
                let dashStyle = StrokeStyle(
                    lineWidth: strokeWidth,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: isZigzag ? [] : dashPatternToDashArray(dashPattern)
                )
                context.stroke(pathToStroke, with: .color(lineColor), style: dashStyle)
            }

            // Draw outline on top (should be thicker to cover main line)
            if let outlineColor = outlineColor, outlineWeight > 0 {
                let outlineStrokeWidth = CGFloat(outlineWeight)
                let isZigzag = outlineDashPattern == 49344
                let pathToStroke = isZigzag ? createZigzagPath(for: path, size: size) : path
                let dashStyle = StrokeStyle(
                    lineWidth: outlineStrokeWidth,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: isZigzag ? [] : dashPatternToDashArray(outlineDashPattern)
                )
                context.stroke(pathToStroke, with: .color(outlineColor), style: dashStyle)
            }
        }
    }

    private func createZigzagPath(for basePath: Path, size: CGSize, amplitude: CGFloat = 5) -> Path {
        // Create zigzag around rectangle perimeter
        let inset: CGFloat = 4
        let topLeft = CGPoint(x: inset, y: inset)
        let topRight = CGPoint(x: size.width - inset, y: inset)
        let bottomRight = CGPoint(x: size.width - inset, y: size.height - inset)
        let bottomLeft = CGPoint(x: inset, y: size.height - inset)

        var points: [CGPoint] = []
        let stepSize: CGFloat = 8
        var isInset = false

        // Top edge (left to right)
        var x = topLeft.x
        while x <= topRight.x {
            let y = topLeft.y + (isInset ? -amplitude : amplitude)
            points.append(CGPoint(x: x, y: min(y, topLeft.y + amplitude)))
            x += stepSize
            isInset.toggle()
        }

        // Right edge (top to bottom)
        var y = topRight.y + stepSize
        while y <= bottomRight.y {
            let xOffset = isInset ? amplitude : -amplitude
            points.append(CGPoint(x: topRight.x + xOffset, y: y))
            y += stepSize
            isInset.toggle()
        }

        // Bottom edge (right to left)
        x = bottomRight.x - stepSize
        while x >= bottomLeft.x {
            let yOffset = isInset ? amplitude : -amplitude
            points.append(CGPoint(x: x, y: bottomRight.y + yOffset))
            x -= stepSize
            isInset.toggle()
        }

        // Left edge (bottom to top)
        y = bottomLeft.y - stepSize
        while y >= topLeft.y {
            let xOffset = isInset ? -amplitude : amplitude
            points.append(CGPoint(x: bottomLeft.x + xOffset, y: y))
            y -= stepSize
            isInset.toggle()
        }

        var zigzagPath = Path()
        if !points.isEmpty {
            zigzagPath.move(to: points[0])
            for point in points.dropFirst() {
                zigzagPath.addLine(to: point)
            }
            zigzagPath.closeSubpath()
        }

        return zigzagPath
    }

    private func dashPatternToDashArray(_ pattern: UInt16) -> [CGFloat] {
        if pattern == 0xFFFF {
            return []
        }
        var dashes: [CGFloat] = []
        var currentDash: CGFloat = 0
        var isDash = (pattern & 0x8000) != 0

        for i in (0..<16).reversed() {
            let bit = (pattern >> i) & 1
            let isBitSet = bit != 0

            if isBitSet == isDash {
                currentDash += 1
            } else {
                if currentDash > 0 {
                    dashes.append(currentDash)
                }
                isDash = isBitSet
                currentDash = 1
            }
        }
        if currentDash > 0 {
            dashes.append(currentDash)
        }

        return dashes.count <= 2 && dashes.allSatisfy({ $0 > 14 }) ? [] : dashes
    }
}

#Preview {
    StyleSelectorModal(selectedStyleId: .constant(.custom(0x0202)))
}
