import SwiftUI
import zlib

// MARK: - VectorToolbar

struct VectorToolbar: View {
    @EnvironmentObject var vectorStore: VectorStore
    @EnvironmentObject var toastManager: ToastManager

    @State private var showNewShapeNameAlert = false
    @State private var pendingShapeName = ""
    @State private var exportContainer: ExportContainer? = nil
    @State private var showShapeEditor = false
    @State private var showRenameFolderAlert = false
    @State private var renameFolderText = ""

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
                    exportButton
                } else if vectorStore.activeShapeId != nil && vectorStore.activeTool == .none {
                    // ── Shape selected ────────────────────────────────────────
                    let isSystem = selectedShapeIsSystem
                    if !isSystem {
                        Button(selectedShapeIsPoint ? "Move" : "Edit Shape") {
                            vectorStore.beginEditingShape()
                        }
                        .buttonStyle(RutSecondaryButtonStyle())
                    }

                    if !isSystem {
                        Button("Edit Properties") { showShapeEditor = true }
                            .buttonStyle(RutSecondaryButtonStyle())
                    }

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

                    exportButton

                    Button {
                        vectorStore.deselectShape()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(RutSecondaryButtonStyle())
                } else {
                    // ── Default: tool pills ───────────────────────────────────
                    toolButton(tool: .none, icon: "cursorarrow", label: "Select")

                    Text("Create shape:")
                        .font(.system(size: 11))
                        .foregroundColor(RutTheme.textMuted)
                        .padding(.leading, 6)

                    toolButton(tool: .point,    icon: "mappin.circle.fill", label: "Point")
                    toolButton(tool: .polyline, icon: "line.diagonal", label: "Line")
                    toolButton(tool: .polygon,  icon: "triangle",      label: "Polygon")
                    toolButton(tool: .circle,   icon: "circle",        label: "Circle")

                    Spacer()

                    // Edit Group Name — shown when a non-system folder is selected
                    if let folderId = vectorStore.activeLayerId,
                       vectorStore.activeShapeId == nil,
                       !vectorStore.layerIsSystem(id: folderId) {
                        Button("Edit group name") {
                            if let name = vectorStore.layerName(id: folderId) {
                                renameFolderText = name
                            }
                            showRenameFolderAlert = true
                        }
                        .buttonStyle(RutSecondaryButtonStyle())
                        .padding(.trailing, 8)
                    }

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

                    exportButton
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
        .alert("Edit group name", isPresented: $showRenameFolderAlert) {
            TextField("Name", text: $renameFolderText)
            Button("Save") {
                if let id = vectorStore.activeLayerId {
                    let name = renameFolderText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { vectorStore.renameLayer(id: id, name: name) }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showShapeEditor) {
            if let id = vectorStore.activeShapeId,
               let found = vectorStore.findShape(id: id) {
                VectorShapeEditorView(shape: found.shape, layerId: found.layerId)
                    .environmentObject(vectorStore)
            }
        }
    }

    // MARK: - Export button

    @ViewBuilder
    private var exportButton: some View {
        Button {
            exportSelection()
        } label: {
            Label(exportButtonLabel, systemImage: "square.and.arrow.up")
        }
        .buttonStyle(RutSecondaryButtonStyle())
        .sheet(item: $exportContainer) { container in
            MultiFileExportController(fileURLs: container.urls) { _ in }
        }
    }

    private var exportButtonLabel: String {
        if vectorStore.activeShapeId != nil {
            return "Export Shape"
        } else if vectorStore.activeLayerId != nil && vectorStore.activeShapeId == nil {
            return "Export Group"
        } else {
            return "Export"
        }
    }

    // MARK: - Export logic

    private func exportSelection() {
        let kmlService = KMLVectorExportService()
        do {
            // Determine what to export
            let layersToExport: [VectorLayer]
            let outputName: String

            if let shapeId = vectorStore.activeShapeId,
               let found = vectorStore.findShape(id: shapeId),
               let parentLayer = vectorStore.findLayer(id: found.layerId) {
                // Export single shape wrapped in a copy of its parent layer
                var singleLayer = parentLayer
                singleLayer.shapes = [found.shape]
                singleLayer.children = []
                layersToExport = [singleLayer]
                outputName = sanitizeFilename(found.shape.name)
            } else if let layerId = vectorStore.activeLayerId,
                      let layer = vectorStore.findLayer(id: layerId) {
                layersToExport = [layer]
                outputName = sanitizeFilename(layer.name)
            } else {
                layersToExport = vectorStore.layers.filter { !$0.isSystem }
                outputName = "VectorLayers"
            }

            guard !layersToExport.isEmpty else {
                toastManager.show(message: "Nothing to export.", kind: .info)
                return
            }

            // Build KML
            var doc = NavigationDocument()
            doc.vectorLayers = layersToExport
            let files = try kmlService.export(document: doc, selectedRoutes: [])
            guard let kmlFile = files.first else {
                toastManager.show(message: "Export failed.", kind: .info)
                return
            }

            // Package as KMZ (minimal ZIP, stored mode)
            let kmzData = buildKMZ(kmlData: kmlFile.data)

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let kmzURL = tempDir.appendingPathComponent(outputName + ".kmz")
            try kmzData.write(to: kmzURL, options: .atomic)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.exportContainer = ExportContainer(urls: [kmzURL])
            }
        } catch {
            toastManager.show(message: error.localizedDescription)
        }
    }

    // MARK: - Minimal ZIP / KMZ builder (stored, no compression)

    private func buildKMZ(kmlData: Data) -> Data {
        let filename = "doc.kml"
        let filenameBytes = Array(filename.utf8)
        let fileSize = UInt32(kmlData.count)

        // CRC-32 via zlib
        let crc: UInt32 = kmlData.withUnsafeBytes { ptr -> UInt32 in
            guard let base = ptr.baseAddress else { return 0 }
            let result = zlib.crc32(0, base.assumingMemoryBound(to: Bytef.self), uInt(kmlData.count))
            return UInt32(result & 0xFFFFFFFF)
        }

        var data = Data()

        // ── Local file header ──────────────────────────────────────────────
        let localHeaderOffset = UInt32(0)
        data.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])   // signature
        data.append(uint16LE: 0x0014)   // version needed
        data.append(uint16LE: 0x0000)   // flags
        data.append(uint16LE: 0x0000)   // compression: stored
        data.append(uint16LE: 0x0000)   // mod time
        data.append(uint16LE: 0x0000)   // mod date
        data.append(uint32LE: crc)
        data.append(uint32LE: fileSize) // compressed size
        data.append(uint32LE: fileSize) // uncompressed size
        data.append(uint16LE: UInt16(filenameBytes.count))
        data.append(uint16LE: 0x0000)   // extra field length
        data.append(contentsOf: filenameBytes)
        data.append(kmlData)

        // ── Central directory header ───────────────────────────────────────
        let centralDirOffset = UInt32(data.count)
        data.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])   // signature
        data.append(uint16LE: 0x0014)   // version made by
        data.append(uint16LE: 0x0014)   // version needed
        data.append(uint16LE: 0x0000)   // flags
        data.append(uint16LE: 0x0000)   // compression: stored
        data.append(uint16LE: 0x0000)   // mod time
        data.append(uint16LE: 0x0000)   // mod date
        data.append(uint32LE: crc)
        data.append(uint32LE: fileSize) // compressed size
        data.append(uint32LE: fileSize) // uncompressed size
        data.append(uint16LE: UInt16(filenameBytes.count))
        data.append(uint16LE: 0x0000)   // extra field length
        data.append(uint16LE: 0x0000)   // comment length
        data.append(uint16LE: 0x0000)   // disk start
        data.append(uint16LE: 0x0000)   // internal attrs
        data.append(uint32LE: 0x00000000) // external attrs
        data.append(uint32LE: localHeaderOffset)
        data.append(contentsOf: filenameBytes)

        let centralDirSize = UInt32(data.count) - centralDirOffset

        // ── End of central directory ───────────────────────────────────────
        data.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])   // signature
        data.append(uint16LE: 0x0000)   // disk number
        data.append(uint16LE: 0x0000)   // start disk
        data.append(uint16LE: 0x0001)   // entries on this disk
        data.append(uint16LE: 0x0001)   // total entries
        data.append(uint32LE: centralDirSize)
        data.append(uint32LE: centralDirOffset)
        data.append(uint16LE: 0x0000)   // comment length

        return data
    }

    // MARK: - Helpers

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = name.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        let trimmed = String(cleaned.prefix(60))
        return trimmed.isEmpty ? "export" : trimmed
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
}

// MARK: - Data ZIP helpers

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func append(uint32LE value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
