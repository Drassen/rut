import SwiftUI

struct VectorShapeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vectorStore: VectorStore

    let shape: VectorShape
    let layerId: UUID

    @State private var name: String
    @State private var notes: String
    @State private var strokeColorUI: Color
    @State private var fillColorUI: Color
    @State private var strokeWidth: Double
    @State private var opacity: Double
    @State private var pointIcon: VectorPointIcon
    @State private var iconScale: Double
    @State private var dmgCategory: DMGShapeCategory
    @State private var dmgAreaType: DMGAreaType
    @State private var dmgStyleClass: DMGStyleClass
    @State private var customStyleInput: String = ""
    @State private var showCustomStyleInput: Bool = false
    @State private var showStyleSelector: Bool = false

    init(shape: VectorShape, layerId: UUID) {
        self.shape   = shape
        self.layerId = layerId
        _name          = State(initialValue: shape.name)
        _notes         = State(initialValue: shape.notes)
        _strokeColorUI = State(initialValue: Color(hex: shape.style.strokeColor))
        _fillColorUI   = State(initialValue: Color(hex: shape.style.fillColor.isEmpty ? "#00000000" : shape.style.fillColor))
        _strokeWidth   = State(initialValue: shape.style.strokeWidth)
        _opacity       = State(initialValue: shape.style.opacity)
        _pointIcon     = State(initialValue: shape.style.pointIcon)
        _iconScale     = State(initialValue: shape.style.iconScale)
        _dmgCategory   = State(initialValue: shape.dmgCategory)
        _dmgAreaType   = State(initialValue: shape.dmgAreaType)
        _dmgStyleClass = State(initialValue: shape.dmgStyleClass)
    }

    var body: some View {
        NavigationStack {
            Form {

                Section("General") {
                    TextField("Name", text: $name)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(4...8)
                }

                if isPoint {
                    Section("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(VectorPointIcon.allCases, id: \.self) { icon in
                                Button {
                                    pointIcon = icon
                                } label: {
                                    VStack(spacing: 4) {
                                        VectorPointIconView(
                                            icon: icon,
                                            color: pointIcon == icon ? RutTheme.amber : Color.primary,
                                            size: 28
                                        )
                                        Text(icon.displayName)
                                            .font(.system(size: 9))
                                            .foregroundStyle(pointIcon == icon ? RutTheme.amber : Color.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(pointIcon == icon ? RutTheme.amber.opacity(0.12) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Section("Style") {
                        ColorPicker("Icon color", selection: $strokeColorUI, supportsOpacity: false)
                        LabeledContent("Scale") {
                            HStack {
                                Slider(value: $iconScale, in: 0.5...3.0, step: 0.25)
                                Text(String(format: "×%.2g", iconScale))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40)
                            }
                        }
                        LabeledContent("Opacity") {
                            HStack {
                                Slider(value: $opacity, in: 0...1, step: 0.05)
                                Text(String(format: "%.0f%%", opacity * 100))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40)
                            }
                        }
                    }
                } else {
                Section("Style") {
                    ColorPicker("Stroke color", selection: $strokeColorUI, supportsOpacity: false)
                    if !isPolyline {
                        ColorPicker("Fill color", selection: $fillColorUI, supportsOpacity: true)
                    }
                    LabeledContent("Stroke width") {
                        HStack {
                            Slider(value: $strokeWidth, in: 0.5...8, step: 0.5)
                            Text(String(format: "%.1f", strokeWidth))
                                .foregroundStyle(.secondary)
                                .frame(width: 32)
                        }
                    }
                    LabeledContent("Opacity") {
                        HStack {
                            Slider(value: $opacity, in: 0...1, step: 0.05)
                            Text(String(format: "%.0f%%", opacity * 100))
                                .foregroundStyle(.secondary)
                                .frame(width: 40)
                        }
                    }
                }
                }

                // A109 DMG export section (all shapes)
                Section("Euronav DMG options (A109)") {
                        if !isPolyline {
                            Picker("Shape Type", selection: $dmgCategory) {
                                ForEach([DMGShapeCategory.drawing, .area], id: \.self) { cat in
                                    Text(cat.displayName).tag(cat)
                                }
                            }
                        }

                        if dmgCategory == .area {
                            Picker("Zone Type", selection: $dmgAreaType) {
                                ForEach(DMGAreaType.allCases, id: \.self) { areaType in
                                    Text(areaType.displayName).tag(areaType)
                                }
                            }
                        } else {
                            stylePreviewBox()
                                .onTapGesture { showStyleSelector = true }
                        }
                    }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save(); dismiss() }
                        .bold()
                }
            }
        }
        .tint(RutTheme.amber)
        .sheet(isPresented: $showStyleSelector) {
            StyleSelectorModal(
                selectedStyleId: $dmgStyleClass,
                geometry: shape.geometry,
                onStyleChange: { style in
                    if let lineColor = style.lineColor {
                        strokeColorUI = lineColor
                    }
                    if let fillColor = style.polygonFillColor {
                        fillColorUI = fillColor
                    }
                    strokeWidth = Double(style.lineWeight)
                }
            )
        }
    }

    private var isPoint: Bool {
        if case .point = shape.geometry { return true }
        return false
    }

    private var isPolyline: Bool {
        if case .polyline = shape.geometry { return true }
        return false
    }

    private func save() {
        var updated = shape
        updated.name = name
        updated.notes = notes
        updated.style.strokeColor = strokeColorUI.toHexString()
        updated.style.fillColor   = fillColorUI.toHexString(includeAlpha: true)
        updated.style.strokeWidth = strokeWidth
        updated.style.opacity     = opacity
        updated.style.pointIcon   = pointIcon
        updated.style.iconScale   = iconScale
        updated.dmgCategory = dmgCategory
        updated.dmgAreaType = dmgAreaType
        updated.dmgStyleClass = dmgStyleClass
        vectorStore.updateShape(updated, in: layerId)
    }

    private var customStyleIDDisplay: String {
        if case .custom(let id) = dmgStyleClass {
            return String(format: "0x%04X (%d)", id, id)
        }
        return ""
    }

    private func getStyleSymbolInfo(styleId: UInt16) -> (symbolId: Int, primaryColor: Color?, secondaryColor: Color?)? {
        guard let appMatrixPath = Bundle.main.path(forResource: "appMatrix", ofType: "json", inDirectory: "euronav5") else {
            return nil
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: appMatrixPath)) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let members = json["member"] as? [[Any]] else {
            return nil
        }

        for member in members {
            guard member.count >= 2,
                  let ids = member[0] as? [Int],
                  ids.count >= 2,
                  let info = member[1] as? [Any],
                  info.count >= 3,
                  let renderingData = info[2] as? [[Any]],
                  renderingData.count >= 1 else {
                continue
            }

            let loadedStyleId = UInt16(ids[1])
            if loadedStyleId == styleId {
                let colors = renderingData[0]
                var symbolId: Int = 0
                var primaryColor: Color? = nil
                var secondaryColor: Color? = nil

                if colors.count >= 2 {
                    if let primaryColorArray = colors[0] as? [Int], primaryColorArray.count >= 3 {
                        primaryColor = arrayToColor(primaryColorArray)
                    }
                    if let secondaryColorArray = colors[1] as? [Int], secondaryColorArray.count >= 3 {
                        secondaryColor = arrayToColor(secondaryColorArray)
                    }
                }

                if colors.count > 2, let symbol = colors[2] as? Int {
                    symbolId = symbol
                }

                return (symbolId, primaryColor, secondaryColor)
            }
        }

        return nil
    }

    private func arrayToColor(_ array: [Int]) -> Color? {
        guard array.count >= 3 else { return nil }
        let r = CGFloat(array[0]) / 255.0
        let g = CGFloat(array[1]) / 255.0
        let b = CGFloat(array[2]) / 255.0
        let a = array.count >= 4 ? CGFloat(array[3]) / 255.0 : 1.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    @ViewBuilder
    private func stylePreviewBox() -> some View {
        HStack(spacing: 12) {
            if case .custom(let id) = dmgStyleClass, let styleInfo = getStyleSymbolInfo(styleId: id) {
                if styleInfo.symbolId > 0 {
                    GlyphDisplayView(
                        symbolId: UInt16(styleInfo.symbolId),
                        primaryColor: styleInfo.primaryColor,
                        secondaryColor: styleInfo.secondaryColor
                    )
                    .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Style")
                        .font(.headline)
                    Text(String(format: "0x%04X (%d)", id, id))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if case .custom(let id) = dmgStyleClass {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Style")
                        .font(.headline)
                    Text(String(format: "0x%04X (%d)", id, id))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if case .known(let known) = dmgStyleClass, let styleInfo = getStyleSymbolInfo(styleId: known.rawValue) {
                if styleInfo.symbolId > 0 {
                    GlyphDisplayView(
                        symbolId: UInt16(styleInfo.symbolId),
                        primaryColor: styleInfo.primaryColor,
                        secondaryColor: styleInfo.secondaryColor
                    )
                    .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(known.displayName)
                        .font(.headline)
                    Text(String(format: "0x%04X (%d)", known.rawValue, known.rawValue))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if case .known(let known) = dmgStyleClass {
                VStack(alignment: .leading, spacing: 2) {
                    Text(known.displayName)
                        .font(.headline)
                    Text(String(format: "0x%04X (%d)", known.rawValue, known.rawValue))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    private func updateCustomStyleFromInput(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let id: UInt16?
        if trimmed.lowercased().hasPrefix("0x") {
            // Parse as hex
            let hexStr = String(trimmed.dropFirst(2))
            id = UInt16(hexStr, radix: 16)
        } else {
            // Parse as decimal
            id = UInt16(trimmed, radix: 10)
        }

        if let id = id {
            dmgStyleClass = .custom(id)
        }
    }
}

// MARK: - Color → hex string

extension Color {
    func toHexString(includeAlpha: Bool = false) -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int(r * 255), gi = Int(g * 255), bi = Int(b * 255)
        if includeAlpha {
            let ai = Int(a * 255)
            return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
        } else {
            return String(format: "#%02X%02X%02X", ri, gi, bi)
        }
    }
}
