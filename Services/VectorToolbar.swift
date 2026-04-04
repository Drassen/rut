import SwiftUI

// MARK: - VectorToolbar

struct VectorToolbar: View {
    @EnvironmentObject var vectorStore: VectorStore
    @EnvironmentObject var toastManager: ToastManager

    @State private var showNewShapeNameAlert = false
    @State private var pendingShapeName = ""
    @State private var exportContainer: ExportContainer? = nil
    @State private var showShapeEditor = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(RutTheme.border).frame(height: 1)
            HStack(spacing: 8) {
                if vectorStore.isEditingShape {
                    // ── Editing mode ──────────────────────────────────────────
                    Button("Done") { vectorStore.commitShapeEdit() }
                        .buttonStyle(RutPrimaryButtonStyle())
                    Button("Cancel") { vectorStore.cancelShapeEdit() }
                        .buttonStyle(RutSecondaryButtonStyle())
                    Spacer()
                } else if vectorStore.activeShapeId != nil && vectorStore.activeTool == .none {
                    // ── Shape selected ────────────────────────────────────────
                    let isSystem = selectedShapeIsSystem
                    if !isSystem {
                        Button(selectedShapeIsPoint ? "Move" : "Edit Shape") {
                            vectorStore.beginEditingShape()
                        }
                        .buttonStyle(RutSecondaryButtonStyle())
                    }

                    Button("Edit Properties") { showShapeEditor = true }
                        .buttonStyle(RutSecondaryButtonStyle())

                    if !isSystem {
                        Button {
                            if let id = vectorStore.activeShapeId,
                               let layerId = vectorStore.activeShapeLayerId {
                                vectorStore.deleteShape(shapeId: id, in: layerId)
                                vectorStore.deselectShape()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(RutSecondaryButtonStyle())
                    }

                    Spacer()

                    Button {
                        vectorStore.deselectShape()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(RutSecondaryButtonStyle())
                } else {
                    // ── Default: tool pills ───────────────────────────────────
                    toolButton(tool: .none,     icon: "cursorarrow",   label: "Select")
                    toolButton(tool: .point,    icon: "mappin",        label: "Point")
                    toolButton(tool: .polyline, icon: "line.diagonal", label: "Line")
                    toolButton(tool: .polygon,  icon: "triangle",      label: "Polygon")
                    toolButton(tool: .circle,   icon: "circle",        label: "Circle")

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
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(RutSecondaryButtonStyle())
                    .sheet(item: $exportContainer) { container in
                        MultiFileExportController(fileURLs: container.urls) { _ in }
                    }
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
                vectorStore.activeTool = .none
                pendingShapeName = ""
            }
            Button("Cancel", role: .cancel) {
                vectorStore.drawing.cancel()
                pendingShapeName = ""
            }
        }
        .sheet(isPresented: $showShapeEditor) {
            if let id = vectorStore.activeShapeId,
               let found = vectorStore.findShape(id: id) {
                VectorShapeEditorView(shape: found.shape, layerId: found.layerId)
                    .environmentObject(vectorStore)
            }
        }
    }

    private var selectedShapeIsPoint: Bool {
        guard let id = vectorStore.activeShapeId,
              let found = vectorStore.findShape(id: id) else { return false }
        if case .point = found.shape.geometry { return true }
        return false
    }

    private var selectedShapeIsSystem: Bool {
        guard let layerId = vectorStore.activeShapeLayerId else { return false }
        return vectorStore.layerIsSystem(id: layerId)
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
