import Foundation
import CoreLocation

/// Import GPX 1.1 files. Supports <wpt>, <rte>/<rtept>, and <trk>/<trkseg>/<trkpt>.
class GPXImportService: NSObject, RouteImporting, XMLParserDelegate {

    let supportedExtensions = ["gpx"]

    // --- Parse state ---
    private var currentElement = ""
    private var currentChars = ""

    // Temp for current point (wpt / rtept / trkpt)
    private var tempLat: Double?
    private var tempLon: Double?
    private var tempName = ""
    private var tempEle: Double?

    // Deduplication: name → UserWaypoint
    private var waypointsByName: [String: UserWaypoint] = [:]
    private var wptCounter = 1

    // Parsed routes (rte and trk both produce a Route)
    private var routes: [Route] = []

    // Building the current route
    private var currentRouteName = ""
    private var currentRoutePoints: [RoutePointRef] = []
    private var inRoute = false   // inside <rte>
    private var inTrack = false   // inside <trk>

    // Standalone <wpt> elements (defined outside rte/trk)
    private var standaloneWaypoints: [UserWaypoint] = []

    func importDocument(from url: URL) throws -> NavigationDocument {
        // Reset state
        currentElement = ""; currentChars = ""
        tempLat = nil; tempLon = nil; tempName = ""; tempEle = nil
        waypointsByName = [:]
        wptCounter = 1
        routes = []
        currentRouteName = url.deletingPathExtension().lastPathComponent
        currentRoutePoints = []
        inRoute = false; inTrack = false
        standaloneWaypoints = []

        // 1. Read file (same robust pattern as FPLImportService)
        var contentString = ""
        do {
            var usedEnc: UInt = 0
            contentString = try NSString(contentsOf: url, usedEncoding: &usedEnc) as String
        } catch {
            contentString = (try? String(contentsOf: url, encoding: .utf8))
                ?? ((try? String(contentsOf: url, encoding: .isoLatin1)) ?? "")
        }

        guard !contentString.isEmpty else {
            throw RutError.importFailed("Could not read GPX file content.")
        }

        // 2. Strip encoding attribute and xmlns so XMLParser handles tags simply
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
            throw RutError.importFailed("GPX XML parsing failed: \(msg)")
        }
    }

    private func buildDocument() -> NavigationDocument {
        // Standalone waypoints that are NOT already referenced by a route
        // are still imported so the user can see them.
        let allWaypoints = Array(waypointsByName.values)

        return NavigationDocument(
            createdAt: Date(),
            routes: routes,
            userAirports: [],
            userNavaids: [],
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
        case "wpt", "rtept", "trkpt":
            tempLat = attributeDict["lat"].flatMap { Double($0) }
            tempLon = attributeDict["lon"].flatMap { Double($0) }
            tempName = ""
            tempEle = nil

        case "rte":
            inRoute = true
            currentRouteName = ""
            currentRoutePoints = []

        case "trk":
            inTrack = true
            currentRouteName = ""
            currentRoutePoints = []

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentChars += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let content = currentChars.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "name":
            if !content.isEmpty { tempName = content }

        case "ele":
            tempEle = Double(content)

        case "wpt":
            // Standalone waypoint (outside rte/trk)
            if let lat = tempLat, let lon = tempLon {
                let wp = makeOrReuseWaypoint(name: tempName, lat: lat, lon: lon, ele: tempEle)
                standaloneWaypoints.append(wp)
            }

        case "rtept", "trkpt":
            if let lat = tempLat, let lon = tempLon {
                let wp = makeOrReuseWaypoint(name: tempName, lat: lat, lon: lon, ele: tempEle)
                currentRoutePoints.append(RoutePointRef(kind: .userWaypoint, refId: wp.id))
            }

        case "rte":
            let name = sanitizeRouteName(currentRouteName)
            let route = Route(routeId: UUID().uuidString, name: name, pointRefs: currentRoutePoints)
            routes.append(route)
            inRoute = false
            currentRouteName = ""
            currentRoutePoints = []

        case "trk":
            let name = sanitizeRouteName(currentRouteName)
            let route = Route(routeId: UUID().uuidString, name: name, pointRefs: currentRoutePoints)
            routes.append(route)
            inTrack = false
            currentRouteName = ""
            currentRoutePoints = []

        // <name> inside <rte> or <trk> sets the route name (before any rtept/trkpt)
        default:
            break
        }

        // After processing rte/trk name tag we need to capture it for the route.
        // We do this by checking: if we are inside a route/track and the
        // *parent* context name-element just closed, capture it.
        if elementName == "name" && !content.isEmpty {
            if (inRoute || inTrack) && currentRoutePoints.isEmpty {
                // Name element at route/track level (before any points)
                currentRouteName = content
            }
        }

        currentElement = ""
    }

    // MARK: - Helpers

    private func makeOrReuseWaypoint(name: String, lat: Double, lon: Double, ele: Double?) -> UserWaypoint {
        let finalName = name.isEmpty ? nextWptName() : name

        if let existing = waypointsByName[finalName] {
            return existing
        }

        let wp = UserWaypoint(
            id: finalName,
            name: finalName,
            type: finalName.hasPrefix("WPT") ? .wpt : .custom,
            latitude: lat,
            longitude: lon,
            elevation: ele ?? 0
        )
        waypointsByName[finalName] = wp
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
