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
    
    var onPointTap: ((RouteMapPoint) -> Void)? = nil
    
    @State private var camera: MapCameraPosition = .automatic
    @State private var mapStyle: RutMapStyle = .hybrid
    
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
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapReader { proxy in
                Map(position: $camera) {
                    
                    // 1. Inaktiva rutter
                    inactiveRoutesContent(proxy: proxy)
                    
                    // 2. Databas
                    databaseContent()
                    
                    // 3. Aktiv rutt
                    activeRouteContent(proxy: proxy)
                }
                .mapStyle(mapStyle.mapKitStyle)
                .onAppear {
                    configureInitialCamera()
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
    }
    
    // MARK: - 1. Database Content
    
    @MapContentBuilder
    private func databaseContent() -> some MapContent {
        
        let opacity = hasActiveRoute ? 0.8 : 1.0
        let scale   = hasActiveRoute ? 0.8 : 1.0
        
        // --- USER AIRPORTS ---
        ForEach(Array(navStore.document.userAirports.enumerated()), id: \.offset) { index, airport in
            if !activeRouteIDs.contains(airport.id) && !inactiveRouteIDs.contains(airport.id) {
                Annotation("apt-\(index)-\(airport.id)", coordinate: displayCoordinate(for: airport.coordinate)) {
                    DatabaseMarkerView(bgColor: colorAirport, iconName: "airplane", iconColor: .white, label: airport.id)
                        .opacity(opacity)
                        .scaleEffect(scale)
                        .onTapGesture {
                            onPointTap?(RouteMapPoint(coordinate: airport.coordinate, name: airport.id, indexInRoute: -1, kind: .userAirport))
                        }
                }
                .annotationTitles(.hidden)
            }
        }
        
        // --- USER NAVAIDS ---
        ForEach(Array(navStore.document.userNavaids.enumerated()), id: \.offset) { index, navaid in
            if !activeRouteIDs.contains(navaid.id) && !inactiveRouteIDs.contains(navaid.id) {
                Annotation("nav-\(index)-\(navaid.id)", coordinate: displayCoordinate(for: navaid.coordinate)) {
                    DatabaseMarkerView(bgColor: colorNavaid, iconName: "antenna.radiowaves.left.and.right", iconColor: .white, label: navaid.id)
                        .opacity(opacity)
                        .scaleEffect(scale)
                        .onTapGesture {
                            onPointTap?(RouteMapPoint(coordinate: navaid.coordinate, name: navaid.id, indexInRoute: -1, kind: .userNavaid))
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
                    
                    // Databas-waypoint (Svart W)
                    ZStack {
                        Circle().fill(bg)
                        Text("W").font(.system(size: 12, weight: .bold)).foregroundColor(.black)
                    }
                    .frame(width: 26, height: 26) // Fix storlek för centrering
                    .overlay(alignment: .top) {   // Text hänger under
                        Text(wp.id)
                            .font(.caption2)
                            .padding(2)
                            .background(Color.white.opacity(0.8))
                            .cornerRadius(4)
                            .fixedSize()
                            .offset(y: 30) // Skjut ner texten
                    }
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
                
                Annotation(p.name, coordinate: displayCoordinate(for: p.coordinate)) {
                    let type = waypointType(for: p)
                    DraggableRouteMarkerView(
                        point: p,
                        index: idx,
                        color: colorActive,
                        contentColor: .white,
                        waypointType: type,
                        onTap: { onPointTap?(p) },
                        onDragMove: { point in
                            if let c = proxy.convert(point, from: .global) {
                                navStore.updateWaypointCoordinate(in: route, at: idx, to: c)
                            }
                        },
                        onDragEnd: { point in
                            if let c = proxy.convert(point, from: .global) {
                                navStore.updateWaypointCoordinate(in: route, at: idx, to: c)
                            }
                        }
                    )
                    .zIndex(10)
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
    
    // MARK: - Helpers
    
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
        .frame(width: 26, height: 26) // Fixerad storlek
        .overlay(alignment: .top) {   // Text hänger utanför (under)
            Text(label)
                .font(.caption2)
                .padding(2)
                .background(Color.white.opacity(0.8))
                .foregroundColor(Color.black.opacity(0.8))
                .cornerRadius(4)
                .fixedSize()
                .offset(y: 30) // 26 + 4 padding
        }
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
        .frame(width: 26, height: 26) // Fixerad storlek
        .overlay(alignment: .top) {   // Text hänger utanför
            Text(point.name)
                .font(.caption2)
                .padding(2)
                .background(Color.white.opacity(0.8))
                .foregroundColor(.black)
                .cornerRadius(4)
                .fixedSize()
                .offset(y: 30)
        }
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
                    // Default: Cirkel med vit prick
                    ZStack {
                        Circle().fill(color)
                        Circle().fill(Color.white).padding(6)
                    }
                }
            } else {
                // Fallback
                ZStack {
                    Circle().fill(color)
                    Circle().fill(Color.white).padding(6)
                }
            }
        }
    }
}

struct DraggableRouteMarkerView: View {
    let point: RouteMapPoint
    let index: Int
    let color: Color
    let contentColor: Color
    let waypointType: WaypointType?
    let onTap: () -> Void
    let onDragMove: (CGPoint) -> Void
    let onDragEnd: (CGPoint) -> Void
    @GestureState private var isLongPressing = false
    
    var body: some View {
        let drag = DragGesture(coordinateSpace: .global)
            .onChanged { onDragMove($0.location) }
            .onEnded { onDragEnd($0.location) }
        
        let seq = LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: drag)
            .updating($isLongPressing) { v, s, _ in
                if case .first(true) = v { s = true }
                else if case .second(true, _) = v { s = true }
                else { s = false }
            }
        
        RouteMarkerShapeView(point: point, color: color, contentColor: contentColor, waypointType: waypointType)
            .scaleEffect(isLongPressing ? 1.2 : 1.0)
            .gesture(seq)
            .simultaneousGesture(TapGesture().onEnded { if !isLongPressing { onTap() } })
    }
}
