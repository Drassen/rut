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
    @EnvironmentObject var vectorStore: VectorStore
    @EnvironmentObject var core: CoreServices
    @StateObject private var airspaceService = AirspaceService.shared

    var onPointTap: ((RouteMapPoint) -> Void)? = nil
    var onMapLongPress: ((CLLocationCoordinate2D) -> Void)? = nil

    // Camera is stored in CoreServices so both nav and vector modes share position/zoom.
    private var camera: Binding<MapCameraPosition> { $core.mapCamera }
    @State private var mapStyle: RutMapStyle = .hybrid
    @State private var showMapLabels: Bool = true

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

    // Local drag state for route points — avoids @Published on every frame
    @State private var draggingRoutePointIdx: Int? = nil
    @State private var draggingRoutePointCoord = CLLocationCoordinate2D()
    // Separate from draggingRoutePointIdx so we can restore MapPolyline color
    // before hiding the Canvas overlay (they need different timing on cancel).
    @State private var isRoutePointDragActive = false
    @State private var pendingRoutePointMove: PendingRoutePointMove? = nil
    @State private var showRoutePointMoveConfirm = false

    // --- Vector vertex editing drag state ---
    // draggingEditVertexIndex moved to VectorEditingHandles struct below

    // --- Line-segment insertion state ---
    @State private var insertGhostCoord: CLLocationCoordinate2D? = nil
    @State private var insertSnapRef: RoutePointRef? = nil
    @State private var pendingInsert: PendingInsert? = nil
    @State private var showLineInsertAlert = false

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

    // Pending route-point move (awaiting user confirmation)
    private struct PendingRoutePointMove {
        let routeId: UUID
        let pointIndex: Int
        let pointId: String
        let newCoordinate: CLLocationCoordinate2D
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

    // Line-insert pending action
    private struct PendingInsert {
        let segmentIndex: Int
        let snapRef: RoutePointRef?
        let coordinate: CLLocationCoordinate2D
    }

    // Map-level drag target
    private enum MapDragTarget {
        case userAirport(UserAirport)
        case userNavaid(UserNavaid)
        case routePoint(index: Int)
        case lineSegment(segmentIndex: Int) // Converted to .routePoint in onChanged
        case vectorVertex(index: Int)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapReader { proxy in
                ZStack {
                    Map(position: camera) {

                        // 0a. Airspace (from AirspaceService, toggled via vectorStore.airspaceVisible)
                        if vectorStore.airspaceVisible {
                            airspaceContent()
                        }

                        // 0b. User vector layers
                        vectorLayersContent()

                        // 1. Inaktiva rutter (dimmed in vector mode)
                        inactiveRoutesContent(proxy: proxy)

                        // 2. Databas (dimmed in vector mode, no tap handlers)
                        databaseContent(proxy: proxy)

                        // 3. Aktiv rutt (dimmed in vector mode)
                        activeRouteContent(proxy: proxy)
                    }
                    .mapStyle(mapStyle.mapKitStyle)
                    .onMapCameraChange(frequency: .onEnd) { ctx in
                        showMapLabels = ctx.region.span.latitudeDelta < 0.68
                    }
                    .onAppear {
                        configureInitialCamera()
                    }
                    .task {
                        await airspaceService.fetchAllZones()
                        vectorStore.syncAirspaceSystemLayer(zones: airspaceService.zones)
                    }
                    // Single map-level gesture handles both marker drag and new-point creation.
                    // LongPressGesture is NOT on annotation views, so normal pan is never blocked.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { v in
                                    if !mapDragTargetChecked {
                                        mapDragTargetChecked = true
                                        let rawTarget = findDragTarget(at: v.startLocation, proxy: proxy)

                                        // Line segment: show ghost, disable map scroll so pan
                                        // doesn't steal the drag while the finger is moving.
                                        if case .lineSegment = rawTarget,
                                           let touchCoord = proxy.convert(v.startLocation, from: .global) {
                                            setMapScrollEnabled(false)
                                            insertGhostCoord = touchCoord
                                            insertSnapRef = nil
                                            mapDragTarget = rawTarget
                                        } else {
                                            mapDragTarget = rawTarget
                                            if case .routePoint = rawTarget {
                                                isRoutePointDragActive = true
                                                DispatchQueue.main.async { forceMapRedraw() }
                                            }
                                        }
                                    }
                                    if let target = mapDragTarget {
                                        updateMapDragTarget(target, at: v.location, proxy: proxy)
                                    }
                                }
                                .onEnded { v in
                                    if let target = mapDragTarget {
                                        finalizeMapDragTarget(target, at: v.location, proxy: proxy)
                                    } else if core.appMode == .navigation {
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
                                draggingRoutePointIdx = nil
                                isRoutePointDragActive = false
                            }
                            if insertGhostCoord != nil {
                                setMapScrollEnabled(true)
                                insertGhostCoord = nil
                                insertSnapRef = nil
                            }
                            mapDragTarget = nil
                            mapDragTargetChecked = false
                        }
                    }
                    // Shape selection tap in vector cursor mode (doesn't block pan)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onEnded { value in
                                guard core.appMode == .vector,
                                      vectorStore.activeTool == .none,
                                      !vectorStore.isEditingShape else { return }
                                let d = hypot(value.translation.width, value.translation.height)
                                guard d < 8 else { return }
                                if let hit = findNearestUserShape(at: value.startLocation, proxy: proxy) {
                                    vectorStore.selectShape(id: hit.shapeId, layerId: hit.layerId)
                                } else {
                                    vectorStore.deselectShape()
                                }
                            }
                    )

                    // Canvas overlay always renders the active route line.
                    // Canvas overlay for 60fps route-point dragging.
                    routePolylineOverlay(proxy: proxy)
                        .allowsHitTesting(false)

                    // Vector drawing: transparent tap-catcher + preview overlay
                    if core.appMode == .vector && vectorStore.activeTool != .none {
                        drawingTapOverlay(proxy: proxy)
                        drawingPreviewOverlay(proxy: proxy)
                            .allowsHitTesting(false)
                    }

                    // Editing vertex handles — isolated view so 60fps vertex drag
                    // doesn't re-render RutMapView (and airspace MapPolygons).
                    if core.appMode == .vector && vectorStore.isEditingShape {
                        VectorEditingHandles(proxy: proxy)
                    }
                }
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
                isRoutePointDragActive = false
                draggingRoutePointIdx = nil
                DispatchQueue.main.async { forceMapRedraw() }
            }
            Button("Cancel", role: .cancel) {
                // Snap canvas to original position immediately (correct visual during dismiss).
                if let move = pendingRoutePointMove,
                   let route = navStore.document.routes.first(where: { $0.id == move.routeId }) {
                    let pts = navStore.mapPoints(for: route)
                    if move.pointIndex < pts.count {
                        draggingRoutePointCoord = displayCoordinate(for: pts[move.pointIndex].coordinate)
                    }
                }
                pendingRoutePointMove = nil
                // Restore MapPolyline color immediately — MapKit will apply this during
                // the alert dismiss animation (~250ms at 60fps = ~15 render cycles).
                isRoutePointDragActive = false
                // Clear canvas after the alert animation completes, at which point
                // MapKit has definitely rendered the colorActive polyline.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    draggingRoutePointIdx = nil
                }
            }
        } message: {
            if let move = pendingRoutePointMove {
                Text("Move \(move.pointId) to \(String(format: "%.4f", move.newCoordinate.latitude))°N, \(String(format: "%.4f", move.newCoordinate.longitude))°E?")
            }
        }
    }

    // MARK: - 0. Vector layers (airspace + user-drawn)

    @MapContentBuilder
    private func vectorLayersContent() -> some MapContent {
        let selectedId = vectorStore.activeShapeId
        let editingId  = vectorStore.isEditingShape ? selectedId : nil
        // Polygons
        ForEach(vectorStore.visiblePolygons().filter { $0.id != editingId }) { item in
            let sel = item.id == selectedId
            MapPolygon(coordinates: item.coordinates)
                .foregroundStyle(Color(hex: item.style.fillColor).opacity(item.style.opacity))
                .stroke(sel ? Color.white : Color(hex: item.style.strokeColor).opacity(item.style.opacity),
                        lineWidth: sel ? item.style.strokeWidth + 2 : item.style.strokeWidth)
        }
        // Polylines
        ForEach(vectorStore.visiblePolylines().filter { $0.id != editingId }) { item in
            let sel = item.id == selectedId
            MapPolyline(coordinates: item.coordinates)
                .stroke(sel ? Color.white : Color(hex: item.style.strokeColor).opacity(item.style.opacity),
                        lineWidth: sel ? item.style.strokeWidth + 2 : item.style.strokeWidth)
        }
        // Circles
        ForEach(vectorStore.visibleCircles().filter { $0.id != editingId }) { item in
            let sel = item.id == selectedId
            MapCircle(center: item.center, radius: item.radiusMeters)
                .foregroundStyle(Color(hex: item.style.fillColor).opacity(item.style.opacity * 0.3))
                .stroke(sel ? Color.white : Color(hex: item.style.strokeColor).opacity(item.style.opacity),
                        lineWidth: sel ? item.style.strokeWidth + 2 : item.style.strokeWidth)
        }
        // Points rendered as annotations with name label
        ForEach(vectorStore.visiblePoints().filter { $0.id != editingId }) { item in
            let sel = item.id == selectedId
            Annotation(item.name, coordinate: item.coordinate, anchor: .center) {
                VStack(spacing: 2) {
                    VectorPointIconView(
                        icon: item.style.pointIcon,
                        color: sel ? Color.white : Color(hex: item.style.strokeColor).opacity(item.style.opacity),
                        size: (sel ? 28.0 : 22.0) * item.style.iconScale
                    )
                        .onTapGesture {
                            if core.appMode == .vector {
                                vectorStore.selectShape(id: item.id, layerId: item.layerId)
                            }
                        }
                    if core.appMode == .vector {
                        Text(item.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            .annotationTitles(.hidden)
        }
    }

    // MARK: - 0a. Airspace content
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
        let isVector = core.appMode == .vector
        let opacity = isVector ? 0.60 : (hasActiveRoute ? 0.8 : 1.0)
        let scale   = hasActiveRoute && !isVector ? 0.8 : 1.0

        // --- USER AIRPORTS ---
        ForEach(Array(navStore.document.userAirports.enumerated()), id: \.offset) { index, airport in
            if !activeRouteIDs.contains(airport.id) && !inactiveRouteIDs.contains(airport.id) {
                let dragCoord = draggingAirportId == airport.id
                    ? draggingAirportCoord
                    : displayCoordinate(for: airport.coordinate)
                Annotation("apt-\(index)-\(airport.id)", coordinate: dragCoord) {
                    DatabaseMarkerView(bgColor: colorAirport, iconName: "airplane", iconColor: .white, label: airport.id, showLabel: showMapLabels)
                        .scaleEffect(draggingAirportId == airport.id ? 1.2 : 1.0)
                        .opacity(opacity)
                        .scaleEffect(scale)
                        .onTapGesture {
                            if !isVector {
                                onPointTap?(RouteMapPoint(coordinate: airport.coordinate,
                                                          name: airport.id, indexInRoute: -1, kind: .userAirport))
                            }
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
                    DatabaseMarkerView(bgColor: colorNavaid, iconName: "antenna.radiowaves.left.and.right", iconColor: .white, label: navaid.id, showLabel: showMapLabels)
                        .scaleEffect(draggingNavaidId == navaid.id ? 1.2 : 1.0)
                        .opacity(opacity)
                        .scaleEffect(scale)
                        .onTapGesture {
                            if !isVector {
                                onPointTap?(RouteMapPoint(coordinate: navaid.coordinate,
                                                          name: navaid.id, indexInRoute: -1, kind: .userNavaid))
                            }
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
                    DatabaseMarkerView(bgColor: colorAirport, iconName: "airplane", iconColor: .white, label: ap.id, showLabel: showMapLabels)
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
                    DatabaseMarkerView(bgColor: colorNavaid, iconName: "antenna.radiowaves.left.and.right", iconColor: .white, label: nv.id, showLabel: showMapLabels)
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
        let vectorDim = core.appMode == .vector ? 0.60 : 1.0
        ForEach(navStore.routes.filter { $0.id != navStore.activeRouteId }) { route in
            let points = navStore.mapPoints(for: route)
            let coords = points.map { displayCoordinate(for: $0.coordinate) }
            let dimFactor = (hasActiveRoute ? 0.9 : 1.0) * vectorDim

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
                            waypointType: type,
                            showLabel: showMapLabels && core.appMode == .navigation
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
        let isVector  = core.appMode == .vector
        let vectorDim = isVector ? 0.60 : 1.0
        if let route = navStore.activeRoute {
            let points = navStore.mapPoints(for: route)
            // Skip leg-distance labels while dragging — values are stale.
            let legDistances = draggingRoutePointIdx == nil ? navStore.legDistancesNM(for: route) : [Double]()

            let coords = points.map { displayCoordinate(for: $0.coordinate) }
            if coords.count >= 2 {
                MapPolyline(coordinates: coords)
                    .stroke(isRoutePointDragActive ? Color.clear : colorActive.opacity(vectorDim), lineWidth: 6)
            }

            ForEach(Array(points.enumerated()), id: \.offset) { pair in
                let idx = pair.offset
                let p = pair.element
                let type = waypointType(for: p)
                let isDragging = isRoutePointDragActive && draggingRoutePointIdx == idx

                Annotation(p.name, coordinate: displayCoordinate(for: p.coordinate)) {
                    RouteMarkerShapeView(point: p, color: colorActive, contentColor: .white, waypointType: type, showLabel: showMapLabels && !isVector)
                        // Hide while dragging — Canvas overlay renders the live marker instead.
                        .opacity(isDragging ? 0 : vectorDim)
                        .zIndex(10)
                        .onTapGesture { if core.appMode == .navigation { onPointTap?(p) } }
                }
                .annotationTitles(.hidden)

                if showMapLabels && !isVector && idx < points.count - 1 && idx < legDistances.count {
                    let safeP = displayCoordinate(for: p.coordinate)
                    let safeNext = displayCoordinate(for: points[idx + 1].coordinate)
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

            // Ghost marker shown while dragging a line-segment insertion
            if let ghostCoord = insertGhostCoord {
                Annotation("ghost-insert", coordinate: ghostCoord) {
                    GhostInsertMarkerView(isSnapping: insertSnapRef != nil,
                                         snapId: insertSnapRef?.refId)
                }
                .annotationTitles(.hidden)
            }
        }
    }

    // MARK: - Map drag helpers

    /// Hit-test: find the draggable marker closest to a screen point (within threshold).
    private func findDragTarget(at screenPoint: CGPoint, proxy: MapProxy) -> MapDragTarget? {
        let threshold: CGFloat = 30
        var closestDist = CGFloat.infinity
        var result: MapDragTarget? = nil

        // When editing a vector shape, only vertex handles are draggable
        if vectorStore.isEditingShape {
            for (i, vertex) in vectorStore.editingVertices.enumerated() {
                if let pt = proxy.convert(vertex, to: .global) {
                    let dist = hypot(pt.x - screenPoint.x, pt.y - screenPoint.y)
                    if dist < threshold && dist < closestDist {
                        closestDist = dist
                        result = .vectorVertex(index: i)
                    }
                }
            }
            return result
        }

        // In vector mode without editing, no nav markers are draggable
        guard core.appMode == .navigation else { return nil }

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

        // If no marker was hit, check if touch is on a route line segment
        if result == nil, let route = navStore.activeRoute {
            if let segIdx = findNearestSegment(at: screenPoint, proxy: proxy, route: route) {
                result = .lineSegment(segmentIndex: segIdx)
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
            // Update local state only — no @Published fire on every drag frame
            draggingRoutePointIdx = idx
            draggingRoutePointCoord = coord
        case .lineSegment:
            insertGhostCoord = coord
            insertSnapRef = findSnapTarget(at: screenPoint, proxy: proxy)
        case .vectorVertex(let index):
            vectorStore.moveEditVertex(at: index, to: coord)
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
                let points = navStore.mapPoints(for: route)
                let pointId = idx < points.count ? points[idx].name : "point"
                // Keep draggingRoutePointIdx set so Canvas holds the drop position during confirm
                pendingRoutePointMove = PendingRoutePointMove(
                    routeId: route.id,
                    pointIndex: idx,
                    pointId: pointId,
                    newCoordinate: coord
                )
                showRoutePointMoveConfirm = true
            } else {
                draggingRoutePointIdx = nil
            }
        case .lineSegment(let segIdx):
            setMapScrollEnabled(true)
            if let ghostCoord = insertGhostCoord {
                pendingInsert = PendingInsert(
                    segmentIndex: segIdx,
                    snapRef: insertSnapRef,
                    coordinate: ghostCoord
                )
                showLineInsertAlert = true
            }
            insertGhostCoord = nil
            insertSnapRef = nil
        case .vectorVertex(let index):
            vectorStore.moveEditVertex(at: index, to: coord)
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

    // MARK: - Line segment helpers

    /// Returns the segment index (first-point index) of the nearest active-route segment
    /// to `screenPt`, or nil if no segment is within the hit threshold.
    private func findNearestSegment(at screenPt: CGPoint, proxy: MapProxy, route: Route) -> Int? {
        let lineHitThreshold: CGFloat = 18
        let points = navStore.mapPoints(for: route)
        guard points.count >= 2 else { return nil }

        var bestDist = CGFloat.infinity
        var bestIdx: Int? = nil

        for i in 0 ..< points.count - 1 {
            guard
                let p0 = proxy.convert(displayCoordinate(for: points[i].coordinate),     to: .global),
                let p1 = proxy.convert(displayCoordinate(for: points[i+1].coordinate),   to: .global)
            else { continue }

            let (dist, _) = closestPointOnSegment(from: screenPt, segA: p0, segB: p1)
            if dist < lineHitThreshold && dist < bestDist {
                bestDist = dist
                bestIdx  = i
            }
        }
        return bestIdx
    }

    /// Projects point `p` onto segment (segA, segB) and returns (distance, closest point).
    private func closestPointOnSegment(
        from p: CGPoint, segA: CGPoint, segB: CGPoint
    ) -> (CGFloat, CGPoint) {
        let dx = segB.x - segA.x
        let dy = segB.y - segA.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            return (hypot(p.x - segA.x, p.y - segA.y), segA)
        }
        let t = max(0, min(1, ((p.x - segA.x) * dx + (p.y - segA.y) * dy) / lenSq))
        let closest = CGPoint(x: segA.x + t * dx, y: segA.y + t * dy)
        return (hypot(p.x - closest.x, p.y - closest.y), closest)
    }

    /// Returns the nearest database point within snap threshold of `screenPt`, or nil.
    /// Points with `excluding` refId are skipped (used to exclude the temp insertion WPT).
    private func findSnapTarget(at screenPt: CGPoint, proxy: MapProxy, excluding: String? = nil) -> RoutePointRef? {
        let snapThreshold: CGFloat = 32
        var bestDist = CGFloat.infinity
        var result: RoutePointRef? = nil

        func check(_ coord: CLLocationCoordinate2D, _ ref: RoutePointRef) {
            guard ref.refId != excluding else { return }
            guard let pt = proxy.convert(displayCoordinate(for: coord), to: .global) else { return }
            let d = hypot(pt.x - screenPt.x, pt.y - screenPt.y)
            if d < snapThreshold && d < bestDist { bestDist = d; result = ref }
        }

        for ap in navStore.document.userAirports   { check(ap.coordinate, RoutePointRef(kind: .userAirport,   refId: ap.id)) }
        for nv in navStore.document.userNavaids    { check(nv.coordinate, RoutePointRef(kind: .userNavaid,    refId: nv.id)) }
        for wp in navStore.document.userWaypoints  { check(wp.coordinate, RoutePointRef(kind: .userWaypoint,  refId: wp.id)) }
        for ap in navStore.document.systemAirports { check(ap.coordinate, RoutePointRef(kind: .systemAirport, refId: ap.id)) }
        for nv in navStore.document.systemNavaids  { check(nv.coordinate, RoutePointRef(kind: .systemNavaid,  refId: nv.id)) }

        return result
    }

    private func displayCoordinate(for c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if isZero(c) {
            return CLLocationCoordinate2D(latitude: 0.000001, longitude: 0.000001)
        }
        return c
    }

    private func setRegion(center: CLLocationCoordinate2D) {
        camera.wrappedValue = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)))
    }

    private func waypointType(for point: RouteMapPoint) -> WaypointType? {
        guard point.kind == .userWaypoint else { return nil }
        return navStore.document.userWaypoints.first(where: { $0.id == point.name })?.type
    }

    // MARK: - Route point drag overlay

    /// Canvas overlay shown only while dragging a route point.
    /// Draws the live polyline at 60fps on top of the frozen MapPolyline.
    /// MapPolyline is never hidden — on cancel it was always at the original
    /// position so nothing needs to be restored.
    @ViewBuilder
    private func routePolylineOverlay(proxy: MapProxy) -> some View {
        if let dragIdx = draggingRoutePointIdx, let route = navStore.activeRoute {
            let points = navStore.mapPoints(for: route)
            let dragCoord = draggingRoutePointCoord

            ZStack {
                Canvas { ctx, _ in
                    var path = Path()
                    var first = true
                    for (i, p) in points.enumerated() {
                        let coord = i == dragIdx ? dragCoord : displayCoordinate(for: p.coordinate)
                        guard let pt = proxy.convert(coord, to: .local) else { continue }
                        if first { path.move(to: pt); first = false }
                        else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(colorActive), lineWidth: 6)
                }

                if dragIdx < points.count,
                   let pt = proxy.convert(dragCoord, to: .local) {
                    let p = points[dragIdx]
                    RouteMarkerShapeView(
                        point: p,
                        color: colorActive,
                        contentColor: .white,
                        waypointType: waypointType(for: p)
                    )
                    .scaleEffect(1.2)
                    .position(pt)
                }
            }
        }
    }

    // MARK: - Line insert helpers

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
            navStore.renumberWaypoints(forRouteIds: [route.id])
        }
        pendingInsert = nil
    }

    private func findMKMapView() -> MKMapView? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first else { return nil }
        func find(_ view: UIView) -> MKMapView? {
            if let mv = view as? MKMapView { return mv }
            for sub in view.subviews { if let mv = find(sub) { return mv } }
            return nil
        }
        return find(window)
    }

    private func setMapScrollEnabled(_ enabled: Bool) {
        findMKMapView()?.isScrollEnabled = enabled
    }

    /// Forces MapKit to process pending @MapContentBuilder changes.
    /// Must be called via DispatchQueue.main.async so SwiftUI has already
    /// re-evaluated body and sent updated content to MapKit first.
    private func forceMapRedraw() {
        guard let mv = findMKMapView() else { return }
        mv.setCenter(mv.centerCoordinate, animated: false)
    }

    // MARK: - Vector drawing overlays

    /// Transparent overlay that captures taps/drags for vector shape drawing.
    @ViewBuilder
    private func drawingTapOverlay(proxy: MapProxy) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onEnded { value in
                        // Treat as tap when movement is minimal
                        let d = hypot(value.translation.width, value.translation.height)
                        if d < 8, let coord = proxy.convert(value.startLocation, from: .global) {
                            vectorStore.drawing.handleTap(at: coord, tool: vectorStore.activeTool)
                            // Auto-commit point immediately
                            if vectorStore.activeTool == .point && vectorStore.drawing.isActive {
                                vectorStore.commitDrawing(name: "Point")
                            }
                        }
                    }
            )
    }

    /// Canvas overlay that draws the in-progress vector shape preview.
    @ViewBuilder
    private func drawingPreviewOverlay(proxy: MapProxy) -> some View {
        let vertices = vectorStore.drawing.vertices
        let ghost    = vectorStore.drawing.ghostCoord
        let tool     = vectorStore.activeTool

        if !vertices.isEmpty {
            Canvas { ctx, _ in
                switch tool {
                case .polyline, .polygon, .zigzag, .corridor:
                    var path = Path()
                    var points = vertices
                    if let g = ghost { points.append(g) }
                    if let first = points.first, let pt = proxy.convert(first, to: .local) {
                        path.move(to: pt)
                        for coord in points.dropFirst() {
                            if let pt = proxy.convert(coord, to: .local) { path.addLine(to: pt) }
                        }
                        if tool == .polygon, let closePt = proxy.convert(points[0], to: .local) {
                            path.addLine(to: closePt)
                        }
                    }
                    ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

                case .circle:
                    let center = vertices[0]
                    let radiusCoord = ghost ?? (vertices.count > 1 ? vertices[1] : center)
                    if let cPt = proxy.convert(center, to: .local),
                       let ePt = proxy.convert(radiusCoord, to: .local) {
                        let r = hypot(ePt.x - cPt.x, ePt.y - cPt.y)
                        let circle = Path(ellipseIn: CGRect(x: cPt.x - r, y: cPt.y - r,
                                                            width: r * 2, height: r * 2))
                        ctx.stroke(circle, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        ctx.fill(circle, with: .color(Color.white.opacity(0.08)))
                    }

                case .point:
                    if let pt = proxy.convert(vertices[0], to: .local) {
                        let dot = Path(ellipseIn: CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12))
                        ctx.fill(dot, with: .color(.white))
                    }

                case .none:
                    break
                }

                // Draw vertex dots
                for v in vertices {
                    if let pt = proxy.convert(v, to: .local) {
                        let dot = Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
                        ctx.fill(dot, with: .color(.white))
                        ctx.stroke(dot, with: .color(Color.white.opacity(0.5)), lineWidth: 1.5)
                    }
                }
            }
        }
    }

    /// Returns shapeId + layerId of the closest non-system user shape near a screen point.
    private func findNearestUserShape(at point: CGPoint, proxy: MapProxy) -> (shapeId: UUID, layerId: UUID)? {
        let lineThr: CGFloat = 22
        let pointThr: CGFloat = 32
        var bestDist = CGFloat.infinity
        var result: (UUID, UUID)? = nil

        func tryBeat(dist: CGFloat, id: UUID, lid: UUID) {
            if dist < bestDist { bestDist = dist; result = (id, lid) }
        }

        for item in vectorStore.visiblePoints() where !item.isSystem {
            if let pt = proxy.convert(item.coordinate, to: .global) {
                let d = hypot(point.x - pt.x, point.y - pt.y)
                if d < pointThr { tryBeat(dist: d, id: item.id, lid: item.layerId) }
            }
        }
        for item in vectorStore.visiblePolylines() where !item.isSystem {
            for i in 0..<(item.coordinates.count - 1) {
                if let a = proxy.convert(item.coordinates[i], to: .global),
                   let b = proxy.convert(item.coordinates[i+1], to: .global) {
                    let d = distPointToSegment(point, a, b)
                    if d < lineThr { tryBeat(dist: d, id: item.id, lid: item.layerId) }
                }
            }
        }
        for item in vectorStore.visiblePolygons() where !item.isSystem {
            for i in 0..<item.coordinates.count {
                let j = (i + 1) % item.coordinates.count
                if let a = proxy.convert(item.coordinates[i], to: .global),
                   let b = proxy.convert(item.coordinates[j], to: .global) {
                    let d = distPointToSegment(point, a, b)
                    if d < lineThr { tryBeat(dist: d, id: item.id, lid: item.layerId) }
                }
            }
        }
        for item in vectorStore.visibleCircles() where !item.isSystem {
            if let centerPt = proxy.convert(item.center, to: .global) {
                let edgeLat = item.center.latitude + (item.radiusMeters / 111_320.0)
                let edgeCoord = CLLocationCoordinate2D(latitude: edgeLat, longitude: item.center.longitude)
                let screenRadius = proxy.convert(edgeCoord, to: .global)
                    .map { hypot($0.x - centerPt.x, $0.y - centerPt.y) } ?? 0
                let distToEdge = abs(hypot(point.x - centerPt.x, point.y - centerPt.y) - screenRadius)
                if distToEdge < lineThr { tryBeat(dist: distToEdge, id: item.id, lid: item.layerId) }
            }
        }
        return result
    }

    /// Distance from point P to segment AB.
    private func distPointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let lenSq = ab.x * ab.x + ab.y * ab.y
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lenSq))
        let proj = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
        return hypot(p.x - proj.x, p.y - proj.y)
    }
}

// MARK: - SUBVIEWS

struct DatabaseMarkerView: View {
    let bgColor: Color
    let iconName: String
    let iconColor: Color
    let label: String
    var showLabel: Bool = true

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

struct RouteMarkerShapeView: View {
    let point: RouteMapPoint
    let color: Color
    let contentColor: Color
    let waypointType: WaypointType?
    var showLabel: Bool = true

    var body: some View {
        ZStack {
            markerShape()
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .top) {
            if showLabel {
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

struct GhostInsertMarkerView: View {
    let isSnapping: Bool
    let snapId: String?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isSnapping ? Color.green : Color.blue,
                        style: StrokeStyle(lineWidth: 2.5, dash: [5, 3])
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: isSnapping ? "checkmark" : "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(isSnapping ? .green : .blue)
            }
            if let id = snapId {
                Text(id)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .fixedSize()
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - VectorEditingHandles
// Isolated struct so that 60fps vertex-drag updates (via vectorStore.editingVertices)
// don't cause RutMapView to re-evaluate its body and recreate 236 airspace MapPolygons.

struct VectorEditingHandles: View {
    @EnvironmentObject var vectorStore: VectorStore
    let proxy: MapProxy

    @State private var draggingEditVertexIndex: Int? = nil

    var body: some View {
        let verts = vectorStore.editingVertices
        ZStack {
            // Invisible full-screen drag catcher
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if draggingEditVertexIndex == nil {
                                draggingEditVertexIndex = nearestEditVertex(to: value.startLocation)
                            }
                            if let idx = draggingEditVertexIndex,
                               let coord = proxy.convert(value.location, from: .global) {
                                vectorStore.moveEditVertex(at: idx, to: coord)
                            }
                        }
                        .onEnded { _ in
                            draggingEditVertexIndex = nil
                        }
                )

            // Visual handles (non-interactive)
            if !verts.isEmpty {
                Canvas { ctx, _ in
                    if verts.count > 1 {
                        var path = Path()
                        if let first = proxy.convert(verts[0], to: .local) {
                            path.move(to: first)
                            for v in verts.dropFirst() {
                                if let pt = proxy.convert(v, to: .local) { path.addLine(to: pt) }
                            }
                            if let found = vectorStore.activeShapeId.flatMap({ vectorStore.findShape(id: $0) }),
                               case .polygon = found.shape.geometry,
                               let closePt = proxy.convert(verts[0], to: .local) {
                                path.addLine(to: closePt)
                            }
                        }
                        ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                    for v in verts {
                        if let pt = proxy.convert(v, to: .local) {
                            let handle = Path(ellipseIn: CGRect(x: pt.x - 8, y: pt.y - 8, width: 16, height: 16))
                            ctx.fill(handle, with: .color(.white))
                            ctx.stroke(handle, with: .color(Color.white.opacity(0.5)), lineWidth: 2)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func nearestEditVertex(to point: CGPoint) -> Int? {
        let threshold: CGFloat = 44
        var best: (dist: CGFloat, index: Int)? = nil
        for (i, vertex) in vectorStore.editingVertices.enumerated() {
            if let pt = proxy.convert(vertex, to: .global) {
                let d = hypot(pt.x - point.x, pt.y - point.y)
                if d < threshold && (best == nil || d < best!.dist) { best = (d, i) }
            }
        }
        return best?.index
    }
}
