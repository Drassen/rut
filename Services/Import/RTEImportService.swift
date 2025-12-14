import Foundation

/// Placeholder for Garmin RTE import.
/// The concrete binary/text format should be implemented later.
struct RTEImportService: RouteImporting {
    let supportedExtensions = ["rte"]
    
    func importDocument(from url: URL) throws -> NavigationDocument {
        if url.pathExtension.lowercased() == "zip" {
            throw RutError.zipNotSupported
        }
        // For now, treat the file as a simple text file with "NAME LAT LON" per line.
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RutError.importFailed("RTE file is not valid UTF-8.")
        }
        
        var waypoints: [UserWaypoint] = []
        var pointRefs: [RoutePointRef] = []
        var index = 0
        
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count >= 3 {
                let name = String(parts[0])
                let lat = Double(parts[1]) ?? 0
                let lon = Double(parts[2]) ?? 0
                let wpId = String(format: "R%04d", index)
                index += 1
                let wp = UserWaypoint(
                    id: wpId,
                    name: NavigationStore.sanitizedName(name, maxLength: 15),
                    type: .wpt,
                    latitude: lat,
                    longitude: lon,
                    elevation: 0
                )
                waypoints.append(wp)
                pointRefs.append(RoutePointRef(kind: .userWaypoint, refId: wpId))
            }
        }
        
        let route = Route(
            routeId: "RTE01",
            name: "Imported RTE",
            pointRefs: pointRefs
        )
        
        let doc = NavigationDocument(
            createdAt: Date(),
            routes: [route],
            userAirports: [],
            userNavaids: [],
            userWaypoints: waypoints
        )
        return doc
    }
}
