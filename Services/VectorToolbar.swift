import SwiftUI

// MARK: - VectorToolbar

struct VectorToolbar: View {
    @EnvironmentObject var vectorStore: VectorStore
    @EnvironmentObject var toastManager: ToastManager

    @State private var showNewShapeNameAlert = false
    @State private var pendingShapeName = ""
    @State private var exportContainer: ExportContainer? = nil

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(RutTheme.border).frame(height: 1)
            HStack(spacing: 8) {
                // Drawing tool pills
                toolButton(tool: .none,     icon: "cursorarrow",         label: "Select")
                toolButton(tool: .point,    icon: "circle.fill",         label: "Point")
                toolButton(tool: .polyline, icon: "line.diagonal",       label: "Line")
                toolButton(tool: .polygon,  icon: "hexagon",             label: "Polygon")
                toolButton(tool: .circle,   icon: "circle",              label: "Circle")

                Spacer()

                // Done / Undo — only when actively drawing
                if vectorStore.activeTool != .none && vectorStore.drawing.isActive {
                    Button {
                        vectorStore.drawing.undoLastVertex()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(RutSecondaryButtonStyle())

                    Button("Done") {
                        if vectorStore.activeLayerId == nil {
                            // No layer selected — prompt to create one or use first
                            if vectorStore.layers.first(where: { !$0.isSystem }) == nil {
                                vectorStore.addLayer(name: "Layer 1")
                            }
                        }
                        pendingShapeName = defaultName()
                        showNewShapeNameAlert = true
                    }
                    .buttonStyle(RutPrimaryButtonStyle())
                }

                // KML export
                Button {
                    exportVector()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(RutSecondaryButtonStyle())
                .sheet(item: $exportContainer) { container in
                    MultiFileExportController(fileURLs: container.urls) { _ in }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RutTheme.surface)
        }
        .alert("Shape Name", isPresented: $showNewShapeNameAlert) {
            TextField("Name", text: $pendingShapeName)
            Button("Add") {
                vectorStore.commitDrawing(name: pendingShapeName)
                pendingShapeName = ""
            }
            Button("Cancel", role: .cancel) {
                vectorStore.drawing.cancel()
                pendingShapeName = ""
            }
        }
    }

    @ViewBuilder
    private func toolButton(tool: DrawingTool, icon: String, label: String) -> some View {
        let isActive = vectorStore.activeTool == tool
        Button {
            vectorStore.activeTool = tool
            if tool == .none { vectorStore.drawing.cancel() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: isActive ? .bold : .regular))
                .foregroundColor(isActive ? .black : RutTheme.text)
                .frame(width: 32, height: 28)
                .background(isActive ? RutTheme.amber : RutTheme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                    isActive ? RutTheme.amber : RutTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func defaultName() -> String {
        let base: String
        switch vectorStore.activeTool {
        case .point:    base = "Point"
        case .polyline: base = "Line"
        case .polygon:  base = "Polygon"
        case .circle:   base = "Circle"
        case .none:     base = "Shape"
        }
        return base
    }

    private func exportVector() {
        let exporter = KMLVectorExportService()
        do {
            // Build a minimal document just with vector layers
            var doc = NavigationDocument()
            doc.vectorLayers = CoreServices.shared.vectorStore.documentLayers()
            let files = try exporter.export(document: doc, selectedRoutes: [])
            guard !files.isEmpty else {
                toastManager.show(message: "No vector layers to export.", kind: .info); return
            }
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            var urls: [URL] = []
            for file in files {
                let url = tempDir.appendingPathComponent(file.filename)
                try file.data.write(to: url, options: .atomic)
                urls.append(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.exportContainer = ExportContainer(urls: urls)
            }
        } catch {
            toastManager.show(message: error.localizedDescription)
        }
    }
}
