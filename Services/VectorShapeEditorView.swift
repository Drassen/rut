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
                                        let tint: Color = pointIcon == icon ? RutTheme.amber : Color.primary
                                        AsyncImage(url: URL(string: icon.rawValue)) { phase in
                                            if let img = phase.image {
                                                img.resizable().scaledToFit().colorMultiply(tint)
                                            } else {
                                                Image(systemName: icon.sfSymbol)
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(tint, Color.white)
                                            }
                                        }
                                        .frame(width: 28, height: 28)
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
            }
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
        vectorStore.updateShape(updated, in: layerId)
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
