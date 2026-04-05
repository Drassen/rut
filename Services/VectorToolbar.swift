import SwiftUI
import zlib

// MARK: - Export format

enum VectorExportFormat: String, CaseIterable, Identifiable {
    case kmz  = "KMZ"
    case atak = "ATAK (.zip)"
    var id: String { rawValue }
}

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
    @State private var exportFormat: VectorExportFormat = .kmz  // kept for exportSelection()

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
                    exportMenu
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

                    exportMenu

                    Button {
                        vectorStore.deselectShape()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(RutSecondaryButtonStyle())
                } else {
                    if vectorStore.activeTool == .none {
                        // ── Default: all tool pills ───────────────────────────
                        toolButton(tool: .none, icon: "cursorarrow", label: "Select")

                        Text("Create shape:")
                            .font(.system(size: 11))
                            .foregroundColor(RutTheme.textMuted)
                            .padding(.leading, 6)

                        pointToolButton
                        toolButton(tool: .polyline, icon: "line.diagonal", label: "Line")
                        toolButton(tool: .zigzag,   icon: "waveform.path", label: "Zigzag")
                        toolButton(tool: .polygon,  icon: "triangle",      label: "Polygon")
                        toolButton(tool: .circle,   icon: "circle",        label: "Circle")

                        Spacer()

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

                        formatPicker
                        exportButton

                    } else {
                        // ── Create mode ───────────────────────────────────────
                        Button {
                            vectorStore.activeTool = .none
                            vectorStore.drawing.cancel()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(RutSecondaryButtonStyle())

                        activeToolBadge

                        if vectorStore.activeTool == .zigzag {
                            zigzagWidthPicker
                        }

                        Spacer()

                        if vectorStore.drawing.isActive {
                            Button {
                                vectorStore.drawing.undoLastVertex()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(RutSecondaryButtonStyle())

                            Button("Done") {
                                if vectorStore.activeLayerId == nil {
                                    if let existing = vectorStore.layers.first(where: { !$0.isSystem }) {
                                        vectorStore.activeLayerId = existing.id
                                    } else {
                                        vectorStore.addLayer(name: "Layer 1")
                                    }
                                }
                                pendingShapeName = defaultName()
                                showNewShapeNameAlert = true
                            }
                            .buttonStyle(RutPrimaryButtonStyle())
                        }
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

    // MARK: - Export menu

    @ViewBuilder
    private var exportMenu: some View {
        Menu {
            ForEach(VectorExportFormat.allCases) { fmt in
                Button {
                    exportFormat = fmt
                    exportSelection()
                } label: {
                    Label(fmt.rawValue, systemImage: fmt == .kmz ? "map" : "antenna.radiowaves.left.and.right")
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(RutSecondaryButtonStyle())
        .sheet(item: $exportContainer) { container in
            MultiFileExportController(fileURLs: container.urls) { _ in }
        }
    }

    // MARK: - Export logic

    private func exportSelection() {
        do {
            // Determine what to export
            let layersToExport: [VectorLayer]
            let outputName: String

            if let shapeId = vectorStore.activeShapeId,
               let found = vectorStore.findShape(id: shapeId),
               let parentLayer = vectorStore.findLayer(id: found.layerId) {
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

            let outputData: Data
            let filename: String
            switch exportFormat {
            case .kmz:
                let kmlService = KMLVectorExportService()
                var doc = NavigationDocument()
                doc.vectorLayers = layersToExport
                let files = try kmlService.export(document: doc, selectedRoutes: [])
                guard let kmlFile = files.first else {
                    toastManager.show(message: "Export failed.", kind: .info)
                    return
                }
                outputData = buildZIP(entries: [("doc.kml", kmlFile.data)])
                filename = outputName + ".kmz"
            case .atak:
                outputData = buildATAKPackage(layers: layersToExport, name: outputName)
                filename = outputName + ".zip"
            }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let outURL = tempDir.appendingPathComponent(filename)
            try outputData.write(to: outURL, options: .atomic)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.exportContainer = ExportContainer(urls: [outURL])
            }
        } catch {
            toastManager.show(message: error.localizedDescription)
        }
    }

    // MARK: - ATAK Data Package builder
    // Generates native CoT (Cursor on Target) XML so shapes are fully editable in ATAK.
    // Structure:
    //   MANIFEST/manifest.xml
    //   <uid>/<uid>.cot  (one file per shape)

    private func buildATAKPackage(layers: [VectorLayer], name: String) -> Data {
        let packageUID = UUID().uuidString
        var entries: [(path: String, data: Data)] = []
        var contentEntries: [String] = []   // zipEntry paths for manifest

        // Collect all visible non-system shapes
        var shapes: [(shape: VectorShape, layerName: String)] = []
        for layer in layers {
            collectShapesFlat(from: layer, layerName: layer.name, into: &shapes)
        }

        let now   = ISO8601DateFormatter().string(from: Date())
        let stale = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 86400 * 365))

        for (shape, _) in shapes {
            let uid  = shape.id.uuidString
            let path = "\(uid)/\(uid).cot"
            let cot  = buildCoTEvent(shape: shape, uid: uid, now: now, stale: stale)
            if let data = cot.data(using: .utf8) {
                entries.append((path: path, data: data))
                contentEntries.append(path)
            }
        }

        // Manifest
        var contents = ""
        for path in contentEntries {
            let uid = path.components(separatedBy: "/").last?.replacingOccurrences(of: ".cot", with: "") ?? UUID().uuidString
            contents += "    <Content ignore=\"false\" zipEntry=\"\(path)\">\n"
            contents += "      <Parameter name=\"uid\" value=\"\(uid)\"/>\n"
            contents += "    </Content>\n"
        }

        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MissionPackageManifest version="2">
          <Configuration>
            <Parameter name="uid" value="\(packageUID)"/>
            <Parameter name="name" value="\(xmlEscape(name))"/>
            <Parameter name="onReceiveImport" value="true"/>
            <Parameter name="onReceiveDelete" value="false"/>
          </Configuration>
          <Contents>
        \(contents)  </Contents>
        </MissionPackageManifest>
        """
        if let manifestData = manifest.data(using: .utf8) {
            entries.insert(("MANIFEST/manifest.xml", manifestData), at: 0)
        }

        return buildZIP(entries: entries)
    }

    private func collectShapesFlat(from layer: VectorLayer, layerName: String,
                                   into result: inout [(shape: VectorShape, layerName: String)]) {
        if layer.isVisible {
            for shape in layer.shapes where shape.isVisible {
                result.append((shape: shape, layerName: layerName))
            }
            for child in layer.children {
                collectShapesFlat(from: child, layerName: child.name, into: &result)
            }
        }
    }

    // MARK: - CoT event builder

    private func buildCoTEvent(shape: VectorShape, uid: String, now: String, stale: String) -> String {
        let strokeARGB = hexToARGB(shape.style.strokeColor, alpha: shape.style.opacity)
        let fillARGB   = hexToARGB(shape.style.fillColor,   alpha: shape.style.opacity * 0.4)
        let strokeW    = String(format: "%.1f", shape.style.strokeWidth)
        let remarks    = shape.notes.isEmpty ? "" : "\n    <remarks>\(xmlEscape(shape.notes))</remarks>"

        switch shape.geometry {
        case .point(let lat, let lon):
            let iconUrl   = shape.style.pointIcon.rawValue
            let iconScale = String(format: "%.2f", shape.style.iconScale)
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <event version="2.0" uid="\(uid)" type="a-f-G-U-C" how="h-e"
                   time="\(now)" start="\(now)" stale="\(stale)">
              <point lat="\(lat)" lon="\(lon)" hae="0" ce="9999999" le="9999999"/>
              <detail>
                <contact callsign="\(xmlEscape(shape.name))"/>
                <color value="\(strokeARGB)"/>
                <usericon iconsetpath="\(iconUrl)" scale="\(iconScale)"/>\(remarks)
              </detail>
            </event>
            """

        case .polyline(let coords):
            let links  = coords.map { "    <link point='\($0[0]),\($0[1])'/>" }.joined(separator: "\n")
            let center = coordCenter(coords)
            return """
            <?xml version='1.0' encoding='UTF-8' standalone='yes'?>
            <event version='2.0' uid='\(uid)' type='u-d-f' how='h-e'
                   time='\(now)' start='\(now)' stale='\(stale)'>
              <point lat='\(center.lat)' lon='\(center.lon)' hae='9999999.0' ce='9999999.0' le='9999999.0'/>
              <detail>
            \(links)
                <strokeColor value='\(strokeARGB)'/>
                <strokeWeight value='\(strokeW)'/>
                <contact callsign='\(xmlEscape(shape.name))'/>\(remarks)
                <tog enabled='0'/>
                <labels_on value='false'/>
                <archive/>
              </detail>
            </event>
            """

        case .polygon(let coords):
            let links  = coords.map { "    <link point='\($0[0]),\($0[1])'/>" }.joined(separator: "\n")
            let center = coordCenter(coords)
            return """
            <?xml version='1.0' encoding='UTF-8' standalone='yes'?>
            <event version='2.0' uid='\(uid)' type='u-d-f' how='h-e'
                   time='\(now)' start='\(now)' stale='\(stale)'>
              <point lat='\(center.lat)' lon='\(center.lon)' hae='9999999.0' ce='9999999.0' le='9999999.0'/>
              <detail>
            \(links)
                <strokeColor value='\(strokeARGB)'/>
                <strokeWeight value='\(strokeW)'/>
                <fillColor value='\(fillARGB)'/>
                <contact callsign='\(xmlEscape(shape.name))'/>\(remarks)
                <tog enabled='0'/>
                <labels_on value='false'/>
                <archive/>
              </detail>
            </event>
            """

        case .circle(let lat, let lon, let radiusMeters):
            let r = String(format: "%.1f", radiusMeters)
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <event version="2.0" uid="\(uid)" type="u-d-c-c" how="h-e"
                   time="\(now)" start="\(now)" stale="\(stale)">
              <point lat="\(lat)" lon="\(lon)" hae="0" ce="9999999" le="9999999"/>
              <detail>
                <contact callsign="\(xmlEscape(shape.name))"/>
                <shape>
                  <ellipse major="\(r)" minor="\(r)" angle="0.0"/>
                </shape>
                <strokeColor value="\(strokeARGB)"/>
                <fillColor value="\(fillARGB)"/>
                <strokeWeight value="\(strokeW)"/>
                <strokeStyle value="solid"/>\(remarks)
              </detail>
            </event>
            """
        }
    }

    /// Converts "#RRGGBB" or "#RRGGBBAA" hex + opacity to ARGB signed int32 string (ATAK format).
    private func hexToARGB(_ hex: String, alpha: Double) -> String {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32
        if s.count == 6, let v = UInt32(s, radix: 16) {
            r = (v >> 16) & 0xFF; g = (v >> 8) & 0xFF; b = v & 0xFF
        } else if s.count == 8, let v = UInt32(s, radix: 16) {
            r = (v >> 24) & 0xFF; g = (v >> 16) & 0xFF; b = (v >> 8) & 0xFF
            let storedA = Double(v & 0xFF) / 255.0
            a = UInt32(min(max(storedA * alpha, 0), 1) * 255)
            let argb = UInt32(a) << 24 | r << 16 | g << 8 | b
            return String(Int32(bitPattern: argb))
        }
        a = UInt32(min(max(alpha, 0), 1) * 255)
        let argb = a << 24 | r << 16 | g << 8 | b
        return String(Int32(bitPattern: argb))
    }

    private func coordCenter(_ coords: [[Double]]) -> (lat: Double, lon: Double) {
        guard !coords.isEmpty else { return (0, 0) }
        let lat = coords.map { $0[0] }.reduce(0, +) / Double(coords.count)
        let lon = coords.map { $0[1] }.reduce(0, +) / Double(coords.count)
        return (lat, lon)
    }

    // MARK: - ZIP builder (stored, no compression)

    private func buildZIP(entries: [(path: String, data: Data)]) -> Data {
        var archive = Data()
        var centralHeaders: [(offset: UInt32, path: [UInt8], crc: UInt32, size: UInt32)] = []

        for (path, entryData) in entries {
            let pathBytes = Array(path.utf8)
            let size = UInt32(entryData.count)
            let crc: UInt32 = entryData.withUnsafeBytes { ptr -> UInt32 in
                guard let base = ptr.baseAddress else { return 0 }
                return UInt32(zlib.crc32(0, base.assumingMemoryBound(to: Bytef.self), uInt(entryData.count)) & 0xFFFFFFFF)
            }
            let localOffset = UInt32(archive.count)
            centralHeaders.append((offset: localOffset, path: pathBytes, crc: crc, size: size))

            // Local file header
            archive.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            archive.append(uint16LE: 0x0014)
            archive.append(uint16LE: 0x0000)
            archive.append(uint16LE: 0x0000) // stored
            archive.append(uint16LE: 0x0000)
            archive.append(uint16LE: 0x0000)
            archive.append(uint32LE: crc)
            archive.append(uint32LE: size)
            archive.append(uint32LE: size)
            archive.append(uint16LE: UInt16(pathBytes.count))
            archive.append(uint16LE: 0x0000)
            archive.append(contentsOf: pathBytes)
            archive.append(entryData)
        }

        let centralDirOffset = UInt32(archive.count)

        for entry in centralHeaders {
            archive.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            archive.append(uint16LE: 0x0014)
            archive.append(uint16LE: 0x0014)
            archive.append(uint16LE: 0x0000)
            archive.append(uint16LE: 0x0000)
            archive.append(uint16LE: 0x0000)
            archive.append(uint16LE: 0x0000)
            archive.append(uint32LE: entry.crc)
            archive.append(uint32LE: entry.size)
            archive.append(uint32LE: entry.size)
            archive.append(uint16LE: UInt16(entry.path.count))
            archive.append(uint16LE: 0x0000)
            archive.append(uint16LE: 0x0000)
            archive.append(uint16LE: 0x0000)
            archive.append(uint16LE: 0x0000)
            archive.append(uint32LE: 0x00000000)
            archive.append(uint32LE: entry.offset)
            archive.append(contentsOf: entry.path)
        }

        let centralDirSize = UInt32(archive.count) - centralDirOffset
        let entryCount     = UInt16(entries.count)

        archive.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        archive.append(uint16LE: 0x0000)
        archive.append(uint16LE: 0x0000)
        archive.append(uint16LE: entryCount)
        archive.append(uint16LE: entryCount)
        archive.append(uint32LE: centralDirSize)
        archive.append(uint32LE: centralDirOffset)
        archive.append(uint16LE: 0x0000)

        return archive
    }

    // MARK: - Helpers

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

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

    // Active tool label shown in create mode
    @ViewBuilder
    private var activeToolBadge: some View {
        let label: String = {
            switch vectorStore.activeTool {
            case .point:    return "Point"
            case .polyline: return "Line"
            case .zigzag:   return "Zigzag"
            case .polygon:  return "Polygon"
            case .circle:   return "Circle"
            case .none:     return ""
            }
        }()
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RutTheme.amber)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var zigzagWidthPicker: some View {
        HStack(spacing: 4) {
            Text("Width:")
                .font(.system(size: 11))
                .foregroundColor(RutTheme.textMuted)
            ForEach([15.0, 25.0, 50.0], id: \.self) { w in
                let sel = vectorStore.zigzagWidth == w
                Button("\(Int(w))m") {
                    vectorStore.zigzagWidth = w
                }
                .font(.system(size: 12, weight: sel ? .bold : .regular))
                .foregroundColor(sel ? .black : RutTheme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(sel ? RutTheme.amber : RutTheme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                    sel ? RutTheme.amber : RutTheme.border, lineWidth: 1))
                .buttonStyle(.plain)
            }
        }
    }

    private var pointToolButton: some View {
        let isActive = vectorStore.activeTool == .point
        return Button {
            vectorStore.activeTool = .point
        } label: {
            VectorPointIconView(
                icon: .circle,
                color: isActive ? .black : RutTheme.text,
                size: 16
            )
            .frame(width: 32, height: 28)
            .background(isActive ? RutTheme.amber : RutTheme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                isActive ? RutTheme.amber : RutTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
        case .zigzag:
            switch vectorStore.zigzagWidth {
            case 50: base = "RLED"
            case 25: base = "GLED"
            default: base = "SLED"
            }
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
