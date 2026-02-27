import SwiftUI
import MapKit

// MARK: - Map style

enum RutMapStyle: String, CaseIterable, Identifiable {
    case hybrid
    case standard
    case satellite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hybrid:   return "Hybrid"
        case .standard: return "Standard"
        case .satellite:return "Satellite"
        }
    }

    var mapKitStyle: MapStyle {
        switch self {
        case .hybrid:   return .hybrid
        case .standard: return .standard
        case .satellite:return .imagery
        }
    }
}

// MARK: - Custom shapes

struct TriangleMarkerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Map view

struct RutMapView: View {
    @EnvironmentObject var navStore: NavigationStore
    @StateObject private var airspaceService = AirspaceService.shared

    var onPointTap: ((RouteMapPoint) -> Void)? = nil
    var onMapLongPress: ((CLLocationCoordinate2D) -> Void)? = nil

    @State private var camera: MapCameraPosition = .automatic
    @State private var mapStyle: RutMapStyle = .hybrid

    // --- Drag state for database markers ---
    @State private var draggingAirportId: String?
    @State private var draggingAirportCoord = CLLocationCoordinate2D()
    @State private var draggingNavaidId: String?
    @State private var draggingNavaidCoord = CLLocationCoordinate2D()
    @State private var pendingMove: PendingMove?
    @State private var showMoveConfirm = false

    // --- Map-level long-press/drag state ---
    @GestureState private var isMapLongPressing = false
    @State private var mapDragTarget: MapDragTarget? = nil
    @State private var mapDragTargetChecked = false

    // --- FÄRGER ---
    private let colorAirport = Color(uiColor: .darkGray)
    private let colorNavaid  = Color.gray
    private let colorWpt     = Color(uiColor: .lightGray)

    private let colorActive   = Color.blue
    private let colorInactive = Color.blue.opacity(0.3)

    private var hasActiveRoute: Bool { navStore.activeRoute != nil }

    private var activeRouteIDs: Set<String> {
        guard let route = navStore.activeRoute else { return [] }
        return Set(route.pointRefs.map { $0.refId })
    }

    private var inactiveRouteIDs: Set<String> {
        let refs = navStore.routes
            .filter { $0.id != navStore.activeRouteId }
            .flatMap { $0.pointRefs.map { $0.refId } }
        return Set(refs)
    }

    // Pending move confirmation
    private struct PendingMove {
        enum Kind {
            case airport(UserAirport)
            case navaid(UserNavaid)
        }
        let kind: Kind
        let newCoordinate: CLLocationCoordinate2D
    }

    // Map-level drag target
    private enum MapDragTarget {
        case userAirport(UserAirport)
        case userNavaid(UserNavaid)
        case routePoint(index: Int)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapReader { proxy in
                Map(position: $camera) {

                    // 0. Airspace zones (bakgrund, ej klickbar)
                    airspaceContent()

                    // 1. Inaktiva rutter
                    inactiveRoutesContent(proxy: proxy)

                    // 2. Databas
                    databaseContent(proxy: proxy)

                    // 3. Aktiv rutt
                    activeRouteContent(proxy: proxy)
                }
                .mapStyle(mapStyle.mapKitStyle)
                .onAppear {
                    configureInitialCamera()
                }
                .task {
                    await airspaceService.fetchAllZones()
                }
                // Single map-level gesture handles both marker drag and new-point creation.
                // LongPressGesture is NOT on annotation views, so normal pan is never blocked.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { v in
                                if !mapDragTargetChecked {
                                    mapDragTargetChecked = true
                                    mapDragTarget = findDragTarget(at: v.startLocation, proxy: proxy)
                                }
                                if let target = mapDragTarget {
                                    updateMapDragTarget(target, at: v.location, proxy: proxy)
                                }
                            }
                            .onEnded { v in
                                if let target = mapDragTarget {
                                    finalizeMapDragTarget(target, at: v.location, proxy: proxy)
                                } else {
                                    if let coord = proxy.convert(v.startLocation, from: .global) {
                                        onMapLongPress?(coord)
                                    }
                                }
                                mapDragTarget = nil
                                mapDragTargetChecked = false
                            }
                        )
                        .updating($isMapLongPressing) { v, s, _ in
                            if case .first(true) = v { s = true }
                            else if case .second(true, _) = v { s = true }
                            else { s = false }
                        }
                )
                .onChange(of: isMapLongPressing) { wasActive, isActive in
                    if wasActive && !isActive {
                        // Gesture cancelled (e.g. pan recognised first) – clean up
                        if mapDragTarget != nil {
                            draggingAirportId = nil
                            draggingNavaidId = nil
                        }
                        mapDragTarget = nil
                        mapDragTargetChecked = false
                    }
                }
            }

            Picker("Map style", selection: $mapStyle) {
                ForEach(RutMapStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)
            .padding(8)
            .background(Color.black.opacity(0.4))
            .foregroundColor(Color.white)
            .cornerRadius(4)
            .padding()
        }
        .alert("Confirm Move", isPresented: $showMoveConfirm) {
            Button("Move") {
                confirmPendingMove()
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) {
                pendingMove = nil
            }
        } message: {
            if let move = pendingMove {
                Text(moveConfirmMessage(for: move))
            }
        }
    }

    // MARK: - 0. Airspace Zones

    @MapContentBuilder
    private func airspaceContent() -> some MapContent {
        ForEach(airspaceService.zones) { zone in
            MapPolygon(coordinates: zone.coordinates)
                .foregroundStyle(zone.type.fillColor)
                .stroke(zone.type.strokeColor, lineWidth: 1.5)
        }
    }

    // MARK: - 1. Database Content

    @MapContentBuilder
    private func databaseContent(proxy: MapProxy) -> some MapContent {

        let opacity = hasActiveRoute ? 0.8 : 1.0
        let scale   = hasActiveRoute ? 0.8 : 1.0

        // --- USER AIRPORTS ---
        ForEach(Array(navStore.document.userAirports.enumerated()), id: \.offset) { index, airport in
            if !activeRouteIDs.contains(airport.id) && !inactiveRouteIDs.contains(airport.id) {
                let dragCoord = draggingAirportId == airport.id
                    ? draggingAirportCoord
                    : displayCoordinate(for: airport.coordinate)
                Annotation("apt-\(index)-\(airport.id)", coordinate: dragCoord) {
                    DatabaseMarkerView(bgColor: colorAirport, iconName: "airplane", iconColor: .white, label: airport.id)
                        .scaleEffect(draggingAirportId == airport.id ? 1.2 : 1.0)
                        .opacity(opacity)
                        .scaleEffect(scale)
                        .onTapGesture {
                            onPointTap?(RouteMapPoint(coordinate: airport.coordinate,
                                                      name: airport.id, indexInRoute: -1, kind: .userAirport))
                        }
                }
                .annotationTitles(.hidden)
            }
        }

        // --- USER NAVAIDS ---
        ForEach(Array(navStore.document.userNavaids.enumerated()), id: \.offset) { index, navaid in
            if !activeRouteIDs.contains(navaid.id) && !inactiveRouteIDs.contains(navaid.id) {
                let dragCoord = draggingNavaidId == navaid.id
                    ? draggingNavaidCoord
                    : displayCoordinate(for: navaid.coordinate)
                Annotation("nav-\(index)-\(navaid.id)", coordinate: dragCoord) {
                    DatabaseMarkerView(bgColor: colorNavaid, iconName: "antenna.radiowaves.left.and.right", iconColor: .white, label: navaid.id)
                        .scaleEffect(draggingNavaidId == navaid.id ? 1.2 : 1.0)
                        .opacity(opacity)
                        .scaleEffect(scale)
                        .onTapGesture {
                            onPointTap?(RouteMapPoint(coordinate: navaid.coordinate,
                                                      name: navaid.id, indexInRoute: -1, kind: .userNavaid))
                        }
                }
                .annotationTitles(.hidden)
            }
        }

        // --- USER WAYPOINTS ---
        ForEach(Array(navStore.document.userWaypoints.enumerated()), id: \.offset) { index, wp in
            if !activeRouteIDs.contains(wp.id) && !inactiveRouteIDs.contains(wp.id) {
                Annotation("wpt-\(index)-\(wp.id)", coordinate: displayCoordinate(for: wp.coordinate)) {
                    let bg = isZero(wp.coordinate) ? Color.red : colorWpt

                    ZStack {
                        Circle().fill(bg)
                        Text("W").font(.system(size: 12, weight: .bold)).foregroundColor(.black)
                    }
                    .frame(width: 26, height: 26)
                    .overlay(alignment: .top) {
                        Text(wp.id)
                            .font(.caption2)
                            .padding(2)
                            .background(Color.white.opacity(0.8))
                            .cornerRadius(4)
                            .fixedSize()
                            .offset(y: 30)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Circle())
                    .opacity(opacity)
                    .scaleEffect(scale)
                    .onTapGesture {
                        onPointTap?(RouteMapPoint(coordinate: wp.coordinate, name: wp.id, indexInRoute: -1, kind: .userWaypoint))
                    }
                }
                .annotationTitles(.hidden)
            }
        }

        // --- SYSTEM AIRPORTS ---
        ForEach(Array(navStore.document.systemAirports.enumerated()), id: \.offset) { index, ap in
            if !activeRouteIDs.contains(ap.id) && !inactiveRouteIDs.contains(ap.id) {
                Annotation("sys-apt-\(index)-\(ap.id)", coordinate: displayCoordinate(for: ap.coordinate)) {
                    DatabaseMarkerView(bgColor: colorAirport, iconName: "airplane", iconColor: .white, label: ap.id)
                        .opacity(opacity)
                        .scaleEffect(scale)
                        .onTapGesture {
                            onPointTap?(RouteMapPoint(coordinate: ap.coordinate, name: ap.id, indexInRoute: -1, kind: .systemAirport))
                        }
                }
                .annotationTitles(.hidden)
            }
        }

        // --- SYSTEM NAVAIDS ---
        ForEach(Array(navStore.document.systemNavaids.enumerated()), id: \.offset) { index, nv in
            if !activeRouteIDs.contains(nv.id) && !inactiveRouteIDs.contains(nv.id) {
                Annotation("sys-nav-\(index)-\(nv.id)", coordinate: displayCoordinate(for: nv.coordinate)) {
                    DatabaseMarkerView(bgColor: colorNavaid, iconName: "antenna.radiowaves.left.and.right", iconColor: .white, label: nv.id)
                        .opacity(opacity)
                        .scaleEffect(scale)
                        .onTapGesture {
                            onPointTap?(RouteMapPoint(coordinate: nv.coordinate, name: nv.id, indexInRoute: -1, kind: .systemNavaid))
                        }
                }
                .annotationTitles(.hidden)
            }
        }
    }

    // MARK: - 2. Inactive Routes

    @MapContentBuilder
    private func inactiveRoutesContent(proxy: MapProxy) -> some MapContent {
        ForEach(navStore.routes.filter { $0.id != navStore.activeRouteId }) { route in
            let points = navStore.mapPoints(for: route)
            let coords = points.map { displayCoordinate(for: $0.coordinate) }
            let dimFactor = hasActiveRoute ? 0.9 : 1.0

            if coords.count >= 2 {
                MapPolyline(coordinates: coords)
                    .stroke(colorInactive.opacity(dimFactor), lineWidth: 6)
            }

            ForEach(Array(points.enumerated()), id: \.offset) { pair in
                let p = pair.element

                if !activeRouteIDs.contains(p.name) {
                    Annotation(p.name, coordinate: displayCoordinate(for: p.coordinate)) {
                        let type = waypointType(for: p)
                        RouteMarkerShapeView(
                            point: p,
                            color: colorInactive.opacity(dimFactor),
                            contentColor: .white.opacity(0.8 * dimFactor),
                            waypointType: type
                        )
                        .scaleEffect(hasActiveRoute ? 0.9 : 1.0)
                        .onTapGesture {
                            if p.kind == .userWaypoint { onPointTap?(p) }
                        }
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
    }

    // MARK: - 3. Active Route

    @MapContentBuilder
    private func activeRouteContent(proxy: MapProxy) -> some MapContent {
        if let route = navStore.activeRoute {
            let points = navStore.mapPoints(for: route)
            let coords = points.map { displayCoordinate(for: $0.coordinate) }
            let legDistances = navStore.legDistancesNM(for: route)

            if coords.count >= 2 {
                MapPolyline(coordinates: coords)
                    .stroke(colorActive, lineWidth: 6)
            }

            ForEach(Array(points.enumerated()), id: \.offset) { pair in
                let idx = pair.offset
                let p = pair.element
                let type = waypointType(for: p)
                let isDragging: Bool = {
                    if case .routePoint(let di) = mapDragTarget { return di == idx }
                    return false
                }()

                Annotation(p.name, coordinate: displayCoordinate(for: p.coordinate)) {
                    RouteMarkerShapeView(point: p, color: colorActive, contentColor: .white, waypointType: type)
                        .scaleEffect(isDragging ? 1.2 : 1.0)
                        .zIndex(10)
                        .onTapGesture { onPointTap?(p) }
                }
                .annotationTitles(.hidden)

                if idx < points.count - 1 && idx < legDistances.count {
                    let next = points[idx + 1]
                    let safeP = displayCoordinate(for: p.coordinate)
                    let safeNext = displayCoordinate(for: next.coordinate)
                    let mid = CLLocationCoordinate2D(
                        latitude: (safeP.latitude + safeNext.latitude) / 2.0,
                        longitude: (safeP.longitude + safeNext.longitude) / 2.0
                    )
                    let label = String(format: "%.1fN", legDistances[idx])

                    Annotation(label, coordinate: mid) {
                        Text(label)
                            .font(.caption2)
                            .padding(3)
                            .background(colorActive)
                            .foregroundColor(.black)
                            .cornerRadius(4)
                            .zIndex(5)
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
    }

    // MARK: - Map drag helpers

    /// Hit-test: find the draggable marker closest to a screen point (within threshold).
    private func findDragTarget(at screenPoint: CGPoint, proxy: MapProxy) -> MapDragTarget? {
        let threshold: CGFloat = 30
        var closestDist = CGFloat.infinity
        var result: MapDragTarget? = nil

        // User airports (visible ones – not in any route)
        for airport in navStore.document.userAirports {
            guard !activeRouteIDs.contains(airport.id) && !inactiveRouteIDs.contains(airport.id) else { continue }
            let coord = draggingAirportId == airport.id
                ? draggingAirportCoord
                : displayCoordinate(for: airport.coordinate)
            if let pt = proxy.convert(coord, to: .global) {
                let dist = hypot(pt.x - screenPoint.x, pt.y - screenPoint.y)
                if dist < threshold && dist < closestDist {
                    closestDist = dist
                    result = .userAirport(airport)
                }
            }
        }

        // User navaids
        for navaid in navStore.document.userNavaids {
            guard !activeRouteIDs.contains(navaid.id) && !inactiveRouteIDs.contains(navaid.id) else { continue }
            let coord = draggingNavaidId == navaid.id
                ? draggingNavaidCoord
                : displayCoordinate(for: navaid.coordinate)
            if let pt = proxy.convert(coord, to: .global) {
                let dist = hypot(pt.x - screenPoint.x, pt.y - screenPoint.y)
                if dist < threshold && dist < closestDist {
                    closestDist = dist
                    result = .userNavaid(navaid)
                }
            }
        }

        // Active route points
        if let route = navStore.activeRoute {
            let points = navStore.mapPoints(for: route)
            for (idx, point) in points.enumerated() {
                if let pt = proxy.convert(displayCoordinate(for: point.coordinate), to: .global) {
                    let dist = hypot(pt.x - screenPoint.x, pt.y - screenPoint.y)
                    if dist < threshold && dist < closestDist {
                        closestDist = dist
                        result = .routePoint(index: idx)
                    }
                }
            }
        }

        return result
    }

    private func updateMapDragTarget(_ target: MapDragTarget, at screenPoint: CGPoint, proxy: MapProxy) {
        guard let coord = proxy.convert(screenPoint, from: .global) else { return }
        switch target {
        case .userAirport(let airport):
            draggingAirportId = airport.id
            draggingAirportCoord = coord
        case .userNavaid(let navaid):
            draggingNavaidId = navaid.id
            draggingNavaidCoord = coord
        case .routePoint(let idx):
            if let route = navStore.activeRoute {
                navStore.updateWaypointCoordinate(in: route, at: idx, to: coord)
            }
        }
    }

    private func finalizeMapDragTarget(_ target: MapDragTarget, at screenPoint: CGPoint, proxy: MapProxy) {
        guard let coord = proxy.convert(screenPoint, from: .global) else { return }
        switch target {
        case .userAirport(let airport):
            draggingAirportId = nil
            pendingMove = PendingMove(kind: .airport(airport), newCoordinate: coord)
            showMoveConfirm = true
        case .userNavaid(let navaid):
            draggingNavaidId = nil
            pendingMove = PendingMove(kind: .navaid(navaid), newCoordinate: coord)
            showMoveConfirm = true
        case .routePoint(let idx):
            if let route = navStore.activeRoute {
                navStore.updateWaypointCoordinate(in: route, at: idx, to: coord)
            }
        }
    }

    // MARK: - Helpers

    private func moveConfirmMessage(for move: PendingMove) -> String {
        let name: String
        switch move.kind {
        case .airport(let ap): name = ap.id
        case .navaid(let nv):  name = nv.id
        }
        return "Move \(name) to \(String(format: "%.4f", move.newCoordinate.latitude))°N, \(String(format: "%.4f", move.newCoordinate.longitude))°E?"
    }

    private func confirmPendingMove() {
        guard let move = pendingMove else { return }
        switch move.kind {
        case .airport(let ap):
            navStore.updateAirport(
                originalId: ap.id, newId: ap.id, newName: ap.name,
                latitude: move.newCoordinate.latitude,
                longitude: move.newCoordinate.longitude,
                elevation: ap.elevation, magVar: ap.magneticVariation)
        case .navaid(let nv):
            navStore.updateNavaid(
                originalId: nv.id, newId: nv.id, newName: nv.name,
                latitude: move.newCoordinate.latitude,
                longitude: move.newCoordinate.longitude,
                elevation: nv.elevation, magVar: nv.magneticVariation,
                frequency: nv.frequency)
        }
    }

    private func configureInitialCamera() {
        if let route = navStore.activeRoute, let first = navStore.mapPoints(for: route).first {
            setRegion(center: displayCoordinate(for: first.coordinate))
        } else if let ap = navStore.document.userAirports.first {
            setRegion(center: displayCoordinate(for: ap.coordinate))
        } else if let nav = navStore.document.userNavaids.first {
            setRegion(center: displayCoordinate(for: nav.coordinate))
        } else if let wp = navStore.document.userWaypoints.first {
            setRegion(center: displayCoordinate(for: wp.coordinate))
        } else if let sysAp = navStore.document.systemAirports.first {
            setRegion(center: displayCoordinate(for: sysAp.coordinate))
        }
    }

    private func isZero(_ c: CLLocationCoordinate2D) -> Bool {
        return abs(c.latitude) < 0.0000001 && abs(c.longitude) < 0.0000001
    }

    private func displayCoordinate(for c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if isZero(c) {
            return CLLocationCoordinate2D(latitude: 0.000001, longitude: 0.000001)
        }
        return c
    }

    private func setRegion(center: CLLocationCoordinate2D) {
        camera = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)))
    }

    private func waypointType(for point: RouteMapPoint) -> WaypointType? {
        guard point.kind == .userWaypoint else { return nil }
        return navStore.document.userWaypoints.first(where: { $0.id == point.name })?.type
    }
}

// MARK: - SUBVIEWS

struct DatabaseMarkerView: View {
    let bgColor: Color
    let iconName: String
    let iconColor: Color
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .fill(bgColor)

            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundColor(iconColor)
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .top) {
            Text(label)
                .font(.caption2)
                .padding(2)
                .background(Color.white.opacity(0.8))
                .foregroundColor(Color.black.opacity(0.8))
                .cornerRadius(4)
                .fixedSize()
                .offset(y: 30)
                .allowsHitTesting(false)
        }
        .contentShape(Circle())
    }
}

struct RouteMarkerShapeView: View {
    let point: RouteMapPoint
    let color: Color
    let contentColor: Color
    let waypointType: WaypointType?

    var body: some View {
        ZStack {
            markerShape()
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .top) {
            Text(point.name)
                .font(.caption2)
                .padding(2)
                .background(Color.white.opacity(0.8))
                .foregroundColor(.black)
                .cornerRadius(4)
                .fixedSize()
                .offset(y: 30)
                .allowsHitTesting(false)
        }
        .contentShape(Circle())
    }

    @ViewBuilder
    private func markerShape() -> some View {
        switch point.kind {

        // --- AIRPORTS ---
        case .userAirport, .systemAirport:
            ZStack {
                Circle().fill(color)
                Image(systemName: "airplane")
                    .font(.system(size: 14))
                    .foregroundColor(contentColor)
            }

        // --- NAVAIDS ---
        case .userNavaid, .systemNavaid:
            ZStack {
                Circle().fill(color)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundColor(contentColor)
            }

        // --- WAYPOINTS ---
        case .userWaypoint:
            if let t = waypointType {
                switch t {
                case .tgt:
                    ZStack {
                        TriangleMarkerShape().fill(color)
                        TriangleMarkerShape().fill(Color.white).padding(6)
                    }
                case .ip:
                    ZStack {
                        Rectangle().fill(color)
                        Rectangle().fill(Color.white).padding(6)
                    }
                case .lp:
                    ZStack {
                        TriangleMarkerShape().fill(color)
                        TriangleMarkerShape().fill(Color.white).padding(6)
                    }
                case .cli:
                    ZStack {
                        Circle().fill(color)
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    }
                case .des:
                    ZStack {
                        Circle().fill(color)
                        Image(systemName: "arrow.down").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    }
                case .hld:
                    ZStack {
                        Circle().fill(color)
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    }
                default:
                    ZStack {
                        Circle().fill(color)
                        Circle().fill(Color.white).padding(6)
                    }
                }
            } else {
                ZStack {
                    Circle().fill(color)
                    Circle().fill(Color.white).padding(6)
                }
            }
        }
    }
}
