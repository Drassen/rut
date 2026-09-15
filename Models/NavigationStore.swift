import Foundation
import CoreLocation
import SwiftUI
import Combine

/// Central app state.
final class NavigationStore: ObservableObject {
    @Published var document: NavigationDocument = NavigationDocument()
    @Published var activeRouteId: UUID? = nil
    @AppStorage("autoRenumberWaypoints") var autoRenumberWaypoints: Bool = true

    private let logger = ErrorLogger.shared

    var routes: [Route] { document.routes }

    var activeRoute: Route? {
        guard let id = activeRouteId else { return nil }
        return document.routes.first(where: { $0.id == id })
    }

    func setActiveRoute(_ route: Route?) {
        activeRouteId = route?.id
    }

    // MARK: - Merge / delete

    /// What a merge actually added, plus every item that was skipped and why.
    struct MergeResult {
        var routes = 0
        var airports = 0
        var navaids = 0
        var waypoints = 0
        var skipped: [String] = []
        var total: Int { routes + airports + navaids + waypoints }
    }

    /// Merges an imported document into the current one. Only data that differs from what
    /// already exists is added; everything skipped is listed in the result with the reason.
    /// - Routes identical to an existing route (same name, same points) are skipped.
    /// - Airports/navaids whose ID already exists are skipped; routes use the existing point.
    /// - Waypoints identical to an existing waypoint are skipped and routes reuse the existing
    ///   one. A differing waypoint whose ID is taken gets a unique ID.
    /// - Waypoints used only by skipped routes are not imported.
    @discardableResult
    func addOrMerge(document newDoc: NavigationDocument) -> MergeResult {
        let incoming = newDoc
        var merged = document
        var result = MergeResult()

        func coordinate(of ref: RoutePointRef, in doc: NavigationDocument) -> CLLocationCoordinate2D? {
            switch ref.kind {
            case .userWaypoint:  return doc.userWaypoints.first { $0.id == ref.refId }?.coordinate
            case .userAirport:   return doc.userAirports.first { $0.id == ref.refId }?.coordinate
            case .userNavaid:    return doc.userNavaids.first { $0.id == ref.refId }?.coordinate
            case .systemAirport: return doc.systemAirports.first { $0.id == ref.refId }?.coordinate
            case .systemNavaid:  return doc.systemNavaids.first { $0.id == ref.refId }?.coordinate
            }
        }

        // --- 1. ROUTES: skip those identical to an existing route ---
        // Incoming refs may point at points already in the app (A109 ROUTE.P01), so they are
        // resolved in the incoming document first and in the existing one otherwise.
        var newRoutes: [Route] = []
        for route in incoming.routes {
            let rawName = route.name.isEmpty ? route.routeId : route.name
            let isDuplicate = merged.routes.contains { existing in
                guard Self.routeName(existing.name, matchesImported: rawName),
                      existing.pointRefs.count == route.pointRefs.count else { return false }
                return zip(existing.pointRefs, route.pointRefs).allSatisfy { e, i in
                    guard e.kind == i.kind,
                          let c1 = coordinate(of: e, in: merged),
                          let c2 = coordinate(of: i, in: incoming) ?? coordinate(of: i, in: merged)
                    else { return false }
                    return Self.sameCoordinate(c1, c2)
                }
            }
            if isDuplicate {
                result.skipped.append("Route \(rawName): identical route already exists")
            } else {
                newRoutes.append(route)
            }
        }
        let waypointsInRoutes    = Set(incoming.routes.flatMap { Self.waypointIds(in: $0) })
        let waypointsInNewRoutes = Set(newRoutes.flatMap { Self.waypointIds(in: $0) })

        // --- 2. AIRPORTS & NAVAIDS: the ID is the identity; an existing ID is never imported again ---
        for ap in incoming.userAirports {
            if let existing = merged.userAirports.first(where: { $0.id == ap.id }) {
                result.skipped.append(Self.sameAirport(existing, ap)
                    ? "Airport \(ap.id): identical airport already exists"
                    : "Airport \(ap.id): an airport with the same ID but different data already exists")
            } else {
                merged.userAirports.append(ap)
                result.airports += 1
            }
        }
        for nv in incoming.userNavaids {
            if let existing = merged.userNavaids.first(where: { $0.id == nv.id }) {
                result.skipped.append(Self.sameNavaid(existing, nv)
                    ? "Navaid \(nv.id): identical navaid already exists"
                    : "Navaid \(nv.id): a navaid with the same ID but different data already exists")
            } else {
                merged.userNavaids.append(nv)
                result.navaids += 1
            }
        }

        // --- 3. WAYPOINTS: needed if used by a new route, or standalone (used by no route) ---
        var waypointIdMap: [String: String] = [:]
        var usedWaypointIds = Set(merged.userWaypoints.map { $0.id })
        for wp in incoming.userWaypoints {
            guard !waypointsInRoutes.contains(wp.id) || waypointsInNewRoutes.contains(wp.id) else { continue }

            if let existing = merged.userWaypoints.first(where: { Self.sameWaypoint($0, wp) }) {
                waypointIdMap[wp.id] = existing.id
                result.skipped.append("Waypoint \(wp.name): identical waypoint already exists")
                continue
            }
            var newWp = wp
            if usedWaypointIds.contains(wp.id) {
                newWp.id = makeUniqueWaypointId(preferred: wp.id, used: usedWaypointIds)
                waypointIdMap[wp.id] = newWp.id
            }
            usedWaypointIds.insert(newWp.id)
            merged.userWaypoints.append(newWp)
            result.waypoints += 1
        }

        // --- 4. NEW ROUTES: remap waypoint refs, give unique names/IDs, append ---
        var routesDoc = NavigationDocument()
        routesDoc.routes = newRoutes.map { route in
            var r = route
            r.pointRefs = r.pointRefs.map { ref in
                var ref = ref
                if ref.kind == .userWaypoint, let id = waypointIdMap[ref.refId] { ref.refId = id }
                return ref
            }
            return r
        }
        normalizeImportedRouteIds(&routesDoc, existingRoutes: merged.routes)
        var newRouteIds: [UUID] = []
        for route in routesDoc.routes {
            merged.routes.append(route)
            newRouteIds.append(route.id)
            result.routes += 1
        }

        // System points
        for ap in incoming.systemAirports {
            if !merged.systemAirports.contains(where: { $0.id == ap.id }) { merged.systemAirports.append(ap) }
        }
        for nv in incoming.systemNavaids {
            if !merged.systemNavaids.contains(where: { $0.id == nv.id }) { merged.systemNavaids.append(nv) }
        }

        // --- 5. VECTORS (document copy; the map uses VectorStore, merged separately) ---
        for layer in incoming.vectorLayers where !layer.isSystem {
            if !merged.vectorLayers.contains(where: { $0.name == layer.name }) {
                merged.vectorLayers.append(layer)
            }
        }

        document = merged

        if autoRenumberWaypoints && !newRouteIds.isEmpty {
            renumberWaypoints(forRouteIds: newRouteIds)
        }

        if activeRouteId == nil, let first = merged.routes.first {
            activeRouteId = first.id
        }
        return result
    }

    // MARK: - Point type conversion

    /// User point categories that can be converted into each other.
    enum UserPointKind: String, CaseIterable, Identifiable {
        case waypoint = "WPT", navaid = "NAV", airport = "APT"
        var id: Self { self }
        var label: String {
            switch self {
            case .waypoint: return "Waypoint"
            case .navaid:   return "Navaid"
            case .airport:  return "Airport"
            }
        }
        var routeKind: RoutePointKind {
            switch self {
            case .waypoint: return .userWaypoint
            case .navaid:   return .userNavaid
            case .airport:  return .userAirport
            }
        }
    }

    /// A109 PCMCIA limit: AIRPORT.P01, NAVAID.P01 and WAYPOINT.P01 hold at most 100 records each.
    static let maxPointsPerKind = 100

    /// A user point in its converted form.
    enum UserPoint {
        case waypoint(UserWaypoint)
        case navaid(UserNavaid)
        case airport(UserAirport)

        var kind: UserPointKind {
            switch self {
            case .waypoint: return .waypoint
            case .navaid:   return .navaid
            case .airport:  return .airport
            }
        }
        var id: String {
            switch self {
            case .waypoint(let wp): return wp.id
            case .navaid(let nv):   return nv.id
            case .airport(let ap):  return ap.id
            }
        }
    }

    struct PointConversion {
        let fromKind: UserPointKind
        let fromId: String
        let target: UserPoint
    }

    private func pointIds(_ kind: UserPointKind) -> [String] {
        switch kind {
        case .waypoint: return document.userWaypoints.map { $0.id }
        case .navaid:   return document.userNavaids.map { $0.id }
        case .airport:  return document.userAirports.map { $0.id }
        }
    }

    /// Routes that reference a user point. `isEndpoint` is true when the point is the route's
    /// first or last point, which A109 exports as the logistic start/destination if it is an airport.
    func routesUsing(kind: UserPointKind, id: String) -> [(route: Route, isEndpoint: Bool)] {
        document.routes.compactMap { route in
            let positions = route.pointRefs.indices.filter {
                route.pointRefs[$0].kind == kind.routeKind && route.pointRefs[$0].refId == id
            }
            guard !positions.isEmpty else { return nil }
            let last = route.pointRefs.count - 1
            return (route, positions.contains { $0 == 0 || $0 == last })
        }
    }

    /// Checks every conversion against the state after the whole batch, before anything is
    /// changed. Returns all reasons the batch can't be done; empty means it can.
    func validateConversions(_ conversions: [PointConversion]) -> [String] {
        var problems: [String] = []
        var ids: [UserPointKind: Set<String>] = [:]
        var counts: [UserPointKind: Int] = [:]
        for kind in UserPointKind.allCases {
            let current = pointIds(kind)
            ids[kind] = Set(current)
            counts[kind] = current.count
        }
        let countsBefore = counts

        for c in conversions {
            let label = "\(c.fromKind.label) \(c.fromId)"
            let to = c.target.kind
            guard ids[c.fromKind, default: []].contains(c.fromId) else {
                problems.append("\(label): point not found")
                continue
            }
            guard to != c.fromKind else {
                problems.append("\(label): is already a \(to.label.lowercased())")
                continue
            }
            // The source leaves its list, which frees its ID there
            ids[c.fromKind, default: []].remove(c.fromId)
            counts[c.fromKind, default: 0] -= 1

            let newId = c.target.id
            if newId.isEmpty || newId != NavigationStore.sanitizedName(newId, maxLength: 5) {
                problems.append("\(label): ID \"\(newId)\" must be 1–5 characters (A–Z, 0–9, -)")
            } else if ids[to, default: []].contains(newId) {
                problems.append("\(label): a \(to.label.lowercased()) with ID \(newId) already exists")
            }
            ids[to, default: []].insert(newId)
            counts[to, default: 0] += 1
        }

        // Only kinds that grow can break the limit
        for kind in UserPointKind.allCases {
            let after = counts[kind] ?? 0
            if after > Self.maxPointsPerKind && after > (countsBefore[kind] ?? 0) {
                problems.append("\(kind.label)s: \(after) after conversion – A109 allows at most \(Self.maxPointsPerKind)")
            }
        }
        return problems
    }

    /// Converts user points between waypoint, navaid and airport. The whole batch is validated
    /// first; if anything fails, nothing is changed and the reasons are returned. Route
    /// references are rewritten to the new kind and ID, so routes keep their points.
    @discardableResult
    func convertPoints(_ conversions: [PointConversion]) -> [String] {
        let problems = validateConversions(conversions)
        guard problems.isEmpty else { return problems }

        var doc = document
        for c in conversions {
            switch c.fromKind {
            case .waypoint: doc.userWaypoints.removeAll { $0.id == c.fromId }
            case .navaid:   doc.userNavaids.removeAll { $0.id == c.fromId }
            case .airport:  doc.userAirports.removeAll { $0.id == c.fromId }
            }
            switch c.target {
            case .waypoint(let wp): doc.userWaypoints.append(wp)
            case .navaid(let nv):   doc.userNavaids.append(nv)
            case .airport(let ap):  doc.userAirports.append(ap)
            }
            for r in doc.routes.indices {
                for p in doc.routes[r].pointRefs.indices
                where doc.routes[r].pointRefs[p].kind == c.fromKind.routeKind
                   && doc.routes[r].pointRefs[p].refId == c.fromId {
                    doc.routes[r].pointRefs[p].kind = c.target.kind.routeKind
                    doc.routes[r].pointRefs[p].refId = c.target.id
                }
            }
        }
        // Single assignment: the document is never observed half-converted
        document = doc
        return []
    }

    /// Builds conversions that turn existing user points of one kind into another. ID, name,
    /// position and elevation are kept, plus magnetic variation where the target kind has it.
    /// Converted waypoints get the CUSTOM type so their ID/name is not renumbered.
    func conversions(of ids: [String], from: UserPointKind, to: UserPointKind) -> [PointConversion] {
        ids.compactMap { id in
            let name: String, lat: Double, lon: Double, elev: Double, magVar: Double
            switch from {
            case .waypoint:
                guard let wp = document.userWaypoints.first(where: { $0.id == id }) else { return nil }
                (name, lat, lon, elev, magVar) = (wp.name, wp.latitude, wp.longitude, wp.elevation, 0)
            case .navaid:
                guard let nv = document.userNavaids.first(where: { $0.id == id }) else { return nil }
                (name, lat, lon, elev, magVar) = (nv.name, nv.latitude, nv.longitude, nv.elevation, nv.magneticVariation)
            case .airport:
                guard let ap = document.userAirports.first(where: { $0.id == id }) else { return nil }
                (name, lat, lon, elev, magVar) = (ap.name, ap.latitude, ap.longitude, ap.elevation, ap.magneticVariation)
            }
            let finalName = name.isEmpty ? id : name
            let target: UserPoint
            switch to {
            case .waypoint:
                target = .waypoint(UserWaypoint(id: id, name: finalName, type: .custom,
                                                latitude: lat, longitude: lon, elevation: elev))
            case .navaid:
                target = .navaid(UserNavaid(id: id, name: finalName, latitude: lat, longitude: lon,
                                            elevation: elev, magneticVariation: magVar, frequency: 0))
            case .airport:
                target = .airport(UserAirport(id: id, name: finalName, latitude: lat, longitude: lon,
                                              elevation: elev, magneticVariation: magVar))
            }
            return PointConversion(fromKind: from, fromId: id, target: target)
        }
    }

    /// Summary of what a batch of conversions changes, shown for confirmation before converting.
    func conversionNotes(_ conversions: [PointConversion]) -> [String] {
        var routeNames = Set<String>()
        var endpointChanges = 0, frequencyLost = 0, magVarLost = 0, a109DataLost = 0
        for c in conversions {
            let to = c.target.kind
            for use in routesUsing(kind: c.fromKind, id: c.fromId) {
                routeNames.insert(use.route.name)
                if use.isEndpoint && (c.fromKind == .airport || to == .airport) { endpointChanges += 1 }
            }
            switch c.fromKind {
            case .navaid:
                guard let nv = document.userNavaids.first(where: { $0.id == c.fromId }) else { continue }
                if nv.frequency != 0 { frequencyLost += 1 }
                if to == .waypoint && nv.magneticVariation != 0 { magVarLost += 1 }
            case .airport:
                guard let ap = document.userAirports.first(where: { $0.id == c.fromId }) else { continue }
                if !ap.usage.isEmpty || !ap.longestRunway.isEmpty || !ap.rawUnknown1.isEmpty { a109DataLost += 1 }
                if to == .waypoint && ap.magneticVariation != 0 { magVarLost += 1 }
            case .waypoint:
                break
            }
        }

        var notes: [String] = []
        if !routeNames.isEmpty {
            let sorted = routeNames.sorted()
            let shown = sorted.prefix(5).joined(separator: ", ") + (sorted.count > 5 ? ", …" : "")
            notes.append("Used in \(sorted.count) route(s) (\(shown)); the routes keep their points.")
        }
        if endpointChanges > 0 {
            notes.append("\(endpointChanges) route start/destination point(s) change whether they are a logistic airport on A109 export.")
        }
        if frequencyLost > 0 { notes.append("Frequency is removed from \(frequencyLost) navaid(s).") }
        if magVarLost > 0 { notes.append("Magnetic variation is removed from \(magVarLost) point(s).") }
        if a109DataLost > 0 { notes.append("A109 airport data (usage, runway) is removed from \(a109DataLost) airport(s).") }
        return notes
    }

    /// Deletes several user points of one kind in a single change and removes them from every
    /// route that uses them. Route references are matched on kind and ID, so a waypoint and an
    /// airport that share an ID are not confused.
    func deletePoints(kind: UserPointKind, ids: Set<String>) {
        var doc = document
        switch kind {
        case .waypoint: doc.userWaypoints.removeAll { ids.contains($0.id) }
        case .navaid:   doc.userNavaids.removeAll { ids.contains($0.id) }
        case .airport:  doc.userAirports.removeAll { ids.contains($0.id) }
        }
        for r in doc.routes.indices {
            doc.routes[r].pointRefs.removeAll { $0.kind == kind.routeKind && ids.contains($0.refId) }
        }
        document = doc
    }

    // MARK: - Merge comparison helpers

    private static let coordinateTolerance = 1e-5   // degrees (~1 m)

    private static func sameCoordinate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) <= coordinateTolerance && abs(a.longitude - b.longitude) <= coordinateTolerance
    }

    private static func sameAirport(_ a: UserAirport, _ b: UserAirport) -> Bool {
        a.id == b.id && a.name == b.name && sameCoordinate(a.coordinate, b.coordinate)
            && abs(a.elevation - b.elevation) <= 0.5 && abs(a.magneticVariation - b.magneticVariation) <= 0.01
    }

    private static func sameNavaid(_ a: UserNavaid, _ b: UserNavaid) -> Bool {
        a.id == b.id && a.name == b.name && sameCoordinate(a.coordinate, b.coordinate)
            && abs(a.elevation - b.elevation) <= 0.5 && abs(a.magneticVariation - b.magneticVariation) <= 0.01
            && abs(a.frequency - b.frequency) <= 0.001
    }

    /// Managed waypoint types (WPT, IP, …) get their IDs/names regenerated when routes are
    /// renumbered, so only CUSTOM waypoints are compared by name.
    private static func sameWaypoint(_ a: UserWaypoint, _ b: UserWaypoint) -> Bool {
        a.type == b.type && sameCoordinate(a.coordinate, b.coordinate)
            && abs(a.elevation - b.elevation) <= 0.5
            && (a.type != .custom || a.name == b.name)
    }

    private static func waypointIds(in route: Route) -> [String] {
        route.pointRefs.filter { $0.kind == .userWaypoint }.map { $0.refId }
    }

    /// True if an existing (normalized) route name corresponds to an imported raw name,
    /// including the "-N" suffix added on import when the name was already taken.
    private static func routeName(_ existing: String, matchesImported raw: String) -> Bool {
        let sanitized = sanitizedName(raw, maxLength: 10)
        let base = sanitized.isEmpty ? "ROUTE" : sanitized
        if existing == base { return true }
        guard let suffix = existing.range(of: "-\\d+$", options: .regularExpression) else { return false }
        let stem = existing[..<suffix.lowerBound]
        return !stem.isEmpty && base.hasPrefix(stem)
    }

    func deleteRoute(_ route: Route) {
            // Only waypoints are cleaned up: those this route used as waypoints and no remaining
            // route uses. Airports and navaids are always kept, and nothing that wasn't in the
            // route is touched (refs are matched on kind, so a same-ID airport is not affected).
            func waypointIds(in routes: [Route]) -> Set<String> {
                Set(routes.flatMap { $0.pointRefs.filter { $0.kind == .userWaypoint }.map { $0.refId } })
            }
            let waypointIdsInDeletedRoute = waypointIds(in: [route])
            document.routes.removeAll { $0.id == route.id }
            let waypointIdsToRemove = waypointIdsInDeletedRoute.subtracting(waypointIds(in: document.routes))

            if !waypointIdsToRemove.isEmpty {
                document.userWaypoints.removeAll { waypointIdsToRemove.contains($0.id) }
            }

            if activeRouteId == route.id {
                activeRouteId = document.routes.first?.id
            }
        }

    // MARK: - Route Point Editing

    func moveRoutePoints(routeId: UUID, from: IndexSet, to: Int) {
        guard let idx = document.routes.firstIndex(where: { $0.id == routeId }) else { return }
        document.routes[idx].pointRefs.move(fromOffsets: from, toOffset: to)
    }

    func removeRoutePoints(routeId: UUID, at offsets: IndexSet) {
        guard let idx = document.routes.firstIndex(where: { $0.id == routeId }) else { return }
        document.routes[idx].pointRefs.remove(atOffsets: offsets)
    }

    func addRoutePoint(routeId: UUID, ref: RoutePointRef) {
        guard let idx = document.routes.firstIndex(where: { $0.id == routeId }) else { return }
        document.routes[idx].pointRefs.append(ref)
    }

    /// Replace the first occurrence of `replacingRefId` in the route with `newRef`,
    /// then delete `replacingRefId` from the waypoint database (it was a temp point).
    func replaceRoutePoint(routeId: UUID, replacingRefId: String, with newRef: RoutePointRef) {
        guard let rIdx = document.routes.firstIndex(where: { $0.id == routeId }) else { return }
        guard let pIdx = document.routes[rIdx].pointRefs.firstIndex(where: { $0.refId == replacingRefId }) else { return }
        document.routes[rIdx].pointRefs[pIdx] = newRef
        document.userWaypoints.removeAll { $0.id == replacingRefId }
    }

    func insertRoutePoint(routeId: UUID, at index: Int, ref: RoutePointRef) {
        guard let idx = document.routes.firstIndex(where: { $0.id == routeId }) else { return }
        let clamped = max(0, min(index, document.routes[idx].pointRefs.count))
        document.routes[idx].pointRefs.insert(ref, at: clamped)
    }

    func createEmptyRoute(named name: String) {
        let sanitized = NavigationStore.sanitizedName(name, maxLength: 15)
        let finalName = sanitized.isEmpty ? "ROUTE" : sanitized
        let used = Set(document.routes.map { $0.routeId })
        let base = makeRouteIdBase(from: finalName)
        let newRouteId = makeUniqueRouteId(base: base, used: used)
        let route = Route(routeId: newRouteId, name: finalName, pointRefs: [])
        document.routes.append(route)
    }

    func updateRouteName(_ route: Route, newName: String) {
        guard let idx = document.routes.firstIndex(where: { $0.id == route.id }) else { return }
        let sanitized = NavigationStore.sanitizedName(newName, maxLength: 15)
        document.routes[idx].name = sanitized
        let base = makeRouteIdBase(from: sanitized)
        let used = Set(document.routes.filter { $0.id != route.id }.map { $0.routeId })
        document.routes[idx].routeId = makeUniqueRouteId(base: base, used: used)
    }

    // MARK: - Update Logic (Waypoints, Airports, Navaids)

    func updateWaypoint(originalId: String,
                        newName: String,
                        newId: String,
                        type: WaypointType,
                        latitude: Double,
                        longitude: Double,
                        elevation: Double) {
        
        guard let index = document.userWaypoints.firstIndex(where: { $0.id == originalId }) else { return }
        
        var finalId = newId
        if originalId != newId {
            if document.userWaypoints.contains(where: { $0.id == newId }) {
                let used = Set(document.userWaypoints.map { $0.id })
                finalId = makeUniqueWaypointId(preferred: newId, used: used)
            }
        }

        var wp = document.userWaypoints[index]
        wp.name = NavigationStore.sanitizedName(newName, maxLength: 15)
        wp.id = finalId
        wp.type = type
        wp.latitude = latitude
        wp.longitude = longitude
        wp.elevation = elevation
        document.userWaypoints[index] = wp
        
        if originalId != finalId {
            for rIndex in 0..<document.routes.count {
                var route = document.routes[rIndex]
                var changed = false
                for pIndex in 0..<route.pointRefs.count {
                    let point = route.pointRefs[pIndex]
                    if point.kind == .userWaypoint && point.refId == originalId {
                        var newPoint = point
                        newPoint.refId = finalId
                        route.pointRefs[pIndex] = newPoint
                        changed = true
                    }
                }
                if changed { document.routes[rIndex] = route }
            }
        }
        
        if autoRenumberWaypoints {
            let affectedRouteIds = document.routes.filter { route in
                route.pointRefs.contains { $0.refId == finalId && $0.kind == .userWaypoint }
            }.map { $0.id }

            if !affectedRouteIds.isEmpty {
                renumberWaypoints(forRouteIds: affectedRouteIds)
            }
        }
    }
    
    func updateAirport(originalId: String, newId: String, newName: String,
                       latitude: Double, longitude: Double, elevation: Double, magVar: Double) {
        guard let idx = document.userAirports.firstIndex(where: { $0.id == originalId }) else { return }
        
        var finalId = newId
        if originalId != newId && document.userAirports.contains(where: { $0.id == newId }) {
            finalId = makeUniqueWaypointId(preferred: newId, used: Set(document.userAirports.map { $0.id }))
        }
        
        var ap = document.userAirports[idx]
        ap.id = finalId
        ap.name = NavigationStore.sanitizedName(newName, maxLength: 15)
        ap.latitude = latitude
        ap.longitude = longitude
        ap.elevation = elevation
        ap.magneticVariation = magVar
        document.userAirports[idx] = ap
        
        if originalId != finalId {
            updateRouteReferences(oldId: originalId, newId: finalId, kind: .userAirport)
        }
    }
    
    func updateNavaid(originalId: String, newId: String, newName: String,
                      latitude: Double, longitude: Double, elevation: Double, magVar: Double, frequency: Double) {
        guard let idx = document.userNavaids.firstIndex(where: { $0.id == originalId }) else { return }
        
        var finalId = newId
        if originalId != newId && document.userNavaids.contains(where: { $0.id == newId }) {
            finalId = makeUniqueWaypointId(preferred: newId, used: Set(document.userNavaids.map { $0.id }))
        }
        
        var nv = document.userNavaids[idx]
        nv.id = finalId
        nv.name = NavigationStore.sanitizedName(newName, maxLength: 15)
        nv.latitude = latitude
        nv.longitude = longitude
        nv.elevation = elevation
        nv.magneticVariation = magVar
        nv.frequency = frequency
        document.userNavaids[idx] = nv
        
        if originalId != finalId {
            updateRouteReferences(oldId: originalId, newId: finalId, kind: .userNavaid)
        }
    }
    
    // MARK: - Waypoint Type & Coords Updates

    func updateWaypointType(in route: Route, at indexInRoute: Int, to newType: WaypointType, customId: String? = nil) {
        guard let routeIdx = document.routes.firstIndex(where: { $0.id == route.id }) else { return }
        let pointRef = document.routes[routeIdx].pointRefs[indexInRoute]
        guard pointRef.kind == .userWaypoint else { return }
        guard let wpIdx = document.userWaypoints.firstIndex(where: { $0.id == pointRef.refId }) else { return }

        document.userWaypoints[wpIdx].type = newType

        if newType == .custom {
            if let customId, !customId.isEmpty {
                let sanitized = NavigationStore.sanitizedName(customId, maxLength: 5)
                if !sanitized.isEmpty {
                    let isTaken = document.userWaypoints.contains(where: { $0.id == sanitized && $0.id != document.userWaypoints[wpIdx].id })
                    if !isTaken {
                        let oldId = document.userWaypoints[wpIdx].id
                        document.userWaypoints[wpIdx].id = sanitized
                        updateRouteReferences(oldId: oldId, newId: sanitized, kind: .userWaypoint)
                    }
                }
            }
        }
        if autoRenumberWaypoints {
            renumberWaypoints(forRouteIds: [document.routes[routeIdx].id])
        }
    }

    func updateWaypointCoordinate(in route: Route, at indexInRoute: Int, to coordinate: CLLocationCoordinate2D) {
        guard let routeIdx = document.routes.firstIndex(where: { $0.id == route.id }) else { return }
        let pointRef = document.routes[routeIdx].pointRefs[indexInRoute]
        guard pointRef.kind == .userWaypoint else { return }
        guard let wpIdx = document.userWaypoints.firstIndex(where: { $0.id == pointRef.refId }) else { return }
        document.userWaypoints[wpIdx].latitude = coordinate.latitude
        document.userWaypoints[wpIdx].longitude = coordinate.longitude
    }
    
    private func updateRouteReferences(oldId: String, newId: String, kind: RoutePointKind) {
        for rIndex in document.routes.indices {
            var route = document.routes[rIndex]; var changed = false
            for pIndex in route.pointRefs.indices {
                let ref = route.pointRefs[pIndex]
                if ref.kind == kind && ref.refId == oldId {
                    var newRef = ref; newRef.refId = newId; route.pointRefs[pIndex] = newRef; changed = true
                }
            }
            if changed { document.routes[rIndex] = route }
        }
    }

    // MARK: - Renumbering logic

    func renumberWaypoints(forRouteIds routeIds: [UUID]) {
        var usedIds = Set(document.userWaypoints.map { $0.id })

        for routeId in routeIds {
            guard let idx = document.routes.firstIndex(where: { $0.id == routeId }) else { continue }
            renumberWaypoints(inRouteAt: idx, usedIds: &usedIds)
        }
    }

    private func renumberWaypoints(inRouteAt routeIdx: Int, usedIds: inout Set<String>) {
            let route = document.routes[routeIdx]
            
            let refsToRenumber = route.pointRefs.filter { ref in
                guard ref.kind == .userWaypoint else { return false }
                if let wp = document.userWaypoints.first(where: { $0.id == ref.refId }) {
                    return wp.type != .custom
                }
                return false
            }
            for ref in refsToRenumber { usedIds.remove(ref.refId) }
            
            var counters: [WaypointType: Int] = [:]
            var idMapping: [String: String] = [:]
            var wpMutations: [(index: Int, newId: String)] = []

            func nextCandidate(for type: WaypointType) -> String {
                let next = (counters[type] ?? 0) + 1
                counters[type] = next
                return String(format: "%@%02d", type.rawValue, next)
            }

            for ref in route.pointRefs {
                guard ref.kind == .userWaypoint else { continue }
                guard let wpIdx = document.userWaypoints.firstIndex(where: { $0.id == ref.refId }) else { continue }

                let type = document.userWaypoints[wpIdx].type
                if type == .custom { continue }

                let oldId = document.userWaypoints[wpIdx].id
                if idMapping[oldId] != nil { continue }

                var candidate = nextCandidate(for: type)
                while usedIds.contains(candidate) {
                    candidate = nextCandidate(for: type)
                }

                wpMutations.append((index: wpIdx, newId: candidate))
                idMapping[oldId] = candidate
                usedIds.insert(candidate)
            }

            guard !idMapping.isEmpty else { return }

            for m in wpMutations {
                document.userWaypoints[m.index].id = m.newId
                document.userWaypoints[m.index].name = m.newId
            }

            for rIndex in document.routes.indices {
                for pIndex in document.routes[rIndex].pointRefs.indices {
                    var ref = document.routes[rIndex].pointRefs[pIndex]
                    if ref.kind == .userWaypoint, let newId = idMapping[ref.refId] {
                        ref.refId = newId
                        document.routes[rIndex].pointRefs[pIndex] = ref
                    }
                }
            }
        }
    
    // MARK: - ID Generation Helpers

    func nextAvailableId(for type: WaypointType) -> String {
        let prefix = type.rawValue
        var counter = 1
        let usedIds = Set(document.userWaypoints.map { $0.id })
        while true {
            let candidate = String(format: "%@%02d", prefix, counter)
            if !usedIds.contains(candidate) { return candidate }
            counter += 1
        }
    }
    
    func predictRenumberedId(for originalId: String, newType: WaypointType) -> String {
        let routeToCheck = activeRoute ?? document.routes.first { r in r.pointRefs.contains { $0.refId == originalId } }
        guard let route = routeToCheck else { return nextAvailableId(for: newType) }
        
        var count = 0
        for ref in route.pointRefs {
            if ref.refId == originalId {
                let prefix = newType.rawValue
                var candidateNum = count + 1
                let allOtherIds = document.userWaypoints.filter { $0.id != originalId }.map { $0.id }
                let usedSet = Set(allOtherIds)
                
                while true {
                    let candidate = String(format: "%@%02d", prefix, candidateNum)
                    if !usedSet.contains(candidate) { return candidate }
                    candidateNum += 1
                }
            }
            if ref.kind == .userWaypoint, let wp = document.userWaypoints.first(where: { $0.id == ref.refId }), wp.type == newType {
                count += 1
            }
        }
        return nextAvailableId(for: newType)
    }

    // MARK: - Map helpers & others
    func mapPoints(for route: Route) -> [RouteMapPoint] {
        var result: [RouteMapPoint] = []
        for (idx, ref) in route.pointRefs.enumerated() {
            switch ref.kind {
            case .userAirport: if let ap = document.userAirports.first(where: { $0.id == ref.refId }) { result.append(RouteMapPoint(coordinate: ap.coordinate, name: ap.id, indexInRoute: idx + 1, kind: .userAirport)) }
            case .userNavaid: if let nv = document.userNavaids.first(where: { $0.id == ref.refId }) { result.append(RouteMapPoint(coordinate: nv.coordinate, name: nv.id, indexInRoute: idx + 1, kind: .userNavaid)) }
            case .userWaypoint: if let wp = document.userWaypoints.first(where: { $0.id == ref.refId }) { result.append(RouteMapPoint(coordinate: wp.coordinate, name: wp.id, indexInRoute: idx + 1, kind: .userWaypoint)) }
            case .systemAirport: if let ap = document.systemAirports.first(where: { $0.id == ref.refId }) { result.append(RouteMapPoint(coordinate: ap.coordinate, name: ap.id, indexInRoute: idx + 1, kind: .systemAirport)) }
            case .systemNavaid: if let nv = document.systemNavaids.first(where: { $0.id == ref.refId }) { result.append(RouteMapPoint(coordinate: nv.coordinate, name: nv.id, indexInRoute: idx + 1, kind: .systemNavaid)) }
            }
        }
        return result
    }
    func legDistancesNM(for route: Route) -> [Double] {
        let points = mapPoints(for: route); guard points.count >= 2 else { return [] }; var distances: [Double] = []
        for i in 0..<(points.count - 1) {
            let a = points[i].coordinate; let b = points[i+1].coordinate
            distances.append(CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0)
        }
        return distances
    }
    
    func deriveUserAirportsIfNeeded() {
            var airportsById: [String: UserAirport] = [:]
            let existingUserIds = Set(document.userAirports.map { $0.id })
            let existingSystemIds = Set(document.systemAirports.map { $0.id })

            for route in document.routes {
                let points = mapPoints(for: route)
                for p in points {
                    let id = p.name
                    if p.kind == .systemAirport || existingSystemIds.contains(id) { continue }
                    if existingUserIds.contains(id) { continue }

                    if NavigationStore.looksLikeAirportId(id), airportsById[id] == nil {
                        let newAirport = UserAirport(
                            id: id, name: id,
                            latitude: p.coordinate.latitude, longitude: p.coordinate.longitude,
                            elevation: 0, magneticVariation: 0
                        )
                        airportsById[id] = newAirport
                    }
                }
            }
            document.userAirports.append(contentsOf: airportsById.values)
        }

    // Normalization & Creation
    private func normalizeImportedRouteIds(_ doc: inout NavigationDocument, existingRoutes: [Route]) {
        var usedIds   = Set(existingRoutes.map { $0.routeId })
        var usedNames = Set(existingRoutes.map { $0.name })

        for i in doc.routes.indices {
            var r = doc.routes[i]

            let raw = r.name.isEmpty ? r.routeId : r.name
            let sanitized = NavigationStore.sanitizedName(raw, maxLength: 10)
            let baseName = sanitized.isEmpty ? "ROUTE" : sanitized
            let finalName = makeUniqueRouteName(base: baseName, used: usedNames)
            r.name = finalName
            usedNames.insert(finalName)

            let idBase  = makeRouteIdBase(from: finalName)
            let finalId = makeUniqueRouteId(base: idBase, used: usedIds)
            r.routeId = finalId
            usedIds.insert(finalId)

            doc.routes[i] = r
        }
    }
    private func makeRouteIdBase(from rawName: String) -> String { let s=NavigationStore.sanitizedName(rawName, maxLength: 15); return s.isEmpty ? "ROUTE" : String(s.prefix(8)) }
    private func makeUniqueRouteName(base: String, used: Set<String>) -> String {
        if !used.contains(base) { return base }
        for n in 2...99 {
            let suffix = "-\(n)"
            let c = String(base.prefix(max(1, 10 - suffix.count))) + suffix
            if !used.contains(c) { return c }
        }
        return String(base.prefix(9)) + "X"
    }
    private func makeUniqueRouteId(base: String, used: Set<String>) -> String { if !used.contains(base) { return base }; for n in 2...99 { let c=String(base.prefix(max(1, 15-"-\(n)".count)))+"-\(n)"; if !used.contains(c) { return c } }; return base+"-X" }
    
    private func makeUniqueWaypointId(preferred: String, used: Set<String>) -> String {
        if !used.contains(preferred) && preferred.count <= 5 { return preferred }
        var base = preferred
        if base.count > 5 { base = String(base.prefix(5)); if !used.contains(base) { return base } }
        if let match = base.range(of: "\\d+$", options: .regularExpression) {
            let prefix = String(base[..<match.lowerBound]); let numStr = String(base[match.lowerBound...])
            if let num = Int(numStr) { for i in (num+1)...999 { let fmt = numStr.hasPrefix("0") ? "%0\(numStr.count)d" : "%d"; let c = prefix + String(format: fmt, i); if c.count <= 5 && !used.contains(c) { return c } } }
        }
        let suffixes = (2...9).map{String($0)} + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map{String($0)}
        for s in suffixes { let c = String(base.prefix(5 - s.count)) + s; if !used.contains(c) { return c } }
        var rnd = ""; repeat { rnd = String(UUID().uuidString.prefix(5)) } while used.contains(rnd)
        return rnd
    }
    
    func createUserAirport(_ ap: UserAirport) { if document.userAirports.contains(where: { $0.id == ap.id }) { var u=ap; u.id=makeUniqueWaypointId(preferred: ap.id, used: Set(document.userAirports.map{$0.id})); document.userAirports.append(u) } else { document.userAirports.append(ap) } }
    func createUserNavaid(_ nv: UserNavaid) { if document.userNavaids.contains(where: { $0.id == nv.id }) { var u=nv; u.id=makeUniqueWaypointId(preferred: nv.id, used: Set(document.userNavaids.map{$0.id})); document.userNavaids.append(u) } else { document.userNavaids.append(nv) } }
    func createUserWaypoint(_ wp: UserWaypoint) { if document.userWaypoints.contains(where: { $0.id == wp.id }) { var u=wp; u.id=makeUniqueWaypointId(preferred: wp.id, used: Set(document.userWaypoints.map{$0.id})); document.userWaypoints.append(u) } else { document.userWaypoints.append(wp) } }
    
    func deleteUserAirport(withID id: String) { document.userAirports.removeAll { $0.id == id }; cleanupReferences(for: id, kind: .userAirport) }
    func deleteUserNavaid(withID id: String) { document.userNavaids.removeAll { $0.id == id }; cleanupReferences(for: id, kind: .userNavaid) }
    func deleteUserWaypoint(withID id: String) { document.userWaypoints.removeAll { $0.id == id }; cleanupReferences(for: id, kind: .userWaypoint) }
    
    /// Removes route references to a deleted point. Matches kind as well as ID: a waypoint and
    /// an airport may share an ID (e.g. "ESSA"), and deleting one must not remove the other.
    private func cleanupReferences(for id: String, kind: RoutePointKind) { for i in document.routes.indices { document.routes[i].pointRefs.removeAll { $0.kind == kind && $0.refId == id } } }
    
    static func looksLikeAirportId(_ value: String) -> Bool { return value.count == 4 && value.first == "E" && value.allSatisfy { $0.isLetter || $0.isNumber } }
    static func sanitizedName(_ raw: String, maxLength: Int) -> String { let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"); let filtered = raw.uppercased().unicodeScalars.filter { allowed.contains($0) }; return String(String.UnicodeScalarView(filtered).prefix(maxLength)) }
}
