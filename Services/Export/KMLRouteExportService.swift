import Foundation

/// Export routes as KML. One file per route.
/// Each route becomes top-level Point Placemarks (for named import round-trip)
/// plus a LineString Placemark (for visual display in Google Earth/Maps).
/// NOTE: KML coordinates are lon,lat,alt (opposite of GPX).
struct KMLRouteExportService: RouteExporting {
    let id = "kml-route"
    let displayName = "KML Route (.kml)"
    let supportedExtensions = ["kml"]

    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile] {
        let routesToExport = selectedRoutes.isEmpty ? document.routes : selectedRoutes
        guard !routesToExport.isEmpty else { return [] }

        let airportDict = Dictionary(uniqueKeysWithValues:
            document.userAirports.map { ($0.id, $0) }
        )
        let navaidDict = Dictionary(uniqueKeysWithValues:
            document.userNavaids.map { ($0.id, $0) }
        )
        let wpDict = Dictionary(uniqueKeysWithValues:
            document.userWaypoints.map { ($0.id, $0) }
        )

        var results: [ExportedFile] = []

        for route in routesToExport {
            var seen: Set<String> = []
            var uniquePoints: [(id: String, lat: Double, lon: Double, ele: Double)] = []
            var orderedIds: [String] = []

            for ref in route.pointRefs {
                guard let info = pointInfo(for: ref, airports: airportDict,
                                           navaids: navaidDict, waypoints: wpDict)
                else { continue }
                orderedIds.append(info.id)
                if seen.insert(info.id).inserted {
                    uniquePoints.append(info)
                }
            }

            guard !orderedIds.isEmpty else { continue }

            let xml = buildKMLXML(route: route, uniquePoints: uniquePoints, orderedIds: orderedIds)
            let filename = sanitizedFilename(from: route.name, ext: "kml")
            let data = xml.data(using: .utf8) ?? Data()
            results.append(ExportedFile(filename: filename, data: data))
        }

        return results
    }

    // MARK: - Helpers

    private func pointInfo(
        for ref: RoutePointRef,
        airports: [String: UserAirport],
        navaids: [String: UserNavaid],
        waypoints: [String: UserWaypoint]
    ) -> (id: String, lat: Double, lon: Double, ele: Double)? {
        switch ref.kind {
        case .userWaypoint:
            guard let wp = waypoints[ref.refId] else { return nil }
            return (id: wp.id, lat: wp.latitude, lon: wp.longitude, ele: wp.elevation)
        case .userAirport, .systemAirport:
            guard let ap = airports[ref.refId] else { return nil }
            return (id: ap.id, lat: ap.latitude, lon: ap.longitude, ele: 0)
        case .userNavaid, .systemNavaid:
            guard let nv = navaids[ref.refId] else { return nil }
            return (id: nv.id, lat: nv.latitude, lon: nv.longitude, ele: 0)
        }
    }

    private func buildKMLXML(
        route: Route,
        uniquePoints: [(id: String, lat: Double, lon: Double, ele: Double)],
        orderedIds: [String]
    ) -> String {
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.minimumFractionDigits = 6
        fmt.maximumFractionDigits = 6
        func c(_ v: Double) -> String { fmt.string(from: NSNumber(value: v)) ?? String(format: "%.6f", v) }

        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n"
        s += "  <Document>\n"
        s += "    <name>\(escapeXML(route.name))</name>\n"

        // One Point Placemark per unique point (for named import round-trip)
        let ptDict = Dictionary(uniqueKeysWithValues: uniquePoints.map { ($0.id, $0) })
        for pt in uniquePoints {
            s += "    <Placemark>\n"
            s += "      <name>\(escapeXML(pt.id))</name>\n"
            s += "      <Point><coordinates>\(c(pt.lon)),\(c(pt.lat)),\(c(pt.ele))</coordinates></Point>\n"
            s += "    </Placemark>\n"
        }

        // LineString for visual display in Google Earth/Maps
        s += "    <Placemark>\n"
        s += "      <name>\(escapeXML(route.name))</name>\n"
        s += "      <LineString>\n"
        s += "        <coordinates>"
        let coordStrings = orderedIds.compactMap { id -> String? in
            guard let pt = ptDict[id] else { return nil }
            return "\(c(pt.lon)),\(c(pt.lat)),\(c(pt.ele))"
        }
        s += coordStrings.joined(separator: " ")
        s += "</coordinates>\n"
        s += "      </LineString>\n"
        s += "    </Placemark>\n"

        s += "  </Document>\n"
        s += "</kml>\n"
        return s
    }

    private func sanitizedFilename(from name: String, ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|:\"<>")
        let base = name.isEmpty ? "route" : name
        let cleaned = base.components(separatedBy: invalid).joined(separator: "_")
        return cleaned + "." + ext
    }

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
