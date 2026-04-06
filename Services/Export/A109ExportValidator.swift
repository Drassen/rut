import Foundation

// MARK: - A109 Pre-Export Validator

/// Validates a NavigationDocument against all A109 PCMCIA format constraints
/// before any file generation takes place. Throws ExportValidationError if
/// one or more rules are violated.
struct A109ExportValidator {

    // MARK: Limits (mirrors A109PCMCIAExportService constants)
    static let maxAirports      = 100
    static let maxNavaids       = 100
    static let maxWaypoints     = 100
    static let maxRoutes        = 100
    static let maxFixesPerRoute = 40
    static let maxRouteNameChars = 10

    /// Characters encodable by the A109 6-bit scheme (after uppercasing).
    /// Anything else encodes to 0, which the helicopter displays as a space or
    /// treats as end-of-string, producing garbled or truncated identifiers.
    private static let valid6BitChars: Set<Character> = {
        var s = Set<Character>()
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ".forEach { s.insert($0) }
        "0123456789".forEach { s.insert($0) }
        s.insert("-")
        s.insert(" ")
        return s
    }()

    private static let allowedRouteChars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    )

    // MARK: - Main entry point

    static func validate(document: NavigationDocument) throws {
        var issues: [String] = []

        let airports  = document.userAirports
        let navaids   = document.userNavaids
        let waypoints = document.userWaypoints
        let routes    = document.routes

        // -- 1. Record-count limits
        if airports.count > maxAirports {
            issues.append(
                "Number of airports (\(airports.count)) exceeds the A109 limit of \(maxAirports)."
            )
        }
        if navaids.count > maxNavaids {
            issues.append(
                "Number of navaids (\(navaids.count)) exceeds the A109 limit of \(maxNavaids)."
            )
        }
        if waypoints.count > maxWaypoints {
            issues.append(
                "Number of waypoints (\(waypoints.count)) exceeds the A109 limit of \(maxWaypoints)."
            )
        }
        if routes.count > maxRoutes {
            issues.append(
                "Number of routes (\(routes.count)) exceeds the A109 limit of \(maxRoutes)."
            )
        }

        // -- 2. Duplicate IDs within each category
        for id in duplicateIDs(in: airports.map { $0.id }) {
            issues.append("Duplicate airport ID \(id). Each airport must have a unique ID.")
        }
        for id in duplicateIDs(in: navaids.map { $0.id }) {
            issues.append("Duplicate navaid ID \(id). Each navaid must have a unique ID.")
        }
        for id in duplicateIDs(in: waypoints.map { $0.id }) {
            issues.append("Duplicate waypoint ID \(id). Each waypoint must have a unique ID.")
        }

        // -- 3. Fix points per route
        let aptIDs = Set(airports.map { $0.id })
        for route in routes {
            let count = effectiveFixCount(route: route, userAirportIDs: aptIDs)
            if count > maxFixesPerRoute {
                issues.append(
                    "Route \(route.name) has \(count) fix points, " +
                    "exceeding the A109 limit of \(maxFixesPerRoute) per route."
                )
            }
        }

        // -- 4. Waypoints referenced in routes beyond the 100-slot database
        // WAYPOINT.P01 holds only the first 100 userWaypoints. Route fixes that
        // reference waypoints beyond that slot get dbIdx=0, making them
        // unresolvable in the helicopter's navigation system.
        let top100IDs = Set(waypoints.prefix(maxWaypoints).map { $0.id })
        var orphaned: [(routeName: String, wptID: String)] = []
        for route in routes {
            for ref in route.pointRefs where ref.kind == .userWaypoint {
                if !top100IDs.contains(ref.refId) {
                    orphaned.append((route.name, ref.refId))
                }
            }
        }
        if !orphaned.isEmpty {
            let sample = orphaned.prefix(5).map { $0.wptID }.joined(separator: ", ")
            let tail   = orphaned.count > 5 ? " (and \(orphaned.count - 5) more)" : ""
            issues.append(
                "Total number of waypoints across all routes exceeds \(maxWaypoints). " +
                "The following navigation points would be unresolvable in the helicopter: " +
                "\(sample)\(tail). Reduce the number of waypoints or routes."
            )
        }

        // -- 5. Duplicate waypoint IDs after 5-character truncation
        // The A109 waypoint ID field fits only 5 characters. Two waypoints whose
        // IDs share the same first 5 characters are indistinguishable in the
        // helicopter's display.
        let grouped = Dictionary(grouping: waypoints) { String($0.id.uppercased().prefix(5)) }
        for (truncated, wpts) in grouped.sorted(by: { $0.key < $1.key }) where wpts.count > 1 {
            let names = wpts.map { $0.id }.joined(separator: " and ")
            issues.append(
                "Waypoints \(names) share the same 5-character A109 identifier \(truncated), " +
                "causing ambiguous display in the helicopter."
            )
        }

        // -- 6. Invalid characters in identifiers
        // The A109 6-bit encoding only supports A-Z, 0-9, hyphen, and space.
        // Other characters (e.g. Å, Ä, Ö, punctuation) encode as zero, which
        // truncates the identifier at that position.
        for ap in airports where hasInvalidChars(ap.id) {
            issues.append(
                "Airport ID \(ap.id) contains characters that cannot be encoded in " +
                "A109 6-bit format. Only A-Z, 0-9, hyphen and space are allowed."
            )
        }
        for nv in navaids where hasInvalidChars(nv.id) {
            issues.append(
                "Navaid ID \(nv.id) contains characters that cannot be encoded in " +
                "A109 6-bit format. Only A-Z, 0-9, hyphen and space are allowed."
            )
        }
        for wp in waypoints where hasInvalidChars(wp.id) {
            issues.append(
                "Waypoint ID \(wp.id) contains characters that cannot be encoded in " +
                "A109 6-bit format. Only A-Z, 0-9, hyphen and space are allowed."
            )
        }

        // -- 7. Duplicate route names (after sanitization)
        // The A109 route name is sanitized to A-Z, 0-9, hyphen and truncated to
        // 10 characters. Two routes that produce the same sanitized name are
        // indistinguishable in the helicopter.
        let sanitized = routes.map { route -> String in
            String(
                route.name.uppercased().unicodeScalars
                    .filter { allowedRouteChars.contains($0) }
                    .prefix(maxRouteNameChars)
            )
        }
        var seenSanitized = Set<String>()
        var reportedSanitized = Set<String>()
        for (i, _) in routes.enumerated() {
            let key = sanitized[i]
            guard !key.isEmpty else { continue }
            if seenSanitized.contains(key), !reportedSanitized.contains(key) {
                reportedSanitized.insert(key)
                issues.append(
                    "Multiple routes produce the same A109 name \(key). Route names must be unique after sanitization."
                )
            }
            seenSanitized.insert(key)
        }

        // -- 8. Route names becoming empty or too long after sanitization
        // The A109 route name encoder strips all characters except A-Z, 0-9 and
        // hyphen. Names longer than 10 characters are silently truncated.
        for route in routes {
            let clean = String(
                route.name.uppercased().unicodeScalars
                    .filter { allowedRouteChars.contains($0) }
            )
            if clean.isEmpty {
                issues.append(
                    "Route \(route.name) produces an empty name after A109 " +
                    "character sanitization. Only A-Z, 0-9 and hyphen are allowed in route names."
                )
            } else if clean.count > maxRouteNameChars {
                issues.append(
                    "Route \(route.name) will be truncated to \(String(clean.prefix(maxRouteNameChars))) " +
                    "in the A109 format (maximum \(maxRouteNameChars) characters)."
                )
            }
        }

        // Throw if any issues were found
        if !issues.isEmpty {
            throw ExportValidationError(
                title: "A109 Export Cannot Proceed",
                issues: issues
            )
        }
    }

    // MARK: - Helpers

    /// Computes the number of fix points a route contributes to ROUTE.P01,
    /// applying the same exclusion logic as the exporter (pure system airports
    /// at the start and end are treated as logistical headers, not fix points).
    private static func effectiveFixCount(route: Route, userAirportIDs: Set<String>) -> Int {
        var refs = route.pointRefs
        guard !refs.isEmpty else { return 0 }

        if let first = refs.first,
           first.kind == .systemAirport,
           !userAirportIDs.contains(first.refId) {
            refs = Array(refs.dropFirst())
        }
        if let last = refs.last,
           last.kind == .systemAirport,
           !userAirportIDs.contains(last.refId) {
            refs = Array(refs.dropLast())
        }
        return refs.count
    }

    /// Returns the IDs that appear more than once in the given list, in stable order.
    private static func duplicateIDs(in ids: [String]) -> [String] {
        var seen = Set<String>()
        var reported = Set<String>()
        var result: [String] = []
        for id in ids {
            if seen.contains(id), !reported.contains(id) {
                reported.insert(id)
                result.append(id)
            }
            seen.insert(id)
        }
        return result
    }

    private static func hasInvalidChars(_ string: String) -> Bool {
        string.uppercased().contains { !valid6BitChars.contains($0) }
    }
}
