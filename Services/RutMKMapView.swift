import SwiftUI
import MapKit

// MARK: - RutMKMapView

/// The map drawn with MKMapView instead of SwiftUI `Map`.
///
/// SwiftUI `Map` adds one overlay per `MapPolygon`. With all 234 LFV airspace zones on
/// screen (zoomed out) MapKit renders at ~30 fps; one `MKMultiPolygon` per zone type
/// (4 overlays) measured a steady 60 fps on iPad (2026-09-15). SwiftUI `Map` cannot
/// show multipolygons, hence this UIKit-backed map.
///
/// The SwiftUI map (RutMapView) was removed on 2026-09-15 once this one covered rendering,
/// taps, marker/route-point dragging, route-point insertion and vector drawing/editing.
struct RutMKMapView: View {
    @EnvironmentObject var navStore: NavigationStore
    @EnvironmentObject var vectorStore: VectorStore
    @EnvironmentObject var core: CoreServices
    @StateObject private var airspaceService = AirspaceService.shared
    @AppStorage("autoLoadLFVLayer") private var autoLoadLFVLayer: Bool = true

    var onPointTap: ((RouteMapPoint) -> Void)? = nil
    var onMapLongPress: ((CLLocationCoordinate2D) -> Void)? = nil

    @State private var mapStyle: RutMapStyle = .hybrid
    @State private var showMapLabels: Bool = true

    // --- Drag confirmations ---
    @State private var pendingMove: PendingMove?
    @State private var showMoveConfirm = false
    @State private var pendingRoutePointMove: PendingRoutePointMove?
    @State private var showRoutePointMoveConfirm = false
    @State private var pendingInsert: PendingInsert?
    @State private var showLineInsertAlert = false

    // Marker and route colours.
    private let colorAirport  = Color(uiColor: .darkGray)
    private let colorNavaid   = Color.gray
    private let colorActive   = Color.blue
    private let colorInactive = Color.blue.opacity(0.3)

    private struct PendingMove {
        enum Kind {
            case airport(id: String)
            case navaid(id: String)
            case waypoint(id: String)
        }
        let kind: Kind
        let newCoordinate: CLLocationCoordinate2D
    }

    private struct PendingRoutePointMove {
        let routeId: UUID
        let pointIndex: Int
        let pointId: String
        let newCoordinate: CLLocationCoordinate2D
    }

    private struct PendingInsert {
        let segmentIndex: Int
        let snapRef: RoutePointRef?
        let coordinate: CLLocationCoordinate2D
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RutMKRepresentable(
                content: makeContent(),
                mapStyle: mapStyle,
                holdRoutePointDrag: pendingRoutePointMove != nil,
                initialRegion: initialRegion,
                handlers: RutMKHandlers(
                    pointTap: onPointTap,
                    longPress: onMapLongPress,
                    selectShape: { vectorStore.selectShape(id: $0, layerId: $1) },
                    deselectShape: { vectorStore.deselectShape() },
                    drawTap: handleDrawTap,
                    moveEditVertex: { vectorStore.moveEditVertex(at: $0, to: $1) },
                    insertEditVertex: { vectorStore.insertEditVertex($1, at: $0) },
                    dragEnded: handleDragEnded,
                    labelsVisibleChanged: { showMapLabels = $0 },
                    regionChanged: { core.mapCamera = .region($0) }
                )
            )
            .task {
                guard autoLoadLFVLayer else { return }
                await airspaceService.fetchAllZones()
                vectorStore.syncAirspaceSystemLayer(zones: airspaceService.zones)
            }

            VStack {
                HStack {
                    Picker("Map style", selection: $mapStyle) {
                        ForEach(RutMapStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RutTheme.surface.opacity(0.88))
                    .foregroundColor(RutTheme.amber)
                    .tint(RutTheme.amber)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(RutTheme.border, lineWidth: 1))
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
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
        .alert(lineInsertAlertTitle, isPresented: $showLineInsertAlert) {
            Button("Add") { confirmLineInsert() }
            Button("Cancel", role: .cancel) { pendingInsert = nil }
        } message: {
            if let ins = pendingInsert, ins.snapRef == nil {
                Text(String(format: "Create a new waypoint at %.4f°N, %.4f°E and insert it into the route?",
                            ins.coordinate.latitude, ins.coordinate.longitude))
            }
        }
        .alert("Confirm Move", isPresented: $showRoutePointMoveConfirm) {
            Button("Move") {
                if let move = pendingRoutePointMove,
                   let route = navStore.document.routes.first(where: { $0.id == move.routeId }) {
                    navStore.updateWaypointCoordinate(in: route, at: move.pointIndex, to: move.newCoordinate)
                }
                pendingRoutePointMove = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRoutePointMove = nil
            }
        } message: {
            if let move = pendingRoutePointMove {
                Text("Move \(move.pointId) to \(String(format: "%.4f", move.newCoordinate.latitude))°N, \(String(format: "%.4f", move.newCoordinate.longitude))°E?")
            }
        }
    }

    // MARK: Content

    /// Everything the map shows, in drawing order, plus what long-press and taps can grab.
    private func makeContent() -> RutMKContent {
        let doc = navStore.document
        let isVector = core.appMode == .vector
        let vectorDim = isVector ? 0.60 : 1.0

        let activeRoute = navStore.activeRoute
        let hasActiveRoute = activeRoute != nil
        let activeRouteIDs = Set(activeRoute?.pointRefs.map { $0.refId } ?? [])
        let inactiveRoutes = navStore.routes.filter { $0.id != navStore.activeRouteId }
        let inactiveRouteIDs = Set(inactiveRoutes.flatMap { $0.pointRefs.map { $0.refId } })
        func inAnyRoute(_ id: String) -> Bool {
            activeRouteIDs.contains(id) || inactiveRouteIDs.contains(id)
        }

        var overlays: [RutMKOverlaySpec] = []
        var annotations: [RutMKAnnotationSpec] = []
        var interaction = RutMKInteraction()
        interaction.isNavigation = core.appMode == .navigation

        // 0a. Airspace: one multipolygon per zone type, stacked in load order.
        if vectorStore.airspaceVisible {
            var zonesByType: [AirspaceZone.ZoneType: [AirspaceZone]] = [:]
            var typeOrder: [AirspaceZone.ZoneType] = []
            for zone in airspaceService.zones where vectorStore.airspaceTypeVisible[zone.type] ?? true {
                if zonesByType[zone.type] == nil { typeOrder.append(zone.type) }
                zonesByType[zone.type, default: []].append(zone)
            }
            for type in typeOrder {
                overlays.append(RutMKOverlaySpec(key: "airspace-\(type.rawValue)",
                                                 geometry: .airspace(zonesByType[type] ?? []),
                                                 style: .airspace(type)))
            }
        }

        // 0b. User vector layers
        let selectedId = vectorStore.activeShapeId
        let editingId  = vectorStore.isEditingShape ? selectedId : nil
        let vectorPolygons = vectorStore.visiblePolygons()
        for item in vectorPolygons where item.id != editingId {
            overlays.append(RutMKOverlaySpec(key: "vpolygon-\(item.id)",
                                             geometry: .polygon(item.coordinates.map { RutMKGeoPoint($0) }),
                                             style: .vectorPolygon(item.style, selected: item.id == selectedId)))
        }
        let vectorPolylines = vectorStore.visiblePolylines()
        for item in vectorPolylines where item.id != editingId {
            overlays.append(RutMKOverlaySpec(key: "vpolyline-\(item.id)",
                                             geometry: .polyline(item.coordinates.map { RutMKGeoPoint($0) }),
                                             style: .vectorPolyline(item.style, selected: item.id == selectedId)))
        }
        let vectorCircles = vectorStore.visibleCircles()
        for item in vectorCircles where item.id != editingId {
            overlays.append(RutMKOverlaySpec(key: "vcircle-\(item.id)",
                                             geometry: .circle(center: RutMKGeoPoint(item.center), radiusMeters: item.radiusMeters),
                                             style: .vectorCircle(item.style, selected: item.id == selectedId)))
        }
        // Shapes are only selectable in vector mode with no active tool and outside vertex
        // editing; with a tool active a tap adds a drawing vertex instead.
        let canSelectShape = isVector && vectorStore.activeTool == .none && !vectorStore.isEditingShape
        let vectorPoints = vectorStore.visiblePoints()
        for item in vectorPoints where item.id != editingId {
            annotations.append(RutMKAnnotationSpec(
                key: "vpoint-\(item.id)",
                coordinate: RutMKGeoPoint(item.coordinate),
                zPriority: isVector ? MapAnnotationZ.vectorPointAbove : MapAnnotationZ.vectorPointBelow,
                marker: .vectorPoint(name: item.name, style: item.style,
                                     selected: item.id == selectedId, showName: isVector),
                tap: canSelectShape ? .selectShape(id: item.id, layerId: item.layerId) : .none))
        }

        // 1. Inactive routes
        let dimFactor = (hasActiveRoute ? 0.9 : 1.0) * vectorDim
        for route in inactiveRoutes {
            let points = navStore.mapPoints(for: route)
            if points.count >= 2 {
                overlays.append(RutMKOverlaySpec(key: "route-\(route.id)",
                                                 geometry: .polyline(points.map { RutMKGeoPoint(Self.displayCoordinate(for: $0.coordinate)) }),
                                                 style: .route(active: false, opacity: dimFactor)))
            }
            for (offset, p) in points.enumerated() where !activeRouteIDs.contains(p.name) {
                annotations.append(RutMKAnnotationSpec(
                    key: "i-\(route.id)-\(offset)",
                    coordinate: RutMKGeoPoint(Self.displayCoordinate(for: p.coordinate)),
                    zPriority: MapAnnotationZ.inactiveRoute,
                    marker: .routePoint(name: p.name, kind: p.kind, waypointType: waypointType(for: p),
                                        color: colorInactive.opacity(dimFactor),
                                        contentColor: .white.opacity(0.8 * dimFactor),
                                        showLabel: false, opacity: 1.0,
                                        scale: hasActiveRoute ? 0.9 : 1.0),
                    tap: p.kind == .userWaypoint ? .point(p) : .none))
            }
        }

        // 2. Database
        let dbOpacity = isVector ? 0.60 : (hasActiveRoute ? 0.8 : 1.0)
        let dbScale   = hasActiveRoute && !isVector ? 0.8 : 1.0
        for (index, airport) in doc.userAirports.enumerated() where !inAnyRoute(airport.id) {
            let key = "apt-\(index)-\(airport.id)"
            annotations.append(databaseSymbol(
                key: key, coordinate: airport.coordinate,
                bgColor: colorAirport, iconName: "airplane", label: airport.id,
                opacity: dbOpacity, scale: dbScale,
                tap: isVector ? .none : .point(name: airport.id, kind: .userAirport, coordinate: airport.coordinate)))
            interaction.airports.append(.init(id: airport.id, key: key,
                                              coordinate: Self.displayCoordinate(for: airport.coordinate)))
        }
        for (index, navaid) in doc.userNavaids.enumerated() where !inAnyRoute(navaid.id) {
            let key = "nav-\(index)-\(navaid.id)"
            annotations.append(databaseSymbol(
                key: key, coordinate: navaid.coordinate,
                bgColor: colorNavaid, iconName: "antenna.radiowaves.left.and.right", label: navaid.id,
                opacity: dbOpacity, scale: dbScale,
                tap: isVector ? .none : .point(name: navaid.id, kind: .userNavaid, coordinate: navaid.coordinate)))
            interaction.navaids.append(.init(id: navaid.id, key: key,
                                             coordinate: Self.displayCoordinate(for: navaid.coordinate)))
        }
        for (index, wp) in doc.userWaypoints.enumerated() where !inAnyRoute(wp.id) {
            let key = "wpt-\(index)-\(wp.id)"
            annotations.append(RutMKAnnotationSpec(
                key: key,
                coordinate: RutMKGeoPoint(Self.displayCoordinate(for: wp.coordinate)),
                zPriority: MapAnnotationZ.database,
                marker: .databaseWaypoint(label: wp.id, isZero: Self.isZero(wp.coordinate),
                                          showLabel: showMapLabels, opacity: dbOpacity, scale: dbScale),
                tap: .point(name: wp.id, kind: .userWaypoint, coordinate: wp.coordinate)))
            interaction.waypoints.append(.init(id: wp.id, key: key,
                                               coordinate: Self.displayCoordinate(for: wp.coordinate)))
        }
        for (index, ap) in doc.systemAirports.enumerated() where !inAnyRoute(ap.id) {
            annotations.append(databaseSymbol(
                key: "sys-apt-\(index)-\(ap.id)", coordinate: ap.coordinate,
                bgColor: colorAirport, iconName: "airplane", label: ap.id,
                opacity: dbOpacity, scale: dbScale,
                tap: .point(name: ap.id, kind: .systemAirport, coordinate: ap.coordinate)))
        }
        for (index, nv) in doc.systemNavaids.enumerated() where !inAnyRoute(nv.id) {
            annotations.append(databaseSymbol(
                key: "sys-nav-\(index)-\(nv.id)", coordinate: nv.coordinate,
                bgColor: colorNavaid, iconName: "antenna.radiowaves.left.and.right", label: nv.id,
                opacity: dbOpacity, scale: dbScale,
                tap: .point(name: nv.id, kind: .systemNavaid, coordinate: nv.coordinate)))
        }

        // Snap targets for route-point insertion: every database point, routed or not.
        func snap(_ kind: RoutePointKind, _ id: String, _ c: CLLocationCoordinate2D) {
            interaction.snapCandidates.append(.init(ref: RoutePointRef(kind: kind, refId: id),
                                                    coordinate: Self.displayCoordinate(for: c)))
        }
        for ap in doc.userAirports   { snap(.userAirport, ap.id, ap.coordinate) }
        for nv in doc.userNavaids    { snap(.userNavaid, nv.id, nv.coordinate) }
        for wp in doc.userWaypoints  { snap(.userWaypoint, wp.id, wp.coordinate) }
        for ap in doc.systemAirports { snap(.systemAirport, ap.id, ap.coordinate) }
        for nv in doc.systemNavaids  { snap(.systemNavaid, nv.id, nv.coordinate) }

        // 3. Active route
        if let route = activeRoute {
            let points = navStore.mapPoints(for: route)
            let legDistances = navStore.legDistancesNM(for: route)
            interaction.activeRouteId = route.id
            if points.count >= 2 {
                overlays.append(RutMKOverlaySpec(key: RutMKOverlaySpec.activeRouteKey(route.id),
                                                 geometry: .polyline(points.map { RutMKGeoPoint(Self.displayCoordinate(for: $0.coordinate)) }),
                                                 style: .route(active: true, opacity: vectorDim)))
            }
            for (idx, p) in points.enumerated() {
                let key = RutMKAnnotationSpec.activeRoutePointKey(idx)
                annotations.append(RutMKAnnotationSpec(
                    key: key,
                    coordinate: RutMKGeoPoint(Self.displayCoordinate(for: p.coordinate)),
                    zPriority: MapAnnotationZ.activeRoute,
                    marker: .routePoint(name: p.name, kind: p.kind, waypointType: waypointType(for: p),
                                        color: colorActive, contentColor: .white,
                                        showLabel: showMapLabels && !isVector,
                                        opacity: vectorDim, scale: 1.0),
                    tap: isVector ? .none : .point(p)))
                interaction.activeRoutePoints.append(.init(id: p.name, key: key,
                                                           coordinate: Self.displayCoordinate(for: p.coordinate)))

                if showMapLabels && !isVector && idx < points.count - 1 && idx < legDistances.count {
                    let a = Self.displayCoordinate(for: p.coordinate)
                    let b = Self.displayCoordinate(for: points[idx + 1].coordinate)
                    annotations.append(RutMKAnnotationSpec(
                        key: RutMKAnnotationSpec.legDistanceKeyPrefix + "\(idx)",
                        coordinate: RutMKGeoPoint(CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2.0,
                                                                         longitude: (a.longitude + b.longitude) / 2.0)),
                        zPriority: MapAnnotationZ.activeRoute,
                        marker: .legDistance(String(format: "%.1fN", legDistances[idx])),
                        tap: .none))
                }
            }
        }

        // Vector mode: tap selection, drawing preview and vertex editing.
        interaction.vector = RutMKVectorState(
            isActive: isVector,
            tool: vectorStore.activeTool,
            drawingVertices: vectorStore.drawing.vertices,
            drawingGhost: vectorStore.drawing.ghostCoord,
            isEditing: vectorStore.isEditingShape,
            editingVertices: vectorStore.editingVertices,
            editingIsPolygon: vectorStore.editingShapeIsPolygon,
            editingSupportsInsert: vectorStore.editingShapeSupportsVertexInsert,
            points: vectorPoints,
            polylines: vectorPolylines,
            polygons: vectorPolygons,
            circles: vectorCircles)

        return RutMKContent(overlays: overlays, annotations: annotations, interaction: interaction)
    }

    private func databaseSymbol(key: String, coordinate: CLLocationCoordinate2D,
                                bgColor: Color, iconName: String, label: String,
                                opacity: Double, scale: Double, tap: RutMKTap) -> RutMKAnnotationSpec {
        RutMKAnnotationSpec(
            key: key,
            coordinate: RutMKGeoPoint(Self.displayCoordinate(for: coordinate)),
            zPriority: MapAnnotationZ.database,
            marker: .databaseSymbol(bgColor: bgColor, iconName: iconName, label: label,
                                    showLabel: showMapLabels, opacity: opacity, scale: scale),
            tap: tap)
    }

    private func waypointType(for point: RouteMapPoint) -> WaypointType? {
        guard point.kind == .userWaypoint else { return nil }
        return navStore.document.userWaypoints.first(where: { $0.id == point.name })?.type
    }

    /// Starts where the shared camera was left; otherwise on the active route's first point
    /// or the first user/system point.
    private func initialRegion() -> MKCoordinateRegion? {
        if let region = core.mapCamera.region { return region }
        func region(_ c: CLLocationCoordinate2D) -> MKCoordinateRegion {
            MKCoordinateRegion(center: Self.displayCoordinate(for: c),
                               span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
        }
        let doc = navStore.document
        if let route = navStore.activeRoute, let first = navStore.mapPoints(for: route).first {
            return region(first.coordinate)
        }
        if let ap = doc.userAirports.first { return region(ap.coordinate) }
        if let nav = doc.userNavaids.first { return region(nav.coordinate) }
        if let wp = doc.userWaypoints.first { return region(wp.coordinate) }
        if let sysAp = doc.systemAirports.first { return region(sysAp.coordinate) }
        return nil
    }

    // MARK: Vector drawing

    /// A tap adds a vertex; a point is committed at once.
    private func handleDrawTap(_ coordinate: CLLocationCoordinate2D) {
        vectorStore.drawing.handleTap(at: coordinate, tool: vectorStore.activeTool)
        if vectorStore.activeTool == .point && vectorStore.drawing.isActive {
            vectorStore.commitDrawing(name: "Point")
        }
    }

    // MARK: Drag results & confirmations

    private func handleDragEnded(_ result: RutMKDragResult) {
        switch result {
        case let .airport(id, coordinate):
            pendingMove = PendingMove(kind: .airport(id: id), newCoordinate: coordinate)
            showMoveConfirm = true
        case let .navaid(id, coordinate):
            pendingMove = PendingMove(kind: .navaid(id: id), newCoordinate: coordinate)
            showMoveConfirm = true
        case let .waypoint(id, coordinate):
            pendingMove = PendingMove(kind: .waypoint(id: id), newCoordinate: coordinate)
            showMoveConfirm = true
        case let .routePoint(index, coordinate):
            guard let route = navStore.activeRoute else { return }
            let points = navStore.mapPoints(for: route)
            let pointId = index < points.count ? points[index].name : "point"
            pendingRoutePointMove = PendingRoutePointMove(routeId: route.id, pointIndex: index,
                                                          pointId: pointId, newCoordinate: coordinate)
            showRoutePointMoveConfirm = true
        case let .insert(segmentIndex, snapRef, coordinate):
            pendingInsert = PendingInsert(segmentIndex: segmentIndex, snapRef: snapRef, coordinate: coordinate)
            showLineInsertAlert = true
        }
    }

    private func moveConfirmMessage(for move: PendingMove) -> String {
        let name: String
        switch move.kind {
        case .airport(let id): name = id
        case .navaid(let id):  name = id
        case .waypoint(let id): name = id
        }
        return "Move \(name) to \(String(format: "%.4f", move.newCoordinate.latitude))°N, \(String(format: "%.4f", move.newCoordinate.longitude))°E?"
    }

    private func confirmPendingMove() {
        guard let move = pendingMove else { return }
        switch move.kind {
        case .airport(let id):
            guard let ap = navStore.document.userAirports.first(where: { $0.id == id }) else { return }
            navStore.updateAirport(
                originalId: ap.id, newId: ap.id, newName: ap.name,
                latitude: move.newCoordinate.latitude,
                longitude: move.newCoordinate.longitude,
                elevation: ap.elevation, magVar: ap.magneticVariation)
        case .navaid(let id):
            guard let nv = navStore.document.userNavaids.first(where: { $0.id == id }) else { return }
            navStore.updateNavaid(
                originalId: nv.id, newId: nv.id, newName: nv.name,
                latitude: move.newCoordinate.latitude,
                longitude: move.newCoordinate.longitude,
                elevation: nv.elevation, magVar: nv.magneticVariation,
                frequency: nv.frequency)
        case .waypoint(let id):
            // Only off-route waypoints are draggable, so nothing but the position changes.
            guard let wp = navStore.document.userWaypoints.first(where: { $0.id == id }) else { return }
            navStore.updateWaypoint(
                originalId: wp.id, newName: wp.name, newId: wp.id, type: wp.type,
                latitude: move.newCoordinate.latitude,
                longitude: move.newCoordinate.longitude,
                elevation: wp.elevation)
        }
    }

    private var lineInsertAlertTitle: String {
        if let ins = pendingInsert, let snap = ins.snapRef {
            return "Insert \(snap.refId) as via point?"
        }
        return "Create Via Waypoint?"
    }

    private func confirmLineInsert() {
        guard let ins = pendingInsert, let route = navStore.activeRoute else {
            pendingInsert = nil; return
        }
        if let snap = ins.snapRef {
            navStore.insertRoutePoint(routeId: route.id, at: ins.segmentIndex + 1, ref: snap)
        } else {
            let newId = navStore.nextAvailableId(for: .wpt)
            navStore.createUserWaypoint(
                UserWaypoint(id: newId, name: newId, type: .wpt,
                             latitude: ins.coordinate.latitude,
                             longitude: ins.coordinate.longitude,
                             elevation: 0)
            )
            navStore.insertRoutePoint(
                routeId: route.id, at: ins.segmentIndex + 1,
                ref: RoutePointRef(kind: .userWaypoint, refId: newId)
            )
            if navStore.autoRenumberWaypoints {
                navStore.renumberWaypoints(forRouteIds: [route.id])
            }
        }
        pendingInsert = nil
    }

    // MARK: Helpers

    private static func isZero(_ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude) < 0.0000001 && abs(c.longitude) < 0.0000001
    }

    private static func displayCoordinate(for c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        isZero(c) ? CLLocationCoordinate2D(latitude: 0.000001, longitude: 0.000001) : c
    }
}

// MARK: - Content model

private struct RutMKGeoPoint: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ c: CLLocationCoordinate2D) {
        latitude = c.latitude
        longitude = c.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RutMKContent {
    /// Bottom to top.
    var overlays: [RutMKOverlaySpec]
    var annotations: [RutMKAnnotationSpec]
    var interaction: RutMKInteraction
}

/// What a long press can grab, in screen hit-test order (display coordinates).
private struct RutMKInteraction {
    struct Point {
        let id: String
        let key: String
        let coordinate: CLLocationCoordinate2D
    }

    struct SnapCandidate {
        let ref: RoutePointRef
        let coordinate: CLLocationCoordinate2D
    }

    /// Database markers and route points are only draggable in navigation mode.
    var isNavigation = true
    /// User airports/navaids/waypoints that are not part of any route.
    var airports: [Point] = []
    var navaids: [Point] = []
    var waypoints: [Point] = []
    var activeRouteId: UUID?
    var activeRoutePoints: [Point] = []
    var snapCandidates: [SnapCandidate] = []
    var vector = RutMKVectorState()
}

/// Vector-mode state the map needs for tap selection, the drawing preview and vertex editing.
private struct RutMKVectorState {
    var isActive = false
    var tool: DrawingTool = .none
    var drawingVertices: [CLLocationCoordinate2D] = []
    var drawingGhost: CLLocationCoordinate2D?
    var isEditing = false
    var editingVertices: [CLLocationCoordinate2D] = []
    var editingIsPolygon = false
    var editingSupportsInsert = false
    /// Visible user shapes (the store only returns non-system ones), for tap selection.
    var points: [FlatVectorPoint] = []
    var polylines: [FlatVectorPolyline] = []
    var polygons: [FlatVectorPolygon] = []
    var circles: [FlatVectorCircle] = []

    var showsDrawingPreview: Bool { isActive && tool != .none && !drawingVertices.isEmpty }
}

private struct RutMKOverlaySpec: Equatable {
    enum Geometry: Equatable {
        case airspace([AirspaceZone])
        case polygon([RutMKGeoPoint])
        case polyline([RutMKGeoPoint])
        case circle(center: RutMKGeoPoint, radiusMeters: Double)

        static func == (lhs: Geometry, rhs: Geometry) -> Bool {
            switch (lhs, rhs) {
            case let (.airspace(a), .airspace(b)):   return a.map(\.id) == b.map(\.id)
            case let (.polygon(a), .polygon(b)):     return a == b
            case let (.polyline(a), .polyline(b)):   return a == b
            case let (.circle(c1, r1), .circle(c2, r2)): return c1 == c2 && r1 == r2
            default: return false
            }
        }
    }

    enum Style: Equatable {
        case airspace(AirspaceZone.ZoneType)
        case vectorPolygon(VectorStyle, selected: Bool)
        case vectorPolyline(VectorStyle, selected: Bool)
        case vectorCircle(VectorStyle, selected: Bool)
        case route(active: Bool, opacity: Double)
    }

    let key: String
    let geometry: Geometry
    let style: Style

    static func activeRouteKey(_ routeId: UUID) -> String { "route-active-\(routeId)" }

    func makeOverlay() -> MKOverlay {
        switch geometry {
        case .airspace(let zones):
            return MKMultiPolygon(zones.map { MKPolygon(coordinates: $0.coordinates, count: $0.coordinates.count) })
        case .polygon(let points):
            let coords = points.map(\.coordinate)
            return MKPolygon(coordinates: coords, count: coords.count)
        case .polyline(let points):
            let coords = points.map(\.coordinate)
            return MKPolyline(coordinates: coords, count: coords.count)
        case let .circle(center, radius):
            return MKCircle(center: center.coordinate, radius: radius)
        }
    }

    /// Fill, stroke and width for each overlay kind.
    func makeRenderer(for overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer: MKOverlayPathRenderer
        switch overlay {
        case let o as MKMultiPolygon: renderer = MKMultiPolygonRenderer(multiPolygon: o)
        case let o as MKPolygon:      renderer = MKPolygonRenderer(polygon: o)
        case let o as MKPolyline:     renderer = MKPolylineRenderer(polyline: o)
        case let o as MKCircle:       renderer = MKCircleRenderer(circle: o)
        default:                      return MKOverlayRenderer(overlay: overlay)
        }

        func applyVectorStroke(_ s: VectorStyle, selected: Bool) {
            renderer.strokeColor = UIColor(selected ? Color.white : Color(hex: s.strokeColor).opacity(s.opacity))
            renderer.lineWidth = selected ? s.strokeWidth + 2 : s.strokeWidth
        }

        switch style {
        case .airspace(let type):
            renderer.fillColor = UIColor(type.fillColor)
            renderer.strokeColor = UIColor(type.strokeColor)
            renderer.lineWidth = 1.5
        case let .vectorPolygon(s, selected):
            renderer.fillColor = UIColor(Color(hex: s.fillColor).opacity(s.opacity))
            applyVectorStroke(s, selected: selected)
        case let .vectorPolyline(s, selected):
            applyVectorStroke(s, selected: selected)
        case let .vectorCircle(s, selected):
            renderer.fillColor = UIColor(Color(hex: s.fillColor).opacity(s.opacity * 0.3))
            applyVectorStroke(s, selected: selected)
        case let .route(active, opacity):
            renderer.strokeColor = UIColor((active ? Color.blue : Color.blue.opacity(0.3)).opacity(opacity))
            renderer.lineWidth = 6
        }
        return renderer
    }
}

private struct RutMKAnnotationSpec: Equatable {
    let key: String
    let coordinate: RutMKGeoPoint
    let zPriority: Float
    let marker: RutMKMarker
    let tap: RutMKTap

    static let legDistanceKeyPrefix = "d-"
    static func activeRoutePointKey(_ index: Int) -> String { "a-\(index)" }
}

private enum RutMKMarker: Equatable {
    case databaseSymbol(bgColor: Color, iconName: String, label: String, showLabel: Bool, opacity: Double, scale: Double)
    case databaseWaypoint(label: String, isZero: Bool, showLabel: Bool, opacity: Double, scale: Double)
    case routePoint(name: String, kind: RoutePointKind, waypointType: WaypointType?,
                    color: Color, contentColor: Color, showLabel: Bool, opacity: Double, scale: Double)
    case legDistance(String)
    case vectorPoint(name: String, style: VectorStyle, selected: Bool, showName: Bool)
    case insertGhost(isSnapping: Bool, snapId: String?)
}

private enum RutMKTap: Equatable {
    case none
    case point(name: String, kind: RoutePointKind, indexInRoute: Int, coordinate: RutMKGeoPoint)
    case selectShape(id: UUID, layerId: UUID)

    static func point(_ p: RouteMapPoint) -> RutMKTap {
        .point(name: p.name, kind: p.kind, indexInRoute: p.indexInRoute, coordinate: RutMKGeoPoint(p.coordinate))
    }

    static func point(name: String, kind: RoutePointKind, coordinate: CLLocationCoordinate2D) -> RutMKTap {
        .point(name: name, kind: kind, indexInRoute: -1, coordinate: RutMKGeoPoint(coordinate))
    }
}

private enum RutMKDragResult {
    case airport(id: String, coordinate: CLLocationCoordinate2D)
    case navaid(id: String, coordinate: CLLocationCoordinate2D)
    case waypoint(id: String, coordinate: CLLocationCoordinate2D)
    case routePoint(index: Int, coordinate: CLLocationCoordinate2D)
    case insert(segmentIndex: Int, snapRef: RoutePointRef?, coordinate: CLLocationCoordinate2D)
}

private struct RutMKHandlers {
    var pointTap: ((RouteMapPoint) -> Void)?
    var longPress: ((CLLocationCoordinate2D) -> Void)?
    var selectShape: (UUID, UUID) -> Void
    var deselectShape: () -> Void
    var drawTap: (CLLocationCoordinate2D) -> Void
    var moveEditVertex: (Int, CLLocationCoordinate2D) -> Void
    var insertEditVertex: (Int, CLLocationCoordinate2D) -> Void
    var dragEnded: (RutMKDragResult) -> Void
    var labelsVisibleChanged: (Bool) -> Void
    var regionChanged: (MKCoordinateRegion) -> Void
}

private extension RutMapStyle {
    var mkConfiguration: MKMapConfiguration {
        switch self {
        case .hybrid:    return MKHybridMapConfiguration(elevationStyle: .flat)
        case .standard:  return MKStandardMapConfiguration(elevationStyle: .flat)
        case .satellite: return MKImageryMapConfiguration(elevationStyle: .flat)
        }
    }
}

// MARK: - UIKit bridge

private struct RutMKRepresentable: UIViewRepresentable {
    let content: RutMKContent
    let mapStyle: RutMapStyle
    /// True while a dropped route point awaits confirmation; the drag visuals stay put until then.
    let holdRoutePointDrag: Bool
    let initialRegion: () -> MKCoordinateRegion?
    let handlers: RutMKHandlers

    func makeCoordinator() -> RutMKCoordinator { RutMKCoordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        let coordinator = context.coordinator
        mapView.delegate = coordinator
        mapView.register(RutMKHostedMarkerView.self,
                         forAnnotationViewWithReuseIdentifier: RutMKHostedMarkerView.reuseIdentifier)
        if let region = initialRegion() {
            mapView.setRegion(region, animated: false)
        }

        let longPress = UILongPressGestureRecognizer(target: coordinator,
                                                     action: #selector(RutMKCoordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.delegate = coordinator
        mapView.addGestureRecognizer(longPress)

        // Vector mode: taps select shapes or add drawing vertices; touching an edit handle drags it.
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(RutMKCoordinator.handleMapTap(_:)))
        tap.cancelsTouchesInView = false   // marker taps (SwiftUI) must still arrive, without delay
        tap.delaysTouchesEnded = false
        tap.delegate = coordinator
        mapView.addGestureRecognizer(tap)

        let vertexPress = UILongPressGestureRecognizer(target: coordinator,
                                                       action: #selector(RutMKCoordinator.handleVertexPress(_:)))
        vertexPress.minimumPressDuration = 0
        vertexPress.delegate = coordinator
        mapView.addGestureRecognizer(vertexPress)
        coordinator.vertexPressRecognizer = vertexPress

        coordinator.installVectorOverlay(in: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.handlers = handlers
        coordinator.interaction = content.interaction
        coordinator.applyStyle(mapStyle, to: mapView)
        coordinator.applyOverlays(content.overlays, to: mapView)
        coordinator.applyAnnotations(content.annotations, to: mapView)
        coordinator.updateRouteDragHold(holdRoutePointDrag, in: mapView)
        coordinator.redrawVectorOverlay(in: mapView)
    }
}

private final class RutMKCoordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
    var handlers: RutMKHandlers?
    var interaction: RutMKInteraction?

    private var overlaysByKey: [String: (spec: RutMKOverlaySpec, overlay: MKOverlay)] = [:]
    private var overlaySpecs: [ObjectIdentifier: RutMKOverlaySpec] = [:]
    private var annotationsByKey: [String: RutMKMarkerAnnotation] = [:]
    private var lastOverlaySpecs: [RutMKOverlaySpec] = []
    private var lastAnnotationSpecs: [RutMKAnnotationSpec] = []
    private var appliedStyle: RutMapStyle?
    private var labelsVisible: Bool?

    // MARK: Applying content

    func applyStyle(_ style: RutMapStyle, to mapView: MKMapView) {
        guard style != appliedStyle else { return }
        appliedStyle = style
        mapView.preferredConfiguration = style.mkConfiguration
    }

    /// Replaces only overlays whose spec changed, inserting new ones at their drawing position.
    func applyOverlays(_ allSpecs: [RutMKOverlaySpec], to mapView: MKMapView) {
        lastOverlaySpecs = allSpecs
        let specs = allSpecs.filter { !suppressedOverlayKeys.contains($0.key) }

        var desired: [String: RutMKOverlaySpec] = [:]
        for spec in specs { desired[spec.key] = spec }

        var stale: [MKOverlay] = []
        for (key, entry) in overlaysByKey where desired[key] != entry.spec {
            stale.append(entry.overlay)
            overlaySpecs[ObjectIdentifier(entry.overlay)] = nil
            overlaysByKey[key] = nil
        }
        if !stale.isEmpty { mapView.removeOverlays(stale) }

        // Kept overlays must still be in drawing order (e.g. after reordering layers);
        // otherwise start over so the insert indices below are right.
        let keptOrder = mapView.overlays(in: .aboveLabels).compactMap { overlaySpecs[ObjectIdentifier($0)]?.key }
        let desiredKeptOrder = specs.map(\.key).filter { overlaysByKey[$0] != nil }
        if keptOrder != desiredKeptOrder {
            mapView.removeOverlays(overlaysByKey.values.map(\.overlay))
            overlaysByKey.removeAll()
            overlaySpecs.removeAll()
        }

        for (index, spec) in specs.enumerated() where overlaysByKey[spec.key] == nil {
            let overlay = spec.makeOverlay()
            overlaySpecs[ObjectIdentifier(overlay)] = spec
            overlaysByKey[spec.key] = (spec, overlay)
            mapView.insertOverlay(overlay, at: index, level: .aboveLabels)
        }
    }

    /// Adds/removes annotations by key and reconfigures the views of changed ones in place.
    func applyAnnotations(_ allSpecs: [RutMKAnnotationSpec], to mapView: MKMapView) {
        lastAnnotationSpecs = allSpecs
        let specs = hideLegDistances
            ? allSpecs.filter { !$0.key.hasPrefix(RutMKAnnotationSpec.legDistanceKeyPrefix) }
            : allSpecs

        var desired: [String: RutMKAnnotationSpec] = [:]
        for spec in specs { desired[spec.key] = spec }

        var stale: [MKAnnotation] = []
        for (key, annotation) in annotationsByKey {
            guard let spec = desired[key] else {
                stale.append(annotation)
                annotationsByKey[key] = nil
                continue
            }
            guard spec != annotation.spec else { continue }
            if let pinned = pinnedCoordinates[key] {
                annotation.coordinate = pinned
            } else if spec.coordinate != annotation.spec.coordinate {
                annotation.coordinate = spec.coordinate.coordinate
            }
            annotation.spec = spec
            if let view = mapView.view(for: annotation) as? RutMKHostedMarkerView {
                configure(view, for: annotation)
            }
        }
        if !stale.isEmpty { mapView.removeAnnotations(stale) }

        var added: [RutMKMarkerAnnotation] = []
        for (key, spec) in desired where annotationsByKey[key] == nil {
            let annotation = RutMKMarkerAnnotation(spec: spec)
            if let pinned = pinnedCoordinates[key] { annotation.coordinate = pinned }
            annotationsByKey[key] = annotation
            added.append(annotation)
        }
        if !added.isEmpty { mapView.addAnnotations(added) }
    }

    private func reapplyContent(to mapView: MKMapView) {
        applyOverlays(lastOverlaySpecs, to: mapView)
        applyAnnotations(lastAnnotationSpecs, to: mapView)
    }

    private func configure(_ view: RutMKHostedMarkerView, for annotation: RutMKMarkerAnnotation) {
        let key = annotation.spec.key
        view.configure(marker: annotation.spec.marker, zPriority: annotation.spec.zPriority) { [weak self] in
            self?.handleTap(key: key)
        }
    }

    private func handleTap(key: String) {
        guard let spec = annotationsByKey[key]?.spec, let handlers else { return }
        switch spec.tap {
        case .none:
            break
        case let .point(name, kind, indexInRoute, coordinate):
            handlers.pointTap?(RouteMapPoint(coordinate: coordinate.coordinate, name: name,
                                             indexInRoute: indexInRoute, kind: kind))
        case let .selectShape(id, layerId):
            handlers.selectShape(id, layerId)
        }
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        overlaySpecs[ObjectIdentifier(overlay)]?.makeRenderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let annotation = annotation as? RutMKMarkerAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: RutMKHostedMarkerView.reuseIdentifier,
                                                         for: annotation)
        guard let markerView = view as? RutMKHostedMarkerView else { return view }
        configure(markerView, for: annotation)
        if draggedKeys.contains(annotation.spec.key) {
            markerView.transform = Self.dragScale
        }
        return markerView
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
        // Taps are handled by the marker's SwiftUI content; don't keep MapKit selection state.
        mapView.deselectAnnotation(annotation, animated: false)
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        // Keeps the drawing preview and edit handles glued to the map while it moves.
        redrawVectorOverlay(in: mapView)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        let region = mapView.region
        let labels = region.span.latitudeDelta < 0.68
        // Deferred: this can fire while SwiftUI is applying an update.
        DispatchQueue.main.async { [weak self] in
            guard let self, let handlers = self.handlers else { return }
            if labels != self.labelsVisible {
                self.labelsVisible = labels
                handlers.labelsVisibleChanged(labels)
            }
            handlers.regionChanged(region)
        }
    }

    // MARK: Long press: drag markers, insert route points, add points

    private enum DragTarget {
        case airport(id: String, key: String)
        case navaid(id: String, key: String)
        case waypoint(id: String, key: String)
        case routePoint(index: Int)
        case lineSegment(index: Int)
    }

    private static let dragScale = CGAffineTransform(scaleX: 1.2, y: 1.2)

    private var pressStartCoordinate: CLLocationCoordinate2D?
    private var dragTarget: DragTarget?
    /// Annotation keys whose position follows the finger instead of the content.
    private var pinnedCoordinates: [String: CLLocationCoordinate2D] = [:]
    private var draggedKeys: Set<String> = []
    private var suppressedOverlayKeys: Set<String> = []
    private var hideLegDistances = false
    private var routeDragPoints: [CLLocationCoordinate2D] = []
    private var routeDragLine: RutMKDragLineView?
    /// Index of a dropped route point whose confirmation dialog is (about to be) shown.
    private var heldRoutePointIndex: Int?
    private var insertGhost: RutMKMarkerAnnotation?
    private var insertSnapRef: RoutePointRef?

    @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)

        switch recognizer.state {
        case .began:
            pressStartCoordinate = coordinate
            if let vector = interaction?.vector, vector.isActive, vector.isEditing {
                // Long press on an outline segment inserts a vertex there and drags it.
                guard editDragIndex == nil, vector.editingSupportsInsert,
                      let hit = nearestEditSegment(to: point, in: mapView, state: vector) else { return }
                handlers?.insertEditVertex(hit.insertIndex, hit.coordinate)
                var vertices = vector.editingVertices
                vertices.insert(hit.coordinate, at: hit.insertIndex)
                beginEditVertexDrag(index: hit.insertIndex, vertices: vertices, owner: recognizer, in: mapView)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                return
            }
            guard let interaction, interaction.isNavigation,
                  let target = findDragTarget(at: point, in: mapView, model: interaction) else { return }
            beginDrag(target, coordinate: coordinate, in: mapView, model: interaction)
            updateDrag(at: point, coordinate: coordinate, in: mapView)
        case .changed:
            if editDragOwner === recognizer {
                moveEditVertexDrag(to: coordinate, in: mapView)
            } else {
                updateDrag(at: point, coordinate: coordinate, in: mapView)
            }
        case .ended:
            if editDragOwner === recognizer {
                endEditVertexDrag(in: mapView)
            } else if dragTarget != nil {
                endDrag(at: coordinate, in: mapView)
            } else if interaction?.isNavigation == true, let start = pressStartCoordinate {
                // No marker or route line under the finger: add a point where the press started.
                handlers?.longPress?(start)
            }
            pressStartCoordinate = nil
        case .cancelled, .failed:
            if editDragOwner === recognizer { endEditVertexDrag(in: mapView) }
            cancelDrag(in: mapView)
            pressStartCoordinate = nil
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func beginDrag(_ target: DragTarget, coordinate: CLLocationCoordinate2D,
                           in mapView: MKMapView, model: RutMKInteraction) {
        dragTarget = target
        setMapGesturesLocked(true, in: mapView)

        switch target {
        case let .airport(_, key), let .navaid(_, key), let .waypoint(_, key):
            grabAnnotation(key: key, in: mapView)

        case .routePoint(let index):
            routeDragPoints = model.activeRoutePoints.map(\.coordinate)
            // The live line replaces the route polyline; leg distances are stale while dragging.
            if let routeId = model.activeRouteId {
                suppressedOverlayKeys.insert(RutMKOverlaySpec.activeRouteKey(routeId))
            }
            hideLegDistances = true
            reapplyContent(to: mapView)
            grabAnnotation(key: RutMKAnnotationSpec.activeRoutePointKey(index), in: mapView)
            let line = RutMKDragLineView(frame: mapView.bounds)
            mapView.addSubview(line)
            routeDragLine = line

        case .lineSegment:
            insertSnapRef = nil
            let ghost = RutMKMarkerAnnotation(spec: Self.ghostSpec(at: coordinate, snap: nil))
            insertGhost = ghost
            mapView.addAnnotation(ghost)
        }
    }

    private func updateDrag(at point: CGPoint, coordinate: CLLocationCoordinate2D, in mapView: MKMapView) {
        guard let dragTarget else { return }
        switch dragTarget {
        case let .airport(_, key), let .navaid(_, key), let .waypoint(_, key):
            moveAnnotation(key: key, to: coordinate)

        case .routePoint(let index):
            moveAnnotation(key: RutMKAnnotationSpec.activeRoutePointKey(index), to: coordinate)
            var coords = routeDragPoints
            if index < coords.count { coords[index] = coordinate }
            routeDragLine?.setPoints(coords.map { mapView.convert($0, toPointTo: routeDragLine) })

        case .lineSegment:
            guard let ghost = insertGhost else { return }
            ghost.coordinate = coordinate
            let snap = interaction.flatMap { findSnapTarget(at: point, in: mapView, model: $0) }
            if snap?.refId != insertSnapRef?.refId || snap?.kind != insertSnapRef?.kind {
                insertSnapRef = snap
                ghost.spec = Self.ghostSpec(at: coordinate, snap: snap)
                if let view = mapView.view(for: ghost) as? RutMKHostedMarkerView {
                    configure(view, for: ghost)
                }
            }
        }
    }

    private func endDrag(at coordinate: CLLocationCoordinate2D, in mapView: MKMapView) {
        guard let target = dragTarget else { return }
        dragTarget = nil
        setMapGesturesLocked(false, in: mapView)

        switch target {
        case let .airport(id, key):
            releaseAnnotation(key: key, in: mapView)   // back in place until the move is confirmed
            handlers?.dragEnded(.airport(id: id, coordinate: coordinate))
        case let .navaid(id, key):
            releaseAnnotation(key: key, in: mapView)
            handlers?.dragEnded(.navaid(id: id, coordinate: coordinate))
        case let .waypoint(id, key):
            releaseAnnotation(key: key, in: mapView)
            handlers?.dragEnded(.waypoint(id: id, coordinate: coordinate))
        case .routePoint(let index):
            heldRoutePointIndex = index                 // keep the dropped position during the dialog
            handlers?.dragEnded(.routePoint(index: index, coordinate: coordinate))
        case .lineSegment(let index):
            let insertCoordinate = insertGhost?.coordinate ?? coordinate
            let snapRef = insertSnapRef
            removeInsertGhost(from: mapView)
            handlers?.dragEnded(.insert(segmentIndex: index, snapRef: snapRef, coordinate: insertCoordinate))
        }
    }

    private func cancelDrag(in mapView: MKMapView) {
        guard let target = dragTarget else { return }
        dragTarget = nil
        setMapGesturesLocked(false, in: mapView)

        switch target {
        case let .airport(_, key), let .navaid(_, key), let .waypoint(_, key):
            releaseAnnotation(key: key, in: mapView)
        case .routePoint(let index):
            finishRouteDrag(index: index, in: mapView)
        case .lineSegment:
            removeInsertGhost(from: mapView)
        }
    }

    /// Called on every SwiftUI update, after the content is applied. Once the route-point
    /// confirmation is answered (moved or cancelled) the live drag visuals are removed.
    func updateRouteDragHold(_ hold: Bool, in mapView: MKMapView) {
        guard !hold, let index = heldRoutePointIndex else { return }
        heldRoutePointIndex = nil
        finishRouteDrag(index: index, in: mapView)
    }

    private func finishRouteDrag(index: Int, in mapView: MKMapView) {
        routeDragLine?.removeFromSuperview()
        routeDragLine = nil
        routeDragPoints = []
        suppressedOverlayKeys.removeAll()
        hideLegDistances = false
        releaseAnnotation(key: RutMKAnnotationSpec.activeRoutePointKey(index), in: mapView)
        reapplyContent(to: mapView)
    }

    private func grabAnnotation(key: String, in mapView: MKMapView) {
        guard let annotation = annotationsByKey[key] else { return }
        pinnedCoordinates[key] = annotation.coordinate
        draggedKeys.insert(key)
        mapView.view(for: annotation)?.transform = Self.dragScale
    }

    private func moveAnnotation(key: String, to coordinate: CLLocationCoordinate2D) {
        pinnedCoordinates[key] = coordinate
        annotationsByKey[key]?.coordinate = coordinate
    }

    private func releaseAnnotation(key: String, in mapView: MKMapView) {
        pinnedCoordinates[key] = nil
        draggedKeys.remove(key)
        guard let annotation = annotationsByKey[key] else { return }
        annotation.coordinate = annotation.spec.coordinate.coordinate
        mapView.view(for: annotation)?.transform = .identity
    }

    private func removeInsertGhost(from mapView: MKMapView) {
        if let ghost = insertGhost { mapView.removeAnnotation(ghost) }
        insertGhost = nil
        insertSnapRef = nil
    }

    private func setMapGesturesLocked(_ locked: Bool, in mapView: MKMapView) {
        mapView.isScrollEnabled = !locked
        mapView.isZoomEnabled = !locked
        mapView.isRotateEnabled = !locked
        mapView.isPitchEnabled = !locked
    }

    private static func ghostSpec(at coordinate: CLLocationCoordinate2D, snap: RoutePointRef?) -> RutMKAnnotationSpec {
        RutMKAnnotationSpec(key: "ghost-insert",
                            coordinate: RutMKGeoPoint(coordinate),
                            zPriority: MapAnnotationZ.insertGhost,
                            marker: .insertGhost(isSnapping: snap != nil, snapId: snap?.refId),
                            tap: .none)
    }

    // MARK: Vector mode: tap selection, drawing, vertex editing

    weak var vertexPressRecognizer: UILongPressGestureRecognizer?
    private var vectorOverlay: RutMKVectorOverlayView?
    /// Vertex being dragged, the recognizer driving it, and its live positions (ahead of the store).
    private var editDragIndex: Int?
    private weak var editDragOwner: UIGestureRecognizer?
    private var editDragVertices: [CLLocationCoordinate2D] = []

    func installVectorOverlay(in mapView: MKMapView) {
        let overlay = RutMKVectorOverlayView(frame: mapView.bounds)
        mapView.addSubview(overlay)
        vectorOverlay = overlay
    }

    func redrawVectorOverlay(in mapView: MKMapView) {
        guard let overlay = vectorOverlay else { return }
        let state = interaction?.vector ?? RutMKVectorState()
        func screen(_ coordinates: [CLLocationCoordinate2D]) -> [CGPoint] {
            coordinates.map { mapView.convert($0, toPointTo: overlay) }
        }

        if state.showsDrawingPreview {
            overlay.showDrawing(tool: state.tool,
                                vertices: screen(state.drawingVertices),
                                ghost: state.drawingGhost.map { mapView.convert($0, toPointTo: overlay) })
        } else {
            overlay.clearDrawing()
        }

        let editVertices = editDragIndex != nil ? editDragVertices : state.editingVertices
        if state.isActive && state.isEditing && !editVertices.isEmpty {
            overlay.showEditing(vertices: screen(editVertices), closed: state.editingIsPolygon)
        } else {
            overlay.clearEditing()
        }
    }

    @objc func handleMapTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let mapView = recognizer.view as? MKMapView,
              let state = interaction?.vector, state.isActive else { return }
        let point = recognizer.location(in: mapView)
        if state.tool != .none {
            handlers?.drawTap(mapView.convert(point, toCoordinateFrom: mapView))
        } else if !state.isEditing {
            if let hit = findNearestUserShape(at: point, in: mapView, state: state) {
                handlers?.selectShape(hit.shapeId, hit.layerId)
            } else {
                handlers?.deselectShape()
            }
        }
    }

    /// Fires on touch-down near an edit handle (see shouldReceive), so the map can't start panning.
    @objc func handleVertexPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        switch recognizer.state {
        case .began:
            guard editDragIndex == nil, let vector = interaction?.vector, vector.isActive, vector.isEditing,
                  let index = nearestEditVertex(to: point, in: mapView, vertices: vector.editingVertices) else { return }
            beginEditVertexDrag(index: index, vertices: vector.editingVertices, owner: recognizer, in: mapView)
        case .changed:
            guard editDragOwner === recognizer else { return }
            moveEditVertexDrag(to: mapView.convert(point, toCoordinateFrom: mapView), in: mapView)
        case .ended, .cancelled, .failed:
            guard editDragOwner === recognizer else { return }
            endEditVertexDrag(in: mapView)
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === vertexPressRecognizer else { return true }
        guard let mapView = gestureRecognizer.view as? MKMapView,
              let vector = interaction?.vector, vector.isActive, vector.isEditing else { return false }
        return nearestEditVertex(to: touch.location(in: mapView), in: mapView,
                                 vertices: vector.editingVertices) != nil
    }

    private func beginEditVertexDrag(index: Int, vertices: [CLLocationCoordinate2D],
                                     owner: UIGestureRecognizer, in mapView: MKMapView) {
        editDragIndex = index
        editDragOwner = owner
        editDragVertices = vertices
        setMapGesturesLocked(true, in: mapView)
        redrawVectorOverlay(in: mapView)
    }

    private func moveEditVertexDrag(to coordinate: CLLocationCoordinate2D, in mapView: MKMapView) {
        guard let index = editDragIndex, index < editDragVertices.count else { return }
        editDragVertices[index] = coordinate
        redrawVectorOverlay(in: mapView)
        handlers?.moveEditVertex(index, coordinate)
    }

    private func endEditVertexDrag(in mapView: MKMapView) {
        guard editDragIndex != nil else { return }
        editDragIndex = nil
        editDragOwner = nil
        editDragVertices = []
        setMapGesturesLocked(false, in: mapView)
        redrawVectorOverlay(in: mapView)
    }

    /// Nearest edit handle within 44 pt.
    private func nearestEditVertex(to point: CGPoint, in mapView: MKMapView,
                                   vertices: [CLLocationCoordinate2D]) -> Int? {
        let threshold: CGFloat = 44
        var best: (distance: CGFloat, index: Int)?
        for (i, vertex) in vertices.enumerated() {
            let p = mapView.convert(vertex, toPointTo: mapView)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < threshold && (best == nil || d < best!.distance) { best = (d, i) }
        }
        return best?.index
    }

    /// Nearest outline segment within 22 pt (polygons include the closing segment):
    /// where a new vertex goes, and the touch projected onto the segment.
    private func nearestEditSegment(to point: CGPoint, in mapView: MKMapView,
                                    state: RutMKVectorState) -> (insertIndex: Int, coordinate: CLLocationCoordinate2D)? {
        let vertices = state.editingVertices
        guard vertices.count >= 2 else { return nil }
        let threshold: CGFloat = 22
        let segmentCount = state.editingIsPolygon ? vertices.count : vertices.count - 1

        var best: (distance: CGFloat, index: Int, point: CGPoint)?
        for i in 0 ..< segmentCount {
            let a = mapView.convert(vertices[i], toPointTo: mapView)
            let b = mapView.convert(vertices[(i + 1) % vertices.count], toPointTo: mapView)
            let dx = b.x - a.x, dy = b.y - a.y
            let lenSq = dx * dx + dy * dy
            guard lenSq > 0 else { continue }
            let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq))
            let projected = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = hypot(point.x - projected.x, point.y - projected.y)
            if d < threshold && (best == nil || d < best!.distance) { best = (d, i, projected) }
        }
        guard let best else { return nil }
        return (best.index + 1, mapView.convert(best.point, toCoordinateFrom: mapView))
    }

    /// Closest non-system user shape: points within 32 pt, lines/outlines/circle edges within 22 pt.
    private func findNearestUserShape(at point: CGPoint, in mapView: MKMapView,
                                      state: RutMKVectorState) -> (shapeId: UUID, layerId: UUID)? {
        let lineThreshold: CGFloat = 22
        let pointThreshold: CGFloat = 32
        var best = CGFloat.infinity
        var result: (shapeId: UUID, layerId: UUID)?

        func consider(_ distance: CGFloat, within threshold: CGFloat, _ id: UUID, _ layerId: UUID) {
            if distance < threshold && distance < best {
                best = distance
                result = (id, layerId)
            }
        }
        func screen(_ c: CLLocationCoordinate2D) -> CGPoint { mapView.convert(c, toPointTo: mapView) }

        for item in state.points where !item.isSystem {
            let p = screen(item.coordinate)
            consider(hypot(point.x - p.x, point.y - p.y), within: pointThreshold, item.id, item.layerId)
        }
        for item in state.polylines where !item.isSystem && item.coordinates.count >= 2 {
            for i in 0 ..< item.coordinates.count - 1 {
                let d = Self.distance(from: point, toSegmentFrom: screen(item.coordinates[i]),
                                      to: screen(item.coordinates[i + 1]))
                consider(d, within: lineThreshold, item.id, item.layerId)
            }
        }
        for item in state.polygons where !item.isSystem {
            let n = item.coordinates.count
            for i in 0 ..< n {
                let d = Self.distance(from: point, toSegmentFrom: screen(item.coordinates[i]),
                                      to: screen(item.coordinates[(i + 1) % n]))
                consider(d, within: lineThreshold, item.id, item.layerId)
            }
        }
        for item in state.circles where !item.isSystem {
            let center = screen(item.center)
            let edge = screen(CLLocationCoordinate2D(latitude: item.center.latitude + item.radiusMeters / 111_320.0,
                                                     longitude: item.center.longitude))
            let radius = hypot(edge.x - center.x, edge.y - center.y)
            consider(abs(hypot(point.x - center.x, point.y - center.y) - radius),
                     within: lineThreshold, item.id, item.layerId)
        }
        return result
    }

    // MARK: Hit testing

    /// Nearest draggable marker within 30 pt; otherwise the active-route segment within 18 pt.
    private func findDragTarget(at point: CGPoint, in mapView: MKMapView, model: RutMKInteraction) -> DragTarget? {
        let threshold: CGFloat = 30
        var closest = CGFloat.infinity
        var result: DragTarget?

        func consider(_ coordinate: CLLocationCoordinate2D, _ target: DragTarget) {
            let p = mapView.convert(coordinate, toPointTo: mapView)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < threshold && d < closest {
                closest = d
                result = target
            }
        }

        for airport in model.airports { consider(airport.coordinate, .airport(id: airport.id, key: airport.key)) }
        for navaid in model.navaids { consider(navaid.coordinate, .navaid(id: navaid.id, key: navaid.key)) }
        for waypoint in model.waypoints { consider(waypoint.coordinate, .waypoint(id: waypoint.id, key: waypoint.key)) }
        for (index, routePoint) in model.activeRoutePoints.enumerated() {
            consider(routePoint.coordinate, .routePoint(index: index))
        }

        if result == nil, let segment = findNearestSegment(at: point, in: mapView, model: model) {
            result = .lineSegment(index: segment)
        }
        return result
    }

    private func findNearestSegment(at point: CGPoint, in mapView: MKMapView, model: RutMKInteraction) -> Int? {
        let threshold: CGFloat = 18
        let points = model.activeRoutePoints
        guard points.count >= 2 else { return nil }

        var best = CGFloat.infinity
        var bestIndex: Int?
        for i in 0 ..< points.count - 1 {
            let a = mapView.convert(points[i].coordinate, toPointTo: mapView)
            let b = mapView.convert(points[i + 1].coordinate, toPointTo: mapView)
            let d = Self.distance(from: point, toSegmentFrom: a, to: b)
            if d < threshold && d < best {
                best = d
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// Nearest database point within 32 pt, used to insert an existing point instead of a new waypoint.
    private func findSnapTarget(at point: CGPoint, in mapView: MKMapView, model: RutMKInteraction) -> RoutePointRef? {
        let threshold: CGFloat = 32
        var best = CGFloat.infinity
        var result: RoutePointRef?
        for candidate in model.snapCandidates {
            let p = mapView.convert(candidate.coordinate, toPointTo: mapView)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < threshold && d < best {
                best = d
                result = candidate.ref
            }
        }
        return result
    }

    private static func distance(from p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Annotations

private final class RutMKMarkerAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var spec: RutMKAnnotationSpec

    init(spec: RutMKAnnotationSpec) {
        self.spec = spec
        self.coordinate = spec.coordinate.coordinate
        super.init()
    }
}

/// Annotation view hosting a SwiftUI marker view (DatabaseMarkerView, RouteMarkerShapeView, …).
private final class RutMKHostedMarkerView: MKAnnotationView {
    static let reuseIdentifier = "RutMKHostedMarker"

    private var host: UIHostingController<RutMKMarkerView>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        displayPriority = .required
        collisionMode = .none
        backgroundColor = .clear
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        transform = .identity
    }

    func configure(marker: RutMKMarker, zPriority: Float, onTap: @escaping () -> Void) {
        let root = RutMKMarkerView(marker: marker, onTap: onTap)
        let host: UIHostingController<RutMKMarkerView>
        if let existing = self.host {
            existing.rootView = root
            host = existing
        } else {
            host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            addSubview(host.view)
            self.host = host
        }
        self.zPriority = MKAnnotationViewZPriority(rawValue: zPriority)

        // Centered on the coordinate, like SwiftUI Annotation's default anchor.
        let size = host.sizeThatFits(in: UIView.layoutFittingExpandedSize)
        bounds = CGRect(origin: .zero, size: size)
        host.view.frame = bounds
    }
}

/// Live route line while a route point is dragged (the route polyline is hidden meanwhile).
private final class RutMKDragLineView: UIView {
    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shapeLayer.strokeColor = UIColor(Color.blue).cgColor
        shapeLayer.fillColor = nil
        shapeLayer.lineWidth = 6
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        layer.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPoints(_ points: [CGPoint]) {
        let path = UIBezierPath()
        for (i, p) in points.enumerated() {
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds
        shapeLayer.path = path.cgPath
        CATransaction.commit()
    }
}

/// Drawing preview and vertex-edit handles, drawn above the map.
private final class RutMKVectorOverlayView: UIView {
    private let drawingFill = CAShapeLayer()
    private let drawingLine = CAShapeLayer()
    private let drawingDots = CAShapeLayer()
    private let editLine = CAShapeLayer()
    private let editHandles = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        for dashed in [drawingLine, editLine] {
            dashed.strokeColor = UIColor.white.cgColor
            dashed.fillColor = nil
            dashed.lineWidth = 2
            dashed.lineDashPattern = [6, 4]
        }
        drawingFill.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
        drawingFill.strokeColor = nil
        drawingDots.fillColor = UIColor.white.cgColor
        drawingDots.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        drawingDots.lineWidth = 1.5
        editHandles.fillColor = UIColor.white.cgColor
        editHandles.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        editHandles.lineWidth = 2
        for sublayer in [drawingFill, drawingLine, drawingDots, editLine, editHandles] {
            layer.addSublayer(sublayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `vertices` must not be empty.
    func showDrawing(tool: DrawingTool, vertices: [CGPoint], ghost: CGPoint?) {
        let line = UIBezierPath()
        let fill = UIBezierPath()
        let dots = UIBezierPath()

        switch tool {
        case .polyline, .polygon, .corridor:
            var points = vertices
            if let ghost { points.append(ghost) }
            if let first = points.first {
                line.move(to: first)
                for p in points.dropFirst() { line.addLine(to: p) }
                if tool == .polygon { line.addLine(to: first) }
            }
        case .circle:
            let center = vertices[0]
            let edge = ghost ?? (vertices.count > 1 ? vertices[1] : center)
            let r = hypot(edge.x - center.x, edge.y - center.y)
            let circle = UIBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            line.append(circle)
            fill.append(circle)
        case .point:
            dots.append(UIBezierPath(ovalIn: CGRect(x: vertices[0].x - 6, y: vertices[0].y - 6, width: 12, height: 12)))
        case .none:
            break
        }
        for v in vertices {
            dots.append(UIBezierPath(ovalIn: CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)))
        }
        setPaths([(drawingFill, fill), (drawingLine, line), (drawingDots, dots)])
    }

    func clearDrawing() {
        setPaths([(drawingFill, nil), (drawingLine, nil), (drawingDots, nil)])
    }

    func showEditing(vertices: [CGPoint], closed: Bool) {
        let line = UIBezierPath()
        let handles = UIBezierPath()
        if vertices.count > 1 {
            line.move(to: vertices[0])
            for v in vertices.dropFirst() { line.addLine(to: v) }
            if closed { line.addLine(to: vertices[0]) }
        }
        for v in vertices {
            handles.append(UIBezierPath(ovalIn: CGRect(x: v.x - 8, y: v.y - 8, width: 16, height: 16)))
        }
        setPaths([(editLine, line), (editHandles, handles)])
    }

    func clearEditing() {
        setPaths([(editLine, nil), (editHandles, nil)])
    }

    private func setPaths(_ items: [(CAShapeLayer, UIBezierPath?)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (shape, path) in items {
            shape.frame = bounds
            shape.path = path?.cgPath
        }
        CATransaction.commit()
    }
}

/// Marker content for each annotation kind.
private struct RutMKMarkerView: View {
    let marker: RutMKMarker
    let onTap: () -> Void

    var body: some View {
        switch marker {
        case let .databaseSymbol(bgColor, iconName, label, showLabel, opacity, scale):
            DatabaseMarkerView(bgColor: bgColor, iconName: iconName, iconColor: .white,
                               label: label, showLabel: showLabel)
                .opacity(opacity)
                .scaleEffect(scale)
                .onTapGesture(perform: onTap)

        case let .databaseWaypoint(label, isZero, showLabel, opacity, scale):
            RutMKWaypointMarkerView(label: label, isZero: isZero, showLabel: showLabel)
                .opacity(opacity)
                .scaleEffect(scale)
                .onTapGesture(perform: onTap)

        case let .routePoint(name, kind, waypointType, color, contentColor, showLabel, opacity, scale):
            RouteMarkerShapeView(
                point: RouteMapPoint(coordinate: CLLocationCoordinate2D(), name: name, indexInRoute: 0, kind: kind),
                color: color,
                contentColor: contentColor,
                waypointType: waypointType,
                showLabel: showLabel
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .onTapGesture(perform: onTap)

        case .legDistance(let text):
            Text(text)
                .font(.caption2)
                .padding(3)
                .background(Color.blue)
                .foregroundColor(.black)
                .cornerRadius(4)

        case let .vectorPoint(name, style, selected, showName):
            VStack(spacing: 2) {
                if style.euronaveSymbolId > 0 {
                    GlyphDisplayView(
                        symbolId: UInt16(style.euronaveSymbolId),
                        primaryColor: Color(hex: style.strokeColor),
                        secondaryColor: nil
                    )
                    .frame(width: (selected ? 28.0 : 22.0) * style.iconScale,
                           height: (selected ? 28.0 : 22.0) * style.iconScale)
                    .opacity(style.opacity)
                    .onTapGesture(perform: onTap)
                } else {
                    VectorPointIconView(
                        icon: style.pointIcon,
                        color: selected ? Color.white : Color(hex: style.strokeColor).opacity(style.opacity),
                        size: (selected ? 28.0 : 22.0) * style.iconScale
                    )
                    .onTapGesture(perform: onTap)
                }
                if showName {
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }

        case let .insertGhost(isSnapping, snapId):
            GhostInsertMarkerView(isSnapping: isSnapping, snapId: snapId)
        }
    }
}

/// Database waypoint marker (ring with a pin); the label hides when zoomed out, like airports and navaids.
private struct RutMKWaypointMarkerView: View {
    let label: String
    let isZero: Bool
    let showLabel: Bool

    var body: some View {
        let fg = isZero ? Color.red : Color(uiColor: .lightGray)
        ZStack {
            Circle().fill(Color.black.opacity(0.45))   // contrast on satellite imagery
            Image(systemName: "mappin.circle")
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundColor(fg)
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .top) {
            if showLabel {
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
        }
        .contentShape(Circle())
    }
}
