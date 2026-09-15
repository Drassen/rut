import Foundation
import zlib

// MARK: - KMZImportService
// Extracts doc.kml from a KMZ (ZIP) archive and parses it into VectorLayers.

final class KMZImportService: NSObject, RouteImporting, XMLParserDelegate {

    let supportedExtensions = ["kmz"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        try importDocumentWithWarnings(from: url).0
    }

    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String]) {
        let data = try Data(contentsOf: url)
        let kmlData = try Self.extractFirstKML(from: data)
        let defaultName = url.deletingPathExtension().lastPathComponent
        let (layers, warnings) = try KMLVectorParser.parseWithWarnings(kmlData: kmlData, defaultLayerName: defaultName)
        var doc = NavigationDocument()
        doc.vectorLayers = layers
        return (doc, warnings)
    }

    // MARK: - ZIP extraction

    /// Entry sizes are read from the central directory, not the local file header:
    /// when general-purpose flag bit 3 (data descriptor) is set — as in KMZ files
    /// written by ArcGIS Earth and other streaming zip writers — the local header
    /// stores 0 for both sizes and the real values follow the compressed data.
    static func extractFirstKML(from zipData: Data) throws -> Data {
        let bytes = zipData

        guard let eocd = findEndOfCentralDirectory(bytes) else {
            throw RutError.importFailed("KMZ: not a valid ZIP archive")
        }
        let entryCount = Int(read16LE(bytes, at: eocd + 10))
        var offset     = Int(read32LE(bytes, at: eocd + 16))

        for _ in 0..<entryCount {
            // Central directory file header signature PK\x01\x02
            guard offset + 46 <= bytes.count, read32LE(bytes, at: offset) == 0x0201_4B50 else { break }

            let method           = read16LE(bytes, at: offset + 10)
            let compressedSize   = Int(read32LE(bytes, at: offset + 20))
            let uncompressedSize = Int(read32LE(bytes, at: offset + 24))
            let fileNameLen      = Int(read16LE(bytes, at: offset + 28))
            let extraLen         = Int(read16LE(bytes, at: offset + 30))
            let commentLen       = Int(read16LE(bytes, at: offset + 32))
            let localOffset      = Int(read32LE(bytes, at: offset + 42))

            let nameStart = offset + 46
            let nameEnd   = nameStart + fileNameLen
            guard nameEnd <= bytes.count else { break }
            let fileName = String(data: bytes[nameStart..<nameEnd], encoding: .utf8) ?? ""
            offset = nameEnd + extraLen + commentLen

            guard fileName.lowercased().hasSuffix(".kml") else { continue }

            // Local header name/extra lengths may differ from the central directory copy
            guard localOffset + 30 <= bytes.count, read32LE(bytes, at: localOffset) == 0x0403_4B50 else {
                throw RutError.importFailed("KMZ: corrupt local header for \(fileName)")
            }
            let dataStart = localOffset + 30
                + Int(read16LE(bytes, at: localOffset + 26))
                + Int(read16LE(bytes, at: localOffset + 28))
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= bytes.count else {
                throw RutError.importFailed("KMZ: \(fileName) is truncated")
            }

            let entryData = Data(bytes[dataStart..<dataEnd])
            switch method {
            case 0:  return entryData                                             // Stored
            case 8:  return try rawInflate(entryData, expectedSize: uncompressedSize) // Deflated
            default: throw RutError.importFailed("Unsupported ZIP compression method \(method) in KMZ")
            }
        }

        throw RutError.importFailed("No KML file found inside KMZ archive")
    }

    /// Scans backwards for the End Of Central Directory signature PK\x05\x06
    /// (22-byte record followed by an optional comment of up to 65535 bytes).
    private static func findEndOfCentralDirectory(_ bytes: Data) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowest = max(0, bytes.count - 22 - 65535)
        for i in stride(from: bytes.count - 22, through: lowest, by: -1)
            where read32LE(bytes, at: i) == 0x0605_4B50 {
            return i
        }
        return nil
    }

    private static func rawInflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard !compressed.isEmpty, expectedSize > 0 else {
            throw RutError.importFailed("KMZ: empty KML entry")
        }
        var output = Data(count: expectedSize)
        var result = Z_OK
        var produced = 0

        compressed.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                var stream = z_stream()
                stream.next_in  = UnsafeMutablePointer(mutating: inBuf.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(expectedSize)

                // windowBits = -15 → raw deflate (no zlib/gzip header)
                inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                result = inflate(&stream, Z_FINISH)
                produced = Int(stream.total_out)
                inflateEnd(&stream)
            }
        }

        guard result == Z_STREAM_END else {
            throw RutError.importFailed("KMZ inflate failed (zlib code \(result))")
        }
        return output.prefix(produced)
    }

    // MARK: - Little-endian readers

    private static func read16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset+1]) << 8
    }
    private static func read32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset+1]) << 8 |
        UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24
    }
}

// MARK: - KMZNavigationImportService
// Imports a KMZ as navigation data by running KMLImportService on its doc.kml.
// Not registered by extension — selected via the "Navigation Data" import choice.

final class KMZNavigationImportService: RouteImporting {

    let supportedExtensions: [String] = []
    private let standalonePointKind: KMLImportService.StandalonePointKind

    init(standalonePointKind: KMLImportService.StandalonePointKind = .waypoint) {
        self.standalonePointKind = standalonePointKind
    }

    func importDocument(from url: URL) throws -> NavigationDocument {
        try importDocumentWithWarnings(from: url).0
    }

    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String]) {
        let kmlData = try KMZImportService.extractFirstKML(from: Data(contentsOf: url))
        return try KMLImportService(standalonePointKind: standalonePointKind).importDocumentWithWarnings(
            kmlData: kmlData,
            documentName: url.deletingPathExtension().lastPathComponent
        )
    }
}

// MARK: - KMLVectorParser
// Parses KML 2.2 into [VectorLayer]. Folder → layer, Placemark → shape.

final class KMLVectorParser: NSObject, XMLParserDelegate {

    static func parse(kmlData: Data, defaultLayerName: String) throws -> [VectorLayer] {
        try parseWithWarnings(kmlData: kmlData, defaultLayerName: defaultLayerName).0
    }

    /// Parses KML into layers, plus one line per placemark that could not be read or lost data.
    static func parseWithWarnings(kmlData: Data, defaultLayerName: String) throws -> ([VectorLayer], [String]) {
        // Strip xmlns to simplify parsing
        var text = String(data: kmlData, encoding: .utf8) ?? String(data: kmlData, encoding: .isoLatin1) ?? ""
        text = text.replacingOccurrences(of: " xmlns=\"[^\"]+\"", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: " encoding=\"[^\"]+\"", with: "", options: .regularExpression)

        guard let cleanData = text.data(using: .utf8) else {
            throw RutError.importFailed("KMZ: could not re-encode KML as UTF-8")
        }

        let parser = KMLVectorParser(defaultName: defaultLayerName)
        let xmlParser = XMLParser(data: cleanData)
        xmlParser.delegate = parser
        xmlParser.shouldProcessNamespaces = false
        guard xmlParser.parse() else {
            throw RutError.importFailed("KMZ: KML XML parse error: \(xmlParser.parserError?.localizedDescription ?? "unknown")")
        }
        return (parser.result(), parser.warnings)
    }

    // Placemarks that could not be read or lost data, with the reason
    private(set) var warnings: [String] = []
    private var pmGeometryCount = 0
    private var pmHoleCount = 0
    private var pmUnreadableCoordinates = 0

    // MARK: - State

    private let defaultLayerName: String

    // Layer stack: [root…, current]
    private var layerStack: [VectorLayer] = []

    // Current placemark being built
    private var inPlacemark = false
    private var pmName = ""
    private var pmStyle = VectorStyle()
    private var pmGeometry: VectorGeometry? = nil

    // Current geometry context
    private var inPoint = false
    private var inLineString = false
    private var inPolygon = false
    private var inOuterBoundary = false
    private var inLinearRing = false
    private var inCoordinates = false

    // Current style context
    private var inStyle = false
    private var inLineStyle = false
    private var inPolyStyle = false
    private var inIconStyle = false

    // Accumulated text
    private var chars = ""

    // Temp values
    private var coordsBuf = ""
    private var strokeColor = VectorStyle().strokeColor
    private var fillColor   = VectorStyle().fillColor
    private var strokeWidth = VectorStyle().strokeWidth

    // Placemarks at Document level (no Folder) go into a synthetic root layer
    private var rootShapes: [VectorShape] = []
    // Completed top-level layers (Folder children of Document)
    private var topLayers: [VectorLayer] = []

    init(defaultName: String) {
        self.defaultLayerName = defaultName
    }

    func result() -> [VectorLayer] {
        var layers = topLayers
        if !rootShapes.isEmpty {
            let root = VectorLayer(name: defaultLayerName, shapes: rootShapes)
            layers.insert(root, at: 0)
        }
        return layers
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        chars = ""
        switch elementName {
        case "Folder":
            layerStack.append(VectorLayer(name: ""))
        case "Placemark":
            inPlacemark = true
            pmName = ""; pmStyle = VectorStyle(); pmGeometry = nil
            inPoint = false; inLineString = false; inPolygon = false
            coordsBuf = ""
            strokeColor = VectorStyle().strokeColor
            fillColor   = VectorStyle().fillColor
            strokeWidth = VectorStyle().strokeWidth
            pmGeometryCount = 0; pmHoleCount = 0; pmUnreadableCoordinates = 0
        case "Point":       inPoint = true; pmGeometryCount += 1
        case "LineString":  inLineString = true; pmGeometryCount += 1
        case "Polygon":     inPolygon = true; pmGeometryCount += 1
        case "innerBoundaryIs": pmHoleCount += 1
        case "outerBoundaryIs": inOuterBoundary = true
        case "LinearRing":  inLinearRing = true
        case "coordinates": inCoordinates = true; coordsBuf = ""
        case "Style":       inStyle = true
        case "LineStyle":   inLineStyle = true
        case "PolyStyle":   inPolyStyle = true
        case "IconStyle":   inIconStyle = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        chars += string
        if inCoordinates { coordsBuf += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let content = chars.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "Folder":
            guard var layer = layerStack.popLast() else { break }
            if layer.name.isEmpty { layer.name = "Layer" }
            if layerStack.isEmpty {
                topLayers.append(layer)
            } else {
                layerStack[layerStack.count - 1].children.append(layer)
            }

        case "name":
            if !content.isEmpty {
                if inPlacemark {
                    pmName = content
                } else if !layerStack.isEmpty {
                    layerStack[layerStack.count - 1].name = content
                }
            }

        case "visibility":
            if !inPlacemark, !layerStack.isEmpty {
                layerStack[layerStack.count - 1].isVisible = (content != "0")
            }

        case "coordinates":
            inCoordinates = false

        case "Point":
            if inPlacemark, let (lat, lon) = parseSingle(coordsBuf) {
                pmGeometry = .point(lat: lat, lon: lon)
            }
            inPoint = false

        case "LineString":
            if inPlacemark {
                let pts = parseMulti(coordsBuf)
                if !pts.isEmpty { pmGeometry = .polyline(coordinates: pts) }
            }
            inLineString = false

        case "outerBoundaryIs": inOuterBoundary = false
        case "LinearRing":      inLinearRing = false

        case "Polygon":
            // geometry already set when we hit the coordinates inside outerBoundaryIs
            inPolygon = false

        case "color":
            // KML color: AABBGGRR
            if inLineStyle  { strokeColor = kmlColorToHex(content) }
            if inPolyStyle  { fillColor   = kmlColorToHexWithAlpha(content) }

        case "width":
            if inLineStyle, let w = Double(content) { strokeWidth = w }

        case "LineStyle": inLineStyle = false
        case "PolyStyle": inPolyStyle = false
        case "IconStyle": inIconStyle = false
        case "Style":     inStyle = false

        case "Placemark":
            let label = pmName.isEmpty ? "(unnamed)" : pmName
            if inPlacemark {
                if pmUnreadableCoordinates > 0 {
                    warnings.append("Placemark '\(label)': \(pmUnreadableCoordinates) coordinate(s) could not be read")
                }
                if pmGeometryCount > 1 {
                    warnings.append("Placemark '\(label)' has \(pmGeometryCount) geometries; only the last one is imported")
                }
                if pmHoleCount > 0 && pmGeometry != nil {
                    warnings.append("Placemark '\(label)': \(pmHoleCount) hole(s) in the polygon not imported")
                }
                if pmGeometry == nil {
                    warnings.append("Placemark '\(label)': no readable geometry; skipped")
                }
            }
            guard inPlacemark, let geo = pmGeometry else { inPlacemark = false; break }
            var style = VectorStyle()
            style.strokeColor = strokeColor
            style.fillColor   = fillColor
            style.strokeWidth = max(0.5, strokeWidth)
            let shape = VectorShape(name: pmName.isEmpty ? "Shape" : pmName,
                                    geometry: geo, style: style)
            if layerStack.isEmpty {
                rootShapes.append(shape)
            } else {
                layerStack[layerStack.count - 1].shapes.append(shape)
            }
            inPlacemark = false

        default: break
        }

        // Handle polygon outer ring coordinates
        if elementName == "coordinates" && inPolygon && inOuterBoundary {
            let pts = parseMulti(coordsBuf)
            if !pts.isEmpty { pmGeometry = .polygon(coordinates: pts) }
        }

        chars = ""
    }

    // MARK: - Coordinate parsing (KML: lon,lat,alt)

    private func parseSingle(_ raw: String) -> (Double, Double)? {
        let first = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first ?? raw
        let parts = first.components(separatedBy: ",")
        guard parts.count >= 2,
              let lon = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lat = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (lat, lon)
    }

    private func parseMulti(_ raw: String) -> [[Double]] {
        var points: [[Double]] = []
        for triple in raw.components(separatedBy: .whitespacesAndNewlines) {
            let t = triple.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let p = t.components(separatedBy: ",")
            guard p.count >= 2, let lon = Double(p[0]), let lat = Double(p[1]) else {
                pmUnreadableCoordinates += 1
                continue
            }
            points.append([lat, lon])
        }
        return points
    }

    // MARK: - KML color conversion: AABBGGRR

    /// Returns #RRGGBB (alpha discarded) — used for stroke colors.
    private func kmlColorToHex(_ kml: String) -> String {
        let s = kml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 8 else { return VectorStyle().strokeColor }
        let bb = String(s.dropFirst(2).prefix(2))
        let gg = String(s.dropFirst(4).prefix(2))
        let rr = String(s.dropFirst(6).prefix(2))
        return "#\(rr)\(gg)\(bb)"
    }

    /// Returns #RRGGBBAA (alpha preserved) — used for fill colors so opacity round-trips.
    private func kmlColorToHexWithAlpha(_ kml: String) -> String {
        let s = kml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 8 else { return VectorStyle().fillColor }
        let aa = String(s.prefix(2))
        let bb = String(s.dropFirst(2).prefix(2))
        let gg = String(s.dropFirst(4).prefix(2))
        let rr = String(s.dropFirst(6).prefix(2))
        return "#\(rr)\(gg)\(bb)\(aa)"
    }
}
