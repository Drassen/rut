import Foundation
import zlib

// MARK: - KMZImportService
// Extracts doc.kml from a KMZ (ZIP) archive and parses it into VectorLayers.

final class KMZImportService: NSObject, RouteImporting, XMLParserDelegate {

    let supportedExtensions = ["kmz"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        let data = try Data(contentsOf: url)
        let kmlData = try Self.extractFirstKML(from: data)
        let defaultName = url.deletingPathExtension().lastPathComponent
        let layers = try KMLVectorParser.parse(kmlData: kmlData, defaultLayerName: defaultName)
        var doc = NavigationDocument()
        doc.vectorLayers = layers
        return doc
    }

    // MARK: - Non-nav content detection

    /// Returns true if the KML/KMZ file contains geometry that can't be
    /// represented as navigation data (polygons, circles etc.).
    static func containsNonNavData(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let text: String
        if ext == "kml" {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        } else {
            // KMZ: extract KML first, then scan
            guard let zipData = try? Data(contentsOf: url),
                  let kmlData = try? extractFirstKML(from: zipData) else { return false }
            text = String(data: kmlData, encoding: .utf8) ?? ""
        }
        // Polygon is the key non-nav element; skip LineString/Point which map to routes
        return text.range(of: "<Polygon", options: [.caseInsensitive]) != nil
    }

    // MARK: - ZIP extraction

    static func extractFirstKML(from zipData: Data) throws -> Data {
        var offset = 0
        let bytes = zipData

        while offset + 30 <= bytes.count {
            // Look for local file header signature PK\x03\x04
            guard bytes[offset] == 0x50 && bytes[offset+1] == 0x4B &&
                  bytes[offset+2] == 0x03 && bytes[offset+3] == 0x04 else {
                offset += 1
                continue
            }

            let method          = read16LE(bytes, at: offset + 8)
            let compressedSize  = read32LE(bytes, at: offset + 18)
            let uncompressedSize = read32LE(bytes, at: offset + 22)
            let fileNameLen     = read16LE(bytes, at: offset + 26)
            let extraLen        = read16LE(bytes, at: offset + 28)

            let nameStart = offset + 30
            let nameEnd   = nameStart + Int(fileNameLen)
            let dataStart = nameEnd   + Int(extraLen)
            let dataEnd   = dataStart + Int(compressedSize)

            guard nameEnd <= bytes.count, dataEnd <= bytes.count else {
                // Malformed entry — advance past signature
                offset += 4
                continue
            }

            let fileName = String(data: bytes[nameStart..<nameEnd], encoding: .utf8) ?? ""

            if fileName.hasSuffix(".kml") || fileName.hasSuffix(".KML") {
                let entryData = bytes[dataStart..<dataEnd]
                if method == 0 {
                    // Stored — no compression
                    return Data(entryData)
                } else if method == 8 {
                    // Deflated
                    return try rawInflate(Data(entryData), expectedSize: Int(uncompressedSize))
                } else {
                    throw RutError.importFailed("Unsupported ZIP compression method \(method) in KMZ")
                }
            }

            // Skip to next entry
            offset = dataEnd
        }

        throw RutError.importFailed("No KML file found inside KMZ archive")
    }

    private static func rawInflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: max(expectedSize, 1))
        var result = Z_OK

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
                inflateEnd(&stream)
            }
        }

        guard result == Z_STREAM_END || result == Z_OK || result == Z_BUF_ERROR else {
            throw RutError.importFailed("KMZ inflate failed (zlib code \(result))")
        }
        return output
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

// MARK: - KMLVectorParser
// Parses KML 2.2 into [VectorLayer]. Folder → layer, Placemark → shape.

final class KMLVectorParser: NSObject, XMLParserDelegate {

    static func parse(kmlData: Data, defaultLayerName: String) throws -> [VectorLayer] {
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
        return parser.result()
    }

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
        case "Point":       inPoint = true
        case "LineString":  inLineString = true
        case "Polygon":     inPolygon = true
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
        raw.components(separatedBy: .whitespacesAndNewlines).compactMap { triple in
            let t = triple.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let p = t.components(separatedBy: ",")
            guard p.count >= 2,
                  let lon = Double(p[0]), let lat = Double(p[1]) else { return nil }
            return [lat, lon]
        }
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
