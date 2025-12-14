import Foundation

/// Export routes as Garmin / ForeFlight FPL XML.
struct FPLExportService: RouteExporting {
    let id = "fpl"
    let displayName = "ForeFlight FPL (.fpl)"
    let supportedExtensions = ["fpl"]
    
    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile] {
        let routesToExport = selectedRoutes.isEmpty ? document.routes : selectedRoutes
        guard !routesToExport.isEmpty else {
            // No routes → nothing to export, return empty list
            return []
        }
        
        // Build lookup tables for coordinates
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
            var waypointTable: [String:(id: String, type: String, lat: Double, lon: Double)] = [:]
            var orderedIds: [String] = []
            
            for ref in route.pointRefs {
                guard let info = pointInfo(for: ref,
                                           airports: airportDict,
                                           navaids: navaidDict,
                                           waypoints: wpDict)
                else { continue }
                
                if waypointTable[info.id] == nil {
                    waypointTable[info.id] = info
                }
                orderedIds.append(info.id)
            }
            
            guard !orderedIds.isEmpty else { continue }
            
            let xml = buildFPLXML(route: route,
                                  waypointTable: waypointTable,
                                  orderedIds: orderedIds)
            let filename = sanitizedFilename(from: route.name, ext: "fpl")
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
    ) -> (id: String, type: String, lat: Double, lon: Double)? {
        switch ref.kind {
        case .userWaypoint:
            guard let wp = waypoints[ref.refId] else { return nil }
            return (id: wp.id,
                    type: "USER WAYPOINT",
                    lat: wp.latitude,
                    lon: wp.longitude)
            
        case .userAirport, .systemAirport:
            guard let ap = airports[ref.refId] else { return nil }
            return (id: ap.id,
                    type: "AIRPORT",
                    lat: ap.latitude,
                    lon: ap.longitude)
            
        case .userNavaid, .systemNavaid:
            guard let nv = navaids[ref.refId] else { return nil }
            // Vi förenklar: alla navaids som VOR i FPL
            return (id: nv.id,
                    type: "VOR",
                    lat: nv.latitude,
                    lon: nv.longitude)
        }
    }
    
    private func buildFPLXML(
        route: Route,
        waypointTable: [String:(id: String, type: String, lat: Double, lon: Double)],
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
        s += "<flight-plan xmlns=\"http://www8.garmin.com/xmlschemas/FlightPlan/v1\">\n"
        s += "  <file-description>Exported from Rut</file-description>\n"
        s += "  <waypoint-table>\n"
        
        for (_, info) in waypointTable.sorted(by: { $0.key < $1.key }) {
            s += "    <waypoint>\n"
            s += "      <identifier>\(info.id)</identifier>\n"
            s += "      <type>\(info.type)</type>\n"
            s += "      <country-code></country-code>\n"
            s += "      <lat>\(coord(info.lat))</lat>\n"
            s += "      <lon>\(coord(info.lon))</lon>\n"
            s += "      <comment>\(info.id)</comment>\n"
            s += "    </waypoint>\n"
        }
        
        s += "  </waypoint-table>\n"
        s += "  <route>\n"
        s += "    <route-name>\(escapeXML(route.name))</route-name>\n"
        s += "    <route-description></route-description>\n"
        s += "    <flight-plan-index>1</flight-plan-index>\n"
        
        for id in orderedIds {
            if let info = waypointTable[id] {
                s += "    <route-point>\n"
                s += "      <waypoint-identifier>\(info.id)</waypoint-identifier>\n"
                s += "      <waypoint-type>\(info.type)</waypoint-type>\n"
                s += "      <waypoint-country-code></waypoint-country-code>\n"
                s += "    </route-point>\n"
            }
        }
        
        s += "  </route>\n"
        s += "</flight-plan>\n"
        return s
    }
    
    private func sanitizedFilename(from name: String, ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|:\"<>")
        let base = name.isEmpty ? "route" : name
        let cleaned = base
            .components(separatedBy: invalid)
            .joined(separator: "_")
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
