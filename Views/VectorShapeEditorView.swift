import SwiftUI

struct VectorShapeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vectorStore: VectorStore

    let shape: VectorShape
    let layerId: UUID

    @State private var name: String
    @State private var strokeColorUI: Color
    @State private var fillColorUI: Color
    @State private var strokeWidth: Double
    @State private var opacity: Double
    @State private var isVisible: Bool
    @State private var confirmDelete = false

    init(shape: VectorShape, layerId: UUID) {
        self.shape   = shape
        self.layerId = layerId
        _name           = State(initialValue: shape.name)
        _strokeColorUI  = State(initialValue: Color(hex: shape.style.strokeColor))
        _fillColorUI    = State(initialValue: Color(hex: shape.style.fillColor.isEmpty ? "#00000000" : shape.style.fillColor))
        _strokeWidth    = State(initialValue: shape.style.strokeWidth)
        _opacity        = State(initialValue: shape.style.opacity)
        _isVisible      = State(initialValue: shape.isVisible)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Toggle("Visible", isOn: $isVisible)
                }

                Section("Style") {
                    ColorPicker("Stroke color", selection: $strokeColorUI, supportsOpacity: false)
                    ColorPicker("Fill color",   selection: $fillColorUI,   supportsOpacity: true)
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

                Section("Geometry") {
                    LabeledContent("Type", value: shape.geometry.geometryTypeName)
                    LabeledContent("Vertices", value: "\(shape.geometry.vertexCount)")
                }

                Section {
                    Button("Delete shape", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
            .navigationTitle("Shape")
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
            .confirmationDialog("Delete this shape?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    vectorStore.deleteShape(shapeId: shape.id, in: layerId)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            }
        }
        .tint(RutTheme.amber)
    }

    private func save() {
        var updated = shape
        updated.name = name
        updated.isVisible = isVisible
        updated.style.strokeColor = strokeColorUI.toHexString()
        updated.style.fillColor   = fillColorUI.toHexString(includeAlpha: true)
        updated.style.strokeWidth = strokeWidth
        updated.style.opacity     = opacity
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
