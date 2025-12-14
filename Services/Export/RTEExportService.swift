import Foundation

/// Very simple Garmin-style RTE exporter.
/// We use a plain text format:
///   ROUTE,<name>
///   POINT,<id>,<lat>,<lon>
/// one file per route.
struct RTEExportService: RouteExporting {
    let id = "rte"
    let displayName = "Garmin RTE (.rte)"
    let supportedExtensions = ["rte"]
    
    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile] {
        let routesToExport = selectedRoutes.isEmpty ? document.routes : selectedRoutes
        guard !routesToExport.isEmpty else { return [] }
        
        // Lookups
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
            var lines: [String] = []
            lines.append("ROUTE,\(route.name)")
            
            for ref in route.pointRefs {
                if let p = coord(for: ref,
                                 airports: airportDict,
                                 navaids: navaidDict,
                                 waypoints: wpDict) {
                    lines.append("POINT,\(p.id),\(p.lat),\(p.lon)")
                }
            }
            
            guard lines.count > 1 else { continue }
            
            let text = lines.joined(separator: "\n") + "\n"
            let filename = sanitizedFilename(from: route.name, ext: "rte")
            let data = text.data(using: .utf8) ?? Data()
            results.append(ExportedFile(filename: filename, data: data))
        }
        
        return results
    }
    
    private func coord(
        for ref: RoutePointRef,
        airports: [String: UserAirport],
        navaids: [String: UserNavaid],
        waypoints: [String: UserWaypoint]
    ) -> (id: String, lat: Double, lon: Double)? {
        switch ref.kind {
        case .userWaypoint:
            guard let wp = waypoints[ref.refId] else { return nil }
            return (id: wp.id, lat: wp.latitude, lon: wp.longitude)
        case .userAirport, .systemAirport:
            guard let ap = airports[ref.refId] else { return nil }
            return (id: ap.id, lat: ap.latitude, lon: ap.longitude)
        case .userNavaid, .systemNavaid:
            guard let nv = navaids[ref.refId] else { return nil }
            return (id: nv.id, lat: nv.latitude, lon: nv.longitude)
        }
    }
    
    private func sanitizedFilename(from name: String, ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|:\"<>")
        let base = name.isEmpty ? "route" : name
        let cleaned = base
            .components(separatedBy: invalid)
            .joined(separator: "_")
        return cleaned + "." + ext
    }
}
