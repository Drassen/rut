import SwiftUI
import MapKit

// MARK: - Map engine switch

/// Picks the map implementation from the "New map engine (beta)" setting.
struct RutMapContainer: View {
    var onPointTap: ((RouteMapPoint) -> Void)? = nil
    var onMapLongPress: ((CLLocationCoordinate2D) -> Void)? = nil

    @AppStorage("useMKMapView") private var useMKMapView = false

    var body: some View {
        if useMKMapView {
            RutMKMapView(onPointTap: onPointTap, onMapLongPress: onMapLongPress)
        } else {
            RutMapView(onPointTap: onPointTap, onMapLongPress: onMapLongPress)
        }
    }
}

// MARK: - RutMKMapView

/// The map drawn with MKMapView instead of SwiftUI `Map`.
///
/// SwiftUI `Map` adds one overlay per `MapPolygon`. With all 234 LFV airspace zones on
/// screen (zoomed out) MapKit renders at ~30 fps; one `MKMultiPolygon` per zone type
/// (4 overlays) measured a steady 60 fps on iPad (2026-09-15). SwiftUI `Map` cannot
/// show multipolygons, hence this UIKit-backed map.
///
/// Migration step 1: rendering, taps and long-press-to-add. Dragging markers, route
/// insertion and vector drawing/editing still need the SwiftUI map (RutMapView).
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

    // Same palette as RutMapView.
    private let colorAirport  = Color(uiColor: .darkGray)
    private let colorNavaid   = Color.gray
    private let colorActive   = Color.blue
    private let colorInactive = Color.blue.opacity(0.3)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RutMKRepresentable(
                content: makeContent(),
                mapStyle: mapStyle,
                initialRegion: initialRegion,
                handlers: RutMKHandlers(
                    pointTap: onPointTap,
                    longPress: onMapLongPress,
                    selectShape: { vectorStore.selectShape(id: $0, layerId: $1) },
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
    }

    // MARK: Content

    /// Everything the map shows, in drawing order. Mirrors RutMapView's content builders.
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
        for item in vectorStore.visiblePolygons() where item.id != editingId {
            overlays.append(RutMKOverlaySpec(key: "vpolygon-\(item.id)",
                                             geometry: .polygon(item.coordinates.map { RutMKGeoPoint($0) }),
                                             style: .vectorPolygon(item.style, selected: item.id == selectedId)))
        }
        for item in vectorStore.visiblePolylines() where item.id != editingId {
            overlays.append(RutMKOverlaySpec(key: "vpolyline-\(item.id)",
                                             geometry: .polyline(item.coordinates.map { RutMKGeoPoint($0) }),
                                             style: .vectorPolyline(item.style, selected: item.id == selectedId)))
        }
        for item in vectorStore.visibleCircles() where item.id != editingId {
            overlays.append(RutMKOverlaySpec(key: "vcircle-\(item.id)",
                                             geometry: .circle(center: RutMKGeoPoint(item.center), radiusMeters: item.radiusMeters),
                                             style: .vectorCircle(item.style, selected: item.id == selectedId)))
        }
        for item in vectorStore.visiblePoints() where item.id != editingId {
            annotations.append(RutMKAnnotationSpec(
                key: "vpoint-\(item.id)",
                coordinate: RutMKGeoPoint(item.coordinate),
                zPriority: isVector ? MapAnnotationZ.vectorPointAbove : MapAnnotationZ.vectorPointBelow,
                marker: .vectorPoint(name: item.name, style: item.style,
                                     selected: item.id == selectedId, showName: isVector),
                tap: isVector ? .selectShape(id: item.id, layerId: item.layerId) : .none))
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
            annotations.append(databaseSymbol(
                key: "apt-\(index)-\(airport.id)", coordinate: airport.coordinate,
                bgColor: colorAirport, iconName: "airplane", label: airport.id,
                opacity: dbOpacity, scale: dbScale,
                tap: isVector ? .none : .point(name: airport.id, kind: .userAirport, coordinate: airport.coordinate)))
        }
        for (index, navaid) in doc.userNavaids.enumerated() where !inAnyRoute(navaid.id) {
            annotations.append(databaseSymbol(
                key: "nav-\(index)-\(navaid.id)", coordinate: navaid.coordinate,
                bgColor: colorNavaid, iconName: "antenna.radiowaves.left.and.right", label: navaid.id,
                opacity: dbOpacity, scale: dbScale,
                tap: isVector ? .none : .point(name: navaid.id, kind: .userNavaid, coordinate: navaid.coordinate)))
        }
        for (index, wp) in doc.userWaypoints.enumerated() where !inAnyRoute(wp.id) {
            annotations.append(RutMKAnnotationSpec(
                key: "wpt-\(index)-\(wp.id)",
                coordinate: RutMKGeoPoint(Self.displayCoordinate(for: wp.coordinate)),
                zPriority: MapAnnotationZ.database,
                marker: .databaseWaypoint(label: wp.id, isZero: Self.isZero(wp.coordinate),
                                          opacity: dbOpacity, scale: dbScale),
                tap: .point(name: wp.id, kind: .userWaypoint, coordinate: wp.coordinate)))
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

        // 3. Active route
        if let route = activeRoute {
            let points = navStore.mapPoints(for: route)
            let legDistances = navStore.legDistancesNM(for: route)
            if points.count >= 2 {
                overlays.append(RutMKOverlaySpec(key: "route-active-\(route.id)",
                                                 geometry: .polyline(points.map { RutMKGeoPoint(Self.displayCoordinate(for: $0.coordinate)) }),
                                                 style: .route(active: true, opacity: vectorDim)))
            }
            for (idx, p) in points.enumerated() {
                annotations.append(RutMKAnnotationSpec(
                    key: "a-\(idx)",
                    coordinate: RutMKGeoPoint(Self.displayCoordinate(for: p.coordinate)),
                    zPriority: MapAnnotationZ.activeRoute,
                    marker: .routePoint(name: p.name, kind: p.kind, waypointType: waypointType(for: p),
                                        color: colorActive, contentColor: .white,
                                        showLabel: showMapLabels && !isVector,
                                        opacity: vectorDim, scale: 1.0),
                    tap: isVector ? .none : .point(p)))

                if showMapLabels && !isVector && idx < points.count - 1 && idx < legDistances.count {
                    let a = Self.displayCoordinate(for: p.coordinate)
                    let b = Self.displayCoordinate(for: points[idx + 1].coordinate)
                    annotations.append(RutMKAnnotationSpec(
                        key: "d-\(idx)",
                        coordinate: RutMKGeoPoint(CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2.0,
                                                                         longitude: (a.longitude + b.longitude) / 2.0)),
                        zPriority: MapAnnotationZ.activeRoute,
                        marker: .legDistance(String(format: "%.1fN", legDistances[idx])),
                        tap: .none))
                }
            }
        }

        return RutMKContent(overlays: overlays, annotations: annotations)
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

    /// Keeps the shared camera when switching map engine; otherwise the same start
    /// position as RutMapView.configureInitialCamera().
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

    /// Same styling as the corresponding SwiftUI MapPolygon/MapPolyline/MapCircle in RutMapView.
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
}

private enum RutMKMarker: Equatable {
    case databaseSymbol(bgColor: Color, iconName: String, label: String, showLabel: Bool, opacity: Double, scale: Double)
    case databaseWaypoint(label: String, isZero: Bool, opacity: Double, scale: Double)
    case routePoint(name: String, kind: RoutePointKind, waypointType: WaypointType?,
                    color: Color, contentColor: Color, showLabel: Bool, opacity: Double, scale: Double)
    case legDistance(String)
    case vectorPoint(name: String, style: VectorStyle, selected: Bool, showName: Bool)
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

private struct RutMKHandlers {
    var pointTap: ((RouteMapPoint) -> Void)?
    var longPress: ((CLLocationCoordinate2D) -> Void)?
    var selectShape: (UUID, UUID) -> Void
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
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.handlers = handlers
        coordinator.applyStyle(mapStyle, to: mapView)
        coordinator.applyOverlays(content.overlays, to: mapView)
        coordinator.applyAnnotations(content.annotations, to: mapView)
    }
}

private final class RutMKCoordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
    var handlers: RutMKHandlers?

    private var overlaysByKey: [String: (spec: RutMKOverlaySpec, overlay: MKOverlay)] = [:]
    private var overlaySpecs: [ObjectIdentifier: RutMKOverlaySpec] = [:]
    private var annotationsByKey: [String: RutMKMarkerAnnotation] = [:]
    private var appliedStyle: RutMapStyle?
    private var labelsVisible: Bool?

    // MARK: Applying content

    func applyStyle(_ style: RutMapStyle, to mapView: MKMapView) {
        guard style != appliedStyle else { return }
        appliedStyle = style
        mapView.preferredConfiguration = style.mkConfiguration
    }

    /// Replaces only overlays whose spec changed, inserting new ones at their drawing position.
    func applyOverlays(_ specs: [RutMKOverlaySpec], to mapView: MKMapView) {
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
    func applyAnnotations(_ specs: [RutMKAnnotationSpec], to mapView: MKMapView) {
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
            if spec.coordinate != annotation.spec.coordinate {
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
            annotationsByKey[key] = annotation
            added.append(annotation)
        }
        if !added.isEmpty { mapView.addAnnotations(added) }
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
        return markerView
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
        // Taps are handled by the marker's SwiftUI content; don't keep MapKit selection state.
        mapView.deselectAnnotation(annotation, animated: false)
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

    // MARK: Long press

    @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        // Presses on markers are reserved for dragging (migration step 2).
        var hit = mapView.hitTest(point, with: nil)
        while let view = hit {
            if view is MKAnnotationView { return }
            hit = view.superview
        }
        handlers?.longPress?(mapView.convert(point, toCoordinateFrom: mapView))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
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

/// Annotation view that hosts the same SwiftUI marker views RutMapView uses.
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

/// Marker content, copied from RutMapView's annotation builders.
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

        case let .databaseWaypoint(label, isZero, opacity, scale):
            RutMKWaypointMarkerView(label: label, isZero: isZero)
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
        }
    }
}

/// Database waypoint marker (ring with a pin), as drawn inline in RutMapView.
private struct RutMKWaypointMarkerView: View {
    let label: String
    let isZero: Bool

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
