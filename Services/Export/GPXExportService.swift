import Foundation

/// Export routes as GPX 1.1 XML. One file per route.
struct GPXExportService: RouteExporting {
    let id = "gpx"
    let displayName = "GPX (.gpx)"
    let supportedExtensions = ["gpx"]

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
            // Collect unique points in route order (deduped by id)
            var seen: Set<String> = []
            var uniquePoints: [(id: String, lat: Double, lon: Double, ele: Double)] = []
            var orderedIds: [String] = []

            for ref in route.pointRefs {
                guard let info = pointInfo(for: ref,
                                           airports: airportDict,
                                           navaids: navaidDict,
                                           waypoints: wpDict)
                else { continue }
                orderedIds.append(info.id)
                if seen.insert(info.id).inserted {
                    uniquePoints.append(info)
                }
            }

            guard !orderedIds.isEmpty else { continue }

            let xml = buildGPXXML(route: route, uniquePoints: uniquePoints, orderedIds: orderedIds)
            let filename = sanitizedFilename(from: route.name, ext: "gpx")
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

    private func buildGPXXML(
        route: Route,
        uniquePoints: [(id: String, lat: Double, lon: Double, ele: Double)],
        orderedIds: [String]
    ) -> String {
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.minimumFractionDigits = 6
        fmt.maximumFractionDigits = 6

        func coord(_ v: Double) -> String {
            fmt.string(from: NSNumber(value: v)) ?? String(format: "%.6f", v)
        }

        var s = ""
        s += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<gpx version=\"1.1\" creator=\"Rut\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"

        // One <wpt> per unique point
        for pt in uniquePoints {
            s += "  <wpt lat=\"\(coord(pt.lat))\" lon=\"\(coord(pt.lon))\">\n"
            s += "    <name>\(escapeXML(pt.id))</name>\n"
            if pt.ele > 0 {
                s += "    <ele>\(coord(pt.ele))</ele>\n"
            }
            s += "  </wpt>\n"
        }

        // One <rte> for the route
        s += "  <rte>\n"
        s += "    <name>\(escapeXML(route.name))</name>\n"

        // Build lookup for ordered output
        let ptDict = Dictionary(uniqueKeysWithValues: uniquePoints.map { ($0.id, $0) })
        for id in orderedIds {
            if let pt = ptDict[id] {
                s += "    <rtept lat=\"\(coord(pt.lat))\" lon=\"\(coord(pt.lon))\">\n"
                s += "      <name>\(escapeXML(pt.id))</name>\n"
                s += "    </rtept>\n"
            }
        }

        s += "  </rte>\n"
        s += "</gpx>\n"
        return s
    }

    private func sanitizedFilename(from name: String, ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|:\"<>")
        let base = name.isEmpty ? "route" : name
        let cleaned = base.components(separatedBy: invalid).joined(separator: "_")
        return cleaned + "." + ext
    }

    private func escapeXML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
