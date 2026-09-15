import Foundation

/// Placeholder for Garmin RTE import.
/// The concrete binary/text format should be implemented later.
struct RTEImportService: RouteImporting {
    let supportedExtensions = ["rte"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        try importDocumentWithWarnings(from: url).0
    }

    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String]) {
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
        var warnings: [String] = []
        var index = 0

        for (lineIndex, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if line.allSatisfy(\.isWhitespace) { continue }
            let parts = line.split(separator: " ")
            guard parts.count >= 3 else {
                warnings.append("Line \(lineIndex + 1): expected 'NAME LAT LON'; skipped")
                continue
            }
            // A position that cannot be read is skipped rather than placed at 0,0
            guard let lat = Double(parts[1]), let lon = Double(parts[2]) else {
                warnings.append("Line \(lineIndex + 1) '\(parts[0])': latitude/longitude could not be read ('\(parts[1])', '\(parts[2])'); skipped")
                continue
            }
            let name = String(parts[0])
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
        return (doc, warnings)
    }
}
