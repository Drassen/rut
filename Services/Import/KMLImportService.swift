import Foundation
import CoreLocation

/// Import KML 2.2 files. Supports folder-based points (Airports/Navaids/Waypoints)
/// and top-level Point Placemarks with optional LineString for routes.
/// NOTE: KML coordinates are lon,lat,alt (opposite of GPX).
class KMLImportService: NSObject, RouteImporting, XMLParserDelegate {

    let supportedExtensions = ["kml"]

    // --- Parse state ---
    private var currentElement = ""
    private var currentChars = ""

    private var currentFolderName = ""
    private var inFolder = false
    private var inPlacemark = false
    private var inPoint = false
    private var inLineString = false
    private var inCoordinates = false

    private var tempName = ""
    private var tempCoordinates = ""

    private var documentName = ""

    // Folder-based collections
    private var importedAirports: [String: UserAirport] = [:]
    private var importedNavaids: [String: UserNavaid] = [:]
    private var importedWaypoints: [String: UserWaypoint] = [:]

    // Top-level (route) collections
    private var topLevelPoints: [(name: String, lat: Double, lon: Double, ele: Double)] = []
    private var topLevelLineString: [(lat: Double, lon: Double)] = []

    private var wptCounter = 1

    func importDocument(from url: URL) throws -> NavigationDocument {
        // Reset state
        currentElement = ""; currentChars = ""
        currentFolderName = ""; inFolder = false
        inPlacemark = false; inPoint = false; inLineString = false; inCoordinates = false
        tempName = ""; tempCoordinates = ""
        documentName = url.deletingPathExtension().lastPathComponent
        importedAirports = [:]; importedNavaids = [:]; importedWaypoints = [:]
        topLevelPoints = []; topLevelLineString = []
        wptCounter = 1

        // 1. Read file (robust, same pattern as FPLImportService)
        var contentString = ""
        do {
            var usedEnc: UInt = 0
            contentString = try NSString(contentsOf: url, usedEncoding: &usedEnc) as String
        } catch {
            contentString = (try? String(contentsOf: url, encoding: .utf8))
                ?? ((try? String(contentsOf: url, encoding: .isoLatin1)) ?? "")
        }

        guard !contentString.isEmpty else {
            throw RutError.importFailed("Could not read KML file content.")
        }

        // 2. Strip encoding attribute and xmlns
        contentString = contentString.replacingOccurrences(of: " encoding=\"[^\"]+\"", with: "", options: .regularExpression)
        contentString = contentString.replacingOccurrences(of: " encoding='[^']+'", with: "", options: .regularExpression)
        contentString = contentString.replacingOccurrences(of: " xmlns=\"[^\"]+\"", with: "", options: .regularExpression)
        contentString = contentString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = contentString.data(using: .utf8) else {
            throw RutError.importFailed("Failed to create UTF-8 buffer.")
        }

        // 3. Parse
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false

        if parser.parse() {
            return buildDocument()
        } else {
            let msg = parser.parserError?.localizedDescription ?? "Unknown"
            throw RutError.importFailed("KML XML parsing failed: \(msg)")
        }
    }

    private func buildDocument() -> NavigationDocument {
        var routes: [Route] = []

        if !topLevelPoints.isEmpty {
            // Route from named Point Placemarks at document level
            var refs: [RoutePointRef] = []
            for pt in topLevelPoints {
                let wp = makeOrReuseWaypoint(name: pt.name, lat: pt.lat, lon: pt.lon, ele: pt.ele)
                refs.append(RoutePointRef(kind: .userWaypoint, refId: wp.id))
            }
            let route = Route(routeId: UUID().uuidString, name: sanitizeRouteName(documentName), pointRefs: refs)
            routes.append(route)
        } else if !topLevelLineString.isEmpty {
            // Route from LineString coordinates only – auto-name waypoints
            var refs: [RoutePointRef] = []
            for coord in topLevelLineString {
                let name = nextWptName()
                let wp = UserWaypoint(id: name, name: name, type: .wpt,
                                      latitude: coord.lat, longitude: coord.lon, elevation: 0)
                importedWaypoints[name] = wp
                refs.append(RoutePointRef(kind: .userWaypoint, refId: name))
            }
            let route = Route(routeId: UUID().uuidString, name: sanitizeRouteName(documentName), pointRefs: refs)
            routes.append(route)
        }

        let allWaypoints = Array(importedWaypoints.values)
        return NavigationDocument(
            createdAt: Date(),
            routes: routes,
            userAirports: Array(importedAirports.values),
            userNavaids: Array(importedNavaids.values),
            userWaypoints: allWaypoints,
            systemAirports: [],
            systemNavaids: []
        )
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentChars = ""

        switch elementName {
        case "Folder":
            inFolder = true
            currentFolderName = ""
        case "Placemark":
            inPlacemark = true
            tempName = ""
            tempCoordinates = ""
            inPoint = false
            inLineString = false
        case "Point":
            inPoint = true
        case "LineString":
            inLineString = true
        case "coordinates":
            inCoordinates = true
            tempCoordinates = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentChars += string
        if inCoordinates {
            tempCoordinates += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let content = currentChars.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "name":
            if !content.isEmpty {
                if inPlacemark {
                    tempName = content
                } else if inFolder {
                    currentFolderName = content
                } else {
                    // Document-level name
                    documentName = content
                }
            }

        case "coordinates":
            inCoordinates = false

        case "Point":
            inPoint = false

        case "LineString":
            inLineString = false

        case "Placemark":
            handlePlacemarkEnd()
            inPlacemark = false

        case "Folder":
            inFolder = false
            currentFolderName = ""

        default:
            break
        }

        currentElement = ""
    }

    // MARK: - Placemark handling

    private func handlePlacemarkEnd() {
        let coords = tempCoordinates.trimmingCharacters(in: .whitespacesAndNewlines)

        if inPoint || (!coords.isEmpty && !inLineString) {
            // Single coordinate: lon,lat,alt
            if let (lat, lon, ele) = parseSingleCoord(coords) {
                if inFolder {
                    let folderLC = currentFolderName.lowercased()
                    if folderLC == "airports" {
                        let ap = UserAirport(id: tempName, name: tempName,
                                             latitude: lat, longitude: lon, elevation: ele,
                                             magneticVariation: 0)
                        importedAirports[tempName] = ap
                    } else if folderLC == "navaids" {
                        let nv = UserNavaid(id: tempName, name: tempName,
                                            latitude: lat, longitude: lon, elevation: ele,
                                            magneticVariation: 0, frequency: 0)
                        importedNavaids[tempName] = nv
                    } else {
                        let wp = makeOrReuseWaypoint(name: tempName, lat: lat, lon: lon, ele: ele)
                        _ = wp // already stored in importedWaypoints
                    }
                } else {
                    // Top-level Point → potential route waypoint
                    topLevelPoints.append((name: tempName, lat: lat, lon: lon, ele: ele))
                }
            }
        } else if inLineString || coords.contains(" ") {
            // Multiple coordinates (LineString)
            if !inFolder && topLevelLineString.isEmpty {
                topLevelLineString = parseMultiCoord(coords)
            }
        }
    }

    // MARK: - Coordinate parsing

    /// Parse a single "lon,lat,alt" coordinate string → (lat, lon, ele)
    private func parseSingleCoord(_ raw: String) -> (lat: Double, lon: Double, ele: Double)? {
        // Take only the first triple (ignore whitespace-separated extras)
        let first = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? raw
        let parts = first.components(separatedBy: ",")
        guard parts.count >= 2,
              let lon = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lat = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let ele = parts.count >= 3 ? Double(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
        return (lat, lon, ele)
    }

    /// Parse space-separated "lon,lat,alt" triples → [(lat, lon)]
    private func parseMultiCoord(_ raw: String) -> [(lat: Double, lon: Double)] {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .compactMap { triple -> (lat: Double, lon: Double)? in
                let t = triple.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return nil }
                let parts = t.components(separatedBy: ",")
                guard parts.count >= 2,
                      let lon = Double(parts[0]),
                      let lat = Double(parts[1])
                else { return nil }
                return (lat, lon)
            }
    }

    // MARK: - Helpers

    @discardableResult
    private func makeOrReuseWaypoint(name: String, lat: Double, lon: Double, ele: Double) -> UserWaypoint {
        let finalName = name.isEmpty ? nextWptName() : name
        if let existing = importedWaypoints[finalName] { return existing }
        let wp = UserWaypoint(id: finalName, name: finalName,
                              type: finalName.hasPrefix("WPT") ? .wpt : .custom,
                              latitude: lat, longitude: lon, elevation: ele)
        importedWaypoints[finalName] = wp
        return wp
    }

    private func nextWptName() -> String {
        let name = String(format: "WPT%02d", wptCounter)
        wptCounter += 1
        return name
    }

    private func sanitizeRouteName(_ raw: String) -> String {
        guard !raw.isEmpty else { return "ROUTE" }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let filtered = raw.uppercased().unicodeScalars.filter { allowed.contains($0) }
        let clean = String(String.UnicodeScalarView(filtered))
        return clean.isEmpty ? "ROUTE" : clean
    }
}
