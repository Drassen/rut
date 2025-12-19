import Foundation
import CoreLocation
import SwiftUI
import Combine

/// Central app state.
final class NavigationStore: ObservableObject {
    @Published var document: NavigationDocument = NavigationDocument()
    @Published var activeRouteId: UUID? = nil

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

    func addOrMerge(document newDoc: NavigationDocument) {
        var incoming = newDoc
        var merged = document

        // 1. Normalisera IDs
        normalizeImportedRouteIds(&incoming, existingRoutes: merged.routes)
        normalizeImportedWaypointIds(&incoming, existingWaypoints: merged.userWaypoints)

        // Håller koll på vilka User Waypoints som faktiskt behövs
        var idsToImport = Set<String>()

        // --- HJÄLPFUNKTION: Hämta koordinat ---
        func getCoordinate(for ref: RoutePointRef, in doc: NavigationDocument) -> CLLocationCoordinate2D? {
            switch ref.kind {
            case .userWaypoint: return doc.userWaypoints.first { $0.id == ref.refId }?.coordinate
            case .userAirport:  return doc.userAirports.first { $0.id == ref.refId }?.coordinate
            case .userNavaid:   return doc.userNavaids.first { $0.id == ref.refId }?.coordinate
            case .systemAirport: return doc.systemAirports.first { $0.id == ref.refId }?.coordinate
            case .systemNavaid:  return doc.systemNavaids.first { $0.id == ref.refId }?.coordinate
            }
        }

        // --- 2. DUBBLETTKONTROLL RUTTER ---
        for route in incoming.routes {
            let isDuplicate = merged.routes.contains { existing in
                if existing.name.caseInsensitiveCompare(route.name) != .orderedSame { return false }
                if existing.pointRefs.count != route.pointRefs.count { return false }
                
                for (i, p1) in existing.pointRefs.enumerated() {
                    let p2 = route.pointRefs[i]
                    if p1.kind != p2.kind { return false }
                    if p1.refId == p2.refId { continue }
                    
                    guard let c1 = getCoordinate(for: p1, in: merged),
                          let c2 = getCoordinate(for: p2, in: incoming) else { return false }
                    
                    if abs(c1.latitude - c2.latitude) > 0.00001 || abs(c1.longitude - c2.longitude) > 0.00001 {
                        return false
                    }
                }
                return true
            }
            
            if !isDuplicate {
                merged.routes.append(route)
                // Spara waypoints som denna rutt behöver
                let wpIds = route.pointRefs.filter { $0.kind == .userWaypoint }.map { $0.refId }
                idsToImport.formUnion(wpIds)
            } else {
                print("Skipping duplicate route: \(route.name)")
            }
        }

        // --- 3. IMPORTERA PUNKTER ---

        // A. User Waypoints (Strikt filtrering)
        // Om filen innehöll rutter, importera bara waypoints som hör till de nya rutterna.
        // Om filen INTE hade rutter (t.ex. en ren waypoint-lista), importera alla.
        let hasRoutes = !incoming.routes.isEmpty
        
        for wp in incoming.userWaypoints {
            let isNeeded = !hasRoutes || idsToImport.contains(wp.id)
            
            if isNeeded && !merged.userWaypoints.contains(where: { $0.id == wp.id }) {
                merged.userWaypoints.append(wp)
            }
        }
        
        // B. Airports & Navaids (Lös filtrering)
        // Dessa importeras ALLTID om de inte finns, oavsett om en rutt använder dem eller inte.
        // Detta fixar buggen att flygplatser inte importerades.
        
        for ap in incoming.userAirports {
            if !merged.userAirports.contains(where: { $0.id == ap.id }) { merged.userAirports.append(ap) }
        }
        for nv in incoming.userNavaids {
            if !merged.userNavaids.contains(where: { $0.id == nv.id }) { merged.userNavaids.append(nv) }
        }
        
        // System points
        for ap in incoming.systemAirports {
            if !merged.systemAirports.contains(where: { $0.id == ap.id }) { merged.systemAirports.append(ap) }
        }
        for nv in incoming.systemNavaids {
            if !merged.systemNavaids.contains(where: { $0.id == nv.id }) { merged.systemNavaids.append(nv) }
        }

        document = merged

        if activeRouteId == nil, let first = merged.routes.first {
            activeRouteId = first.id
        }
    }

    func deleteRoute(_ route: Route) {
            let idsInDeletedRoute = Set(route.pointRefs.map { $0.refId })
            document.routes.removeAll { $0.id == route.id }
            let idsInRemainingRoutes = Set(document.routes.flatMap { $0.pointRefs.map { $0.refId } })
            let idsToRemove = idsInDeletedRoute.subtracting(idsInRemainingRoutes)

            if !idsToRemove.isEmpty {
                document.userWaypoints.removeAll { idsToRemove.contains($0.id) }
                document.userAirports.removeAll { idsToRemove.contains($0.id) }
                document.userNavaids.removeAll { idsToRemove.contains($0.id) }
                document.systemAirports.removeAll { idsToRemove.contains($0.id) }
                document.systemNavaids.removeAll { idsToRemove.contains($0.id) }
            }

            if activeRouteId == route.id {
                activeRouteId = document.routes.first?.id
            }
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
        
        if type != .custom {
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
        } else {
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

                document.userWaypoints[wpIdx].id = candidate
                document.userWaypoints[wpIdx].name = candidate
                
                idMapping[oldId] = candidate
                usedIds.insert(candidate)
            }

            guard !idMapping.isEmpty else { return }

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
    private func normalizeImportedRouteIds(_ doc: inout NavigationDocument, existingRoutes: [Route]) { var used = Set(existingRoutes.map{$0.routeId}); for i in doc.routes.indices { var r=doc.routes[i]; let base=makeRouteIdBase(from: r.name.isEmpty ? r.routeId : r.name); let u=makeUniqueRouteId(base: base, used: used); r.routeId=u; used.insert(u); doc.routes[i]=r } }
    private func normalizeImportedWaypointIds(_ doc: inout NavigationDocument, existingWaypoints: [UserWaypoint]) { var used = Set(existingWaypoints.map{$0.id}); var m=[String:String](); for i in doc.userWaypoints.indices { var wp=doc.userWaypoints[i]; let p=wp.id; if used.contains(p) { let n=makeUniqueWaypointId(preferred: p, used: used); m[p]=n; wp.id=n }; used.insert(wp.id); doc.userWaypoints[i]=wp }; if !m.isEmpty { for ri in doc.routes.indices { for pi in doc.routes[ri].pointRefs.indices { var ref=doc.routes[ri].pointRefs[pi]; if ref.kind == .userWaypoint, let n=m[ref.refId] { ref.refId=n; doc.routes[ri].pointRefs[pi]=ref } } } } }
    private func makeRouteIdBase(from rawName: String) -> String { let s=NavigationStore.sanitizedName(rawName, maxLength: 15); return s.isEmpty ? "ROUTE" : String(s.prefix(8)) }
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
    
    func deleteUserAirport(withID id: String) { document.userAirports.removeAll { $0.id == id }; cleanupReferences(for: id) }
    func deleteUserNavaid(withID id: String) { document.userNavaids.removeAll { $0.id == id }; cleanupReferences(for: id) }
    func deleteUserWaypoint(withID id: String) { document.userWaypoints.removeAll { $0.id == id }; cleanupReferences(for: id) }
    
    private func cleanupReferences(for id: String) { for i in document.routes.indices { document.routes[i].pointRefs.removeAll { $0.refId == id } } }
    
    static func looksLikeAirportId(_ value: String) -> Bool { return value.count == 4 && value.first == "E" && value.allSatisfy { $0.isLetter || $0.isNumber } }
    static func sanitizedName(_ raw: String, maxLength: Int) -> String { let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"); let filtered = raw.uppercased().unicodeScalars.filter { allowed.contains($0) }; return String(String.UnicodeScalarView(filtered).prefix(maxLength)) }
}
