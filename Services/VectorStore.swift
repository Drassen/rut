import Foundation
import Combine
import MapKit

// MARK: - Flat renderable types (for MapKit ForEach)

struct FlatVectorPolygon: Identifiable {
    let id: UUID
    let layerId: UUID
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    let style: VectorStyle
    let isSystem: Bool
}

struct FlatVectorPolyline: Identifiable {
    let id: UUID
    let layerId: UUID
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    let style: VectorStyle
    let isSystem: Bool
}

struct FlatVectorCircle: Identifiable {
    let id: UUID
    let layerId: UUID
    let name: String
    let center: CLLocationCoordinate2D
    let radiusMeters: Double
    let style: VectorStyle
    let isSystem: Bool
}

struct FlatVectorPoint: Identifiable {
    let id: UUID
    let layerId: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
    let style: VectorStyle
    let isSystem: Bool
}

// MARK: - DrawingTool

enum DrawingTool: Equatable {
    case none
    case point
    case polyline
    case polygon
    case circle
    case corridor
}

// MARK: - DrawingStateMachine

final class DrawingStateMachine: ObservableObject {
    @Published private(set) var vertices: [CLLocationCoordinate2D] = []
    @Published var ghostCoord: CLLocationCoordinate2D? = nil

    var isActive: Bool { !vertices.isEmpty }

    /// Returns minimum vertices needed before commit is valid.
    func minVertices(for tool: DrawingTool) -> Int {
        switch tool {
        case .none:    return 0
        case .point:   return 1
        case .circle:  return 2
        case .polyline: return 2
        case .polygon:  return 3
        case .corridor:  return 2
        }
    }

    func handleGhostMove(to coord: CLLocationCoordinate2D) {
        ghostCoord = coord
    }

    func handleTap(at coord: CLLocationCoordinate2D, tool: DrawingTool) {
        switch tool {
        case .none:    break
        case .point:   vertices = [coord]
        case .polyline, .polygon, .corridor: vertices.append(coord)
        case .circle:
            if vertices.isEmpty {
                vertices = [coord]   // tap 1 = center
            } else {
                vertices = [vertices[0], coord]  // tap 2 = radius point
            }
        }
    }

    func undoLastVertex() {
        if !vertices.isEmpty { vertices.removeLast() }
    }

    func commitAndReset(tool: DrawingTool, name: String, style: VectorStyle, widthMeters: Double = 50) -> VectorShape? {
        defer { reset() }
        switch tool {
        case .none:
            return nil
        case .point:
            guard let v = vertices.first else { return nil }
            return VectorShape(name: name, geometry: .point(lat: v.latitude, lon: v.longitude), style: style)
        case .polyline:
            guard vertices.count >= 2 else { return nil }
            return VectorShape(name: name,
                               geometry: .polyline(coordinates: vertices.map { [$0.latitude, $0.longitude] }),
                               style: style)
        case .polygon:
            guard vertices.count >= 3 else { return nil }
            return VectorShape(name: name,
                               geometry: .polygon(coordinates: vertices.map { [$0.latitude, $0.longitude] }),
                               style: style)
        case .circle:
            guard vertices.count == 2 else { return nil }
            let center = vertices[0]; let edge = vertices[1]
            let dist = CLLocation(latitude: center.latitude, longitude: center.longitude)
                .distance(from: CLLocation(latitude: edge.latitude, longitude: edge.longitude))
            return VectorShape(name: name,
                               geometry: .circle(lat: center.latitude, lon: center.longitude, radiusMeters: dist),
                               style: style)
        case .corridor:
            guard vertices.count >= 2 else { return nil }
            let ring = Self.makeCorridorPolygon(from: vertices, radiusMeters: widthMeters / 2)
            return VectorShape(name: name,
                               geometry: .polygon(coordinates: ring.map { [$0.latitude, $0.longitude] }),
                               style: style)
        }
    }

    func cancel() { reset() }

    // MARK: - Geo helpers (flat-earth approximation, sufficient at tactical scales)

    private static func geoDistance(_ a: CLLocationCoordinate2D,
                                    _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func geoBearing(_ from: CLLocationCoordinate2D,
                                   _ to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude  * .pi / 180
        let lat2 = to.latitude    * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    private static func geoInterpolate(from: CLLocationCoordinate2D,
                                       to: CLLocationCoordinate2D,
                                       fraction: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude:  from.latitude  + (to.latitude  - from.latitude)  * fraction,
            longitude: from.longitude + (to.longitude - from.longitude) * fraction
        )
    }

    private static func geoOffset(from coord: CLLocationCoordinate2D,
                                  bearingDeg: Double,
                                  meters: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let d = meters / R
        let brng = bearingDeg * .pi / 180
        let lat1 = coord.latitude  * .pi / 180
        let lon1 = coord.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(brng))
        let lon2 = lon1 + atan2(sin(brng) * sin(d) * cos(lat1),
                                cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi,
                                     longitude: lon2 * 180 / .pi)
    }

    private func reset() {
        vertices = []
        ghostCoord = nil
    }

    // MARK: - Corridor geometry

    /// Builds a rounded offset polygon around an axis polyline.
    /// radiusMeters is the buffer on each side.
    /// End caps are 8-step semicircles; bends are 4-step arcs.
    static func makeCorridorPolygon(from axis: [CLLocationCoordinate2D],
                                    radiusMeters: Double = 500) -> [CLLocationCoordinate2D] {
        guard axis.count >= 2 else { return [] }

        let bearings = (0..<axis.count - 1).map { geoBearing(axis[$0], axis[$0 + 1]) }
        let capSteps = 4

        // Build right side (forward) and left side (forward)
        var right: [CLLocationCoordinate2D] = []
        var left:  [CLLocationCoordinate2D] = []

        right.append(geoOffset(from: axis[0], bearingDeg: bearings[0] + 90, meters: radiusMeters))
        left.append( geoOffset(from: axis[0], bearingDeg: bearings[0] - 90, meters: radiusMeters))

        for i in 1..<axis.count - 1 {
            let b1 = bearings[i - 1], b2 = bearings[i]
            let v  = axis[i]
            right.append(offsetIntersection(vertex: v, b1: b1, b2: b2, sideMult: +1, radius: radiusMeters))
            left.append( offsetIntersection(vertex: v, b1: b1, b2: b2, sideMult: -1, radius: radiusMeters))
        }

        right.append(geoOffset(from: axis.last!, bearingDeg: bearings.last! + 90, meters: radiusMeters))
        left.append( geoOffset(from: axis.last!, bearingDeg: bearings.last! - 90, meters: radiusMeters))

        // End cap: right → (sweep through forward direction) → left
        let endCap   = arcExplicit(center: axis.last!,
                                   from: bearings.last! + 90,
                                   to:   bearings.last! - 90,
                                   throughBearing: bearings.last!,
                                   r: radiusMeters, steps: capSteps)

        // Start cap: left → (sweep through backward direction) → right
        let startCap = arcExplicit(center: axis[0],
                                   from: bearings[0] - 90,
                                   to:   bearings[0] + 90,
                                   throughBearing: bearings[0] + 180,
                                   r: radiusMeters, steps: capSteps)

        var ring = right
        ring.append(contentsOf: endCap.dropFirst())
        ring.append(contentsOf: left.reversed())
        ring.append(contentsOf: startCap.dropFirst())
        ring.append(ring[0]) // close
        return ring
    }

    /// Returns the intersection point of the two offset lines at an interior vertex.
    /// sideMult: +1 = right offset, -1 = left offset.
    /// Falls back to the bisector point if lines are nearly parallel.
    private static func offsetIntersection(vertex: CLLocationCoordinate2D,
                                            b1: Double, b2: Double,
                                            sideMult: Double,
                                            radius: Double) -> CLLocationCoordinate2D {
        let p1 = geoOffset(from: vertex, bearingDeg: b1 + sideMult * 90, meters: radius)
        let p2 = geoOffset(from: vertex, bearingDeg: b2 + sideMult * 90, meters: radius)

        // Flat-earth local coords (meters from vertex)
        let mLat = 111_320.0
        let mLon = mLat * cos(vertex.latitude * .pi / 180)
        let p1x = (p1.longitude - vertex.longitude) * mLon
        let p1y = (p1.latitude  - vertex.latitude)  * mLat
        let p2x = (p2.longitude - vertex.longitude) * mLon
        let p2y = (p2.latitude  - vertex.latitude)  * mLat

        // Direction vectors from bearings
        let b1r = b1 * .pi / 180, b2r = b2 * .pi / 180
        let d1x = sin(b1r), d1y = cos(b1r)
        let d2x = sin(b2r), d2y = cos(b2r)

        // Solve p1 + t*d1 = p2 + s*d2
        let denom = d1x * (-d2y) - d1y * (-d2x)
        guard abs(denom) > 1e-10 else {
            // Parallel — use midpoint of the two offset points
            return CLLocationCoordinate2D(
                latitude:  (p1.latitude  + p2.latitude)  / 2,
                longitude: (p1.longitude + p2.longitude) / 2)
        }
        let dx = p2x - p1x, dy = p2y - p1y
        let t  = (dx * (-d2y) - dy * (-d2x)) / denom
        let ix = p1x + t * d1x
        let iy = p1y + t * d1y
        return CLLocationCoordinate2D(
            latitude:  vertex.latitude  + iy / mLat,
            longitude: vertex.longitude + ix / mLon)
    }

    /// Sweeps an arc from `from` to `to` bearing via the shortest angular path, skipping the first point.
    private static func arcShortest(center: CLLocationCoordinate2D,
                                    from: Double, to: Double,
                                    r: Double, steps: Int) -> [CLLocationCoordinate2D] {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180  { delta -= 360 }
        if delta < -180 { delta += 360 }
        return (1...steps).map { i in
            geoOffset(from: center, bearingDeg: from + delta * Double(i) / Double(steps), meters: r)
        }
    }

    /// Sweeps an arc from `from` to `to` bearing, choosing the direction that passes through `throughBearing`.
    private static func arcExplicit(center: CLLocationCoordinate2D,
                                    from: Double, to: Double,
                                    throughBearing: Double,
                                    r: Double, steps: Int) -> [CLLocationCoordinate2D] {
        // Normalize all bearings to [0, 360)
        func n(_ b: Double) -> Double { var x = b.truncatingRemainder(dividingBy: 360); if x < 0 { x += 360 }; return x }
        let f = n(from), t = n(to), mid = n(throughBearing)

        // Try clockwise delta (positive)
        let cwDelta = n(t - f)  // 0...360
        // Does mid lie within f..f+cwDelta clockwise?
        let midCW = n(mid - f)
        let useClockwise = midCW <= cwDelta

        let delta = useClockwise ? cwDelta : -(360 - cwDelta)
        return (0...steps).map { i in
            geoOffset(from: center, bearingDeg: f + delta * Double(i) / Double(steps), meters: r)
        }
    }
}

// MARK: - VectorStore

final class VectorStore: ObservableObject {
    @Published var layers: [VectorLayer] = []
    @Published var activeLayerId: UUID? = nil
    @Published var activeTool: DrawingTool = .none
    @Published var newShapeStyle: VectorStyle = VectorStyle()
    @Published var activeShapeId: UUID? = nil
    @Published var activeShapeLayerId: UUID? = nil
    @Published var isEditingShape: Bool = false
    @Published var editingVertices: [CLLocationCoordinate2D] = []
    /// Mirrors the LFV airspace system layer's isVisible flag.
    /// Separate @Published so the map can gate airspace rendering without
    /// going through layers (which re-renders user shapes too).
    @Published var airspaceVisible: Bool = true
    @Published var corridorWidth: Double = 1000

    // Drag state is panel-local — NOT @Published to avoid triggering map re-renders on every finger move
    var draggingLayerId: UUID? = nil
    var dragTargetIndex: Int? = nil
    var draggingLayerParentId: UUID? = nil
    var dragIntoTarget: Bool = false
    var draggingShapeId: UUID? = nil
    var draggingShapeLayerId: UUID? = nil
    var dragShapeTargetIndex: Int? = nil

    let drawing = DrawingStateMachine()

    private static let airspaceSystemLayerId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Forward drawing state changes through VectorStore so that
        // VectorToolbar and drawingPreviewOverlay re-render when vertices change.
        drawing.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Layer CRUD

    func addLayer(name: String, parentId: UUID? = nil) {
        let newLayer = VectorLayer(name: name)
        let effectiveParent = parentId.flatMap { id in layerIsSystem(id: id) ? nil : id }
        if let effectiveParent {
            mutateLayer(id: effectiveParent, in: &layers) { $0.children.append(newLayer) }
        } else {
            layers.append(newLayer)
        }
        activeLayerId = newLayer.id
    }

    func deleteLayer(id: UUID) {
        removeLayer(id: id, from: &layers)
        if activeLayerId == id { activeLayerId = nil }
    }

    func toggleLayerVisibility(id: UUID) {
        mutateLayer(id: id, in: &layers) { $0.isVisible.toggle() }
        if id == Self.airspaceSystemLayerId {
            airspaceVisible = findLayer(id: id)?.isVisible ?? airspaceVisible
        }
    }

    func toggleLayerExpanded(id: UUID) {
        mutateLayer(id: id, in: &layers) { $0.isExpanded.toggle() }
    }

    func renameLayer(id: UUID, name: String) {
        mutateLayer(id: id, in: &layers) { $0.name = name }
    }

    func findLayer(id: UUID) -> VectorLayer? {
        findLayerRecursive(id: id, in: layers)
    }

    func layerName(id: UUID) -> String? {
        findLayerRecursive(id: id, in: layers)?.name
    }

    private func findLayerRecursive(id: UUID, in search: [VectorLayer]) -> VectorLayer? {
        for layer in search {
            if layer.id == id { return layer }
            if let found = findLayerRecursive(id: id, in: layer.children) { return found }
        }
        return nil
    }

    func setActiveLayer(_ id: UUID) {
        activeLayerId = id
    }

    /// Returns true if the layer (or any ancestor) has isSystem = true.
    func layerIsSystem(id: UUID) -> Bool {
        layerIsSystemRecursive(id: id, in: layers)
    }

    private func layerIsSystemRecursive(id: UUID, in search: [VectorLayer]) -> Bool {
        for layer in search {
            if layer.id == id { return layer.isSystem }
            if layerIsSystemRecursive(id: id, in: layer.children) { return true }
        }
        return false
    }

    // MARK: - Shape Selection & Editing

    func selectShape(id: UUID, layerId: UUID) {
        activeShapeId = id
        activeShapeLayerId = layerId
        activeLayerId = layerId
        activeTool = .none
        drawing.cancel()
        isEditingShape = false
        editingVertices = []
        expandAncestors(of: layerId, in: &layers)
    }

    /// Expands every layer on the path from the root down to `targetId`.
    @discardableResult
    private func expandAncestors(of targetId: UUID, in search: inout [VectorLayer]) -> Bool {
        for i in search.indices {
            if search[i].id == targetId {
                search[i].isExpanded = true
                return true
            }
            if expandAncestors(of: targetId, in: &search[i].children) {
                search[i].isExpanded = true
                return true
            }
        }
        return false
    }

    func deselectShape() {
        activeShapeId = nil
        activeShapeLayerId = nil
        activeLayerId = nil
        isEditingShape = false
        editingVertices = []
    }

    func findShape(id: UUID) -> (shape: VectorShape, layerId: UUID)? {
        findShapeRecursive(id: id, in: layers)
    }

    private func findShapeRecursive(id: UUID, in search: [VectorLayer]) -> (shape: VectorShape, layerId: UUID)? {
        for layer in search {
            if let shape = layer.shapes.first(where: { $0.id == id }) { return (shape, layer.id) }
            if let found = findShapeRecursive(id: id, in: layer.children) { return found }
        }
        return nil
    }

    func beginEditingShape() {
        guard let id = activeShapeId, let found = findShape(id: id) else { return }
        editingVertices = extractVertices(from: found.shape)
        isEditingShape = true
    }

    func commitShapeEdit() {
        guard let id = activeShapeId, let layerId = activeShapeLayerId,
              let found = findShape(id: id) else { isEditingShape = false; return }
        var updated = found.shape
        updated.geometry = buildGeometry(from: updated.geometry, vertices: editingVertices)
        updateShape(updated, in: layerId)
        isEditingShape = false
        editingVertices = []
    }

    func cancelShapeEdit() {
        isEditingShape = false
        editingVertices = []
    }

    func moveEditVertex(at index: Int, to coord: CLLocationCoordinate2D) {
        guard index < editingVertices.count else { return }
        editingVertices[index] = coord
    }

    private func extractVertices(from shape: VectorShape) -> [CLLocationCoordinate2D] {
        switch shape.geometry {
        case .point(let lat, let lon):
            return [CLLocationCoordinate2D(latitude: lat, longitude: lon)]
        case .polyline(let coords), .polygon(let coords):
            return coords.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        case .circle(let lat, let lon, let r):
            let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let edgeLat = lat + (r / 111_320.0)
            return [center, CLLocationCoordinate2D(latitude: edgeLat, longitude: lon)]
        }
    }

    private func buildGeometry(from original: VectorGeometry, vertices: [CLLocationCoordinate2D]) -> VectorGeometry {
        switch original {
        case .point:
            guard let v = vertices.first else { return original }
            return .point(lat: v.latitude, lon: v.longitude)
        case .polyline:
            return .polyline(coordinates: vertices.map { [$0.latitude, $0.longitude] })
        case .polygon:
            return .polygon(coordinates: vertices.map { [$0.latitude, $0.longitude] })
        case .circle:
            guard vertices.count >= 2 else { return original }
            let dist = CLLocation(latitude: vertices[0].latitude, longitude: vertices[0].longitude)
                .distance(from: CLLocation(latitude: vertices[1].latitude, longitude: vertices[1].longitude))
            return .circle(lat: vertices[0].latitude, lon: vertices[0].longitude, radiusMeters: dist)
        }
    }

    // MARK: - Unified panel flat list (layers + shapes, for drag reorder)

    enum FlatPanelEntry {
        case layer(VectorLayer, parentId: UUID?, depth: Int)
        case shape(VectorShape, layerId: UUID, depth: Int)

        var id: UUID {
            switch self {
            case .layer(let l, _, _): return l.id
            case .shape(let s, _, _): return s.id
            }
        }
    }

    func flatPanelEntries() -> [FlatPanelEntry] {
        var result: [FlatPanelEntry] = []
        collectPanelEntries(layers: layers, parentId: nil, depth: 0, into: &result)
        return result
    }

    private func collectPanelEntries(layers: [VectorLayer], parentId: UUID?, depth: Int,
                                      into result: inout [FlatPanelEntry]) {
        for layer in layers {
            result.append(.layer(layer, parentId: parentId, depth: depth))
            if layer.isExpanded {
                for shape in layer.shapes {
                    result.append(.shape(shape, layerId: layer.id, depth: depth))
                }
                collectPanelEntries(layers: layer.children, parentId: layer.id,
                                    depth: depth + 1, into: &result)
            }
        }
    }

    /// Move a shape to any position in the visible panel list (cross-layer).
    func moveShapeToFlatPanel(shapeId: UUID, fromLayerId: UUID, toPanelIndex: Int) {
        let flat = flatPanelEntries()
        guard let movedShape = findShape(id: shapeId)?.shape else { return }
        let clamped = max(0, min(flat.count - 1, toPanelIndex))
        let target  = flat[clamped]

        // Remove from source layer
        mutateLayer(id: fromLayerId, in: &layers) { $0.shapes.removeAll { $0.id == shapeId } }

        switch target {
        case .shape(let targetShape, let targetLayerId, _):
            guard !layerIsSystem(id: targetLayerId) else {
                mutateLayer(id: fromLayerId, in: &layers) { $0.shapes.append(movedShape) }
                return
            }
            mutateLayer(id: targetLayerId, in: &layers) { layer in
                let idx = layer.shapes.firstIndex(where: { $0.id == targetShape.id }) ?? layer.shapes.count
                layer.shapes.insert(movedShape, at: idx)
            }
        case .layer(let targetLayer, _, _):
            guard !targetLayer.isSystem else {
                mutateLayer(id: fromLayerId, in: &layers) { $0.shapes.append(movedShape) }
                return
            }
            mutateLayer(id: targetLayer.id, in: &layers) { $0.shapes.append(movedShape) }
        }
    }

    // MARK: - Flat layer list (for cross-level drag reorder)

    struct FlatLayerEntry {
        let layer: VectorLayer
        let parentId: UUID?
        let depth: Int
    }

    /// Returns all layers in current display order (DFS, respects isExpanded).
    func flatLayerEntries() -> [FlatLayerEntry] {
        var result: [FlatLayerEntry] = []
        collectFlat(layers: layers, parentId: nil, depth: 0, into: &result)
        return result
    }

    private func collectFlat(layers: [VectorLayer], parentId: UUID?, depth: Int,
                              into result: inout [FlatLayerEntry]) {
        for layer in layers {
            result.append(FlatLayerEntry(layer: layer, parentId: parentId, depth: depth))
            if layer.isExpanded {
                collectFlat(layers: layer.children, parentId: layer.id, depth: depth + 1, into: &result)
            }
        }
    }

    /// Move a layer (by id) so it appears at the given flat index in the visible list.
    /// If `asChild` is true the layer becomes the first child of the target row's layer.
    func moveLayerToFlatIndex(_ id: UUID, flatIndex dest: Int, asChild: Bool = false) {
        var flat = flatLayerEntries()
        guard let sourceIdx = flat.firstIndex(where: { $0.layer.id == id }) else { return }
        guard let movedLayer = findLayerRecursive(id: id, in: layers) else { return }
        // Prevent user layers from being dragged above root-level system layers.
        let firstUserFlatIdx = flat.firstIndex(where: { $0.parentId == nil && !$0.layer.isSystem }) ?? 0
        let isDraggingRootUser = flat[sourceIdx].parentId == nil && !flat[sourceIdx].layer.isSystem
        let minDest = isDraggingRootUser ? firstUserFlatIdx : 0
        let clampedDest = max(minDest, min(flat.count - 1, dest))
        guard !(clampedDest == sourceIdx && !asChild) else { return }

        // Guard against dropping into own subtree
        if asChild {
            var cur: UUID? = flat[clampedDest].layer.id
            while let c = cur {
                if c == id { return }
                cur = flat.first(where: { $0.layer.id == c })?.parentId
            }
        }

        // Remove from current parent
        let sourceEntry = flat[sourceIdx]
        if let pId = sourceEntry.parentId {
            mutateLayer(id: pId, in: &layers) { $0.children.removeAll { $0.id == id } }
        } else {
            layers.removeAll { $0.id == id }
        }

        // Recompute flat list after removal
        flat = flatLayerEntries()

        if asChild {
            // Insert as first child of the target layer
            let targetId = flat[max(0, min(flat.count - 1, clampedDest > sourceIdx ? clampedDest - 1 : clampedDest))].layer.id
            mutateLayer(id: targetId, in: &layers) { $0.children.insert(movedLayer, at: 0) }
        } else {
            let adjusted = max(0, min(flat.count, clampedDest > sourceIdx ? clampedDest - 1 : clampedDest))
            if adjusted >= flat.count {
                layers.append(movedLayer)
            } else {
                let target = flat[adjusted]
                if let pId = target.parentId {
                    mutateLayer(id: pId, in: &layers) { parent in
                        let idx = parent.children.firstIndex(where: { $0.id == target.layer.id }) ?? parent.children.count
                        parent.children.insert(movedLayer, at: idx)
                    }
                } else {
                    let idx = layers.firstIndex(where: { $0.id == target.layer.id }) ?? layers.count
                    layers.insert(movedLayer, at: idx)
                }
            }
        }
    }

    // MARK: - Reorder (within-level helpers kept for other uses)

    /// Move a top-level layer from one index to another.
    func moveTopLevelLayer(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < layers.count,
              destination >= 0, destination < layers.count else { return }
        let item = layers.remove(at: source)
        layers.insert(item, at: destination)
    }

    /// Move a child layer within its parent.
    func moveChildLayer(id: UUID, from source: Int, to destination: Int, inParentId: UUID) {
        mutateLayer(id: inParentId, in: &layers) { parent in
            guard source != destination,
                  source >= 0, source < parent.children.count,
                  destination >= 0, destination < parent.children.count else { return }
            let item = parent.children.remove(at: source)
            parent.children.insert(item, at: destination)
        }
    }

    /// Move a shape within its layer.
    func moveShape(from source: Int, to destination: Int, inLayerId: UUID) {
        mutateLayer(id: inLayerId, in: &layers) { layer in
            guard source != destination,
                  source >= 0, source < layer.shapes.count,
                  destination >= 0, destination < layer.shapes.count else { return }
            let item = layer.shapes.remove(at: source)
            layer.shapes.insert(item, at: destination)
        }
    }

    // MARK: - Shape CRUD

    func addShape(_ shape: VectorShape, to layerId: UUID) {
        mutateLayer(id: layerId, in: &layers) { $0.shapes.append(shape) }
    }

    func deleteShape(shapeId: UUID, in layerId: UUID) {
        mutateLayer(id: layerId, in: &layers) { $0.shapes.removeAll { $0.id == shapeId } }
    }

    func updateShape(_ shape: VectorShape, in layerId: UUID) {
        mutateLayer(id: layerId, in: &layers) { layer in
            if let idx = layer.shapes.firstIndex(where: { $0.id == shape.id }) {
                layer.shapes[idx] = shape
            }
        }
    }

    // MARK: - Document sync

    /// Returns non-system layers for .rut export / document storage.
    func documentLayers() -> [VectorLayer] {
        layers.filter { !$0.isSystem }
    }

    /// Merges user layers from an imported document into the existing layer list.
    /// Existing layers are preserved; incoming layers are appended if no layer
    /// with the same name already exists. System layers are kept at the top.
    func syncFromDocument(_ doc: NavigationDocument) {
        let systemLayers = layers.filter { $0.isSystem }
        let existingUserLayers = layers.filter { !$0.isSystem }
        let incoming = doc.vectorLayers.filter { !$0.isSystem }
        let newLayers = incoming.filter { inLayer in
            !existingUserLayers.contains(where: { $0.name == inLayer.name })
        }
        layers = systemLayers + existingUserLayers + newLayers
    }

    // MARK: - Airspace system layer

    func syncAirspaceSystemLayer(zones: [AirspaceZone]) {
        let systemId = VectorStore.airspaceSystemLayerId
        let existing = layers.first(where: { $0.id == systemId })
        let wasVisible  = existing?.isVisible  ?? true
        let wasExpanded = existing?.isExpanded ?? false

        // System layer is metadata-only (shapes not stored — airspace is rendered
        // directly from AirspaceService.zones to avoid polluting the layers array
        // with hundreds of complex polygon shapes).
        let typeNames: [AirspaceZone.ZoneType: String] = [
            .ctr: "CTR", .atz: "ATZ", .rsta: "RSTA", .dnga: "DNGA"
        ]
        let typeOrder: [AirspaceZone.ZoneType] = [.ctr, .atz, .rsta, .dnga]
        let children: [VectorLayer] = typeOrder.compactMap { zoneType in
            let count = zones.filter { $0.type == zoneType }.count
            guard count > 0 else { return nil }
            return VectorLayer(name: "\(typeNames[zoneType]!) (\(count))", isSystem: true, isExpanded: false)
        }

        var systemLayer = VectorLayer(id: systemId, name: "LFV Luftrum", isSystem: true)
        systemLayer.isVisible  = wasVisible
        systemLayer.isExpanded = wasExpanded
        systemLayer.children   = children

        if let idx = layers.firstIndex(where: { $0.id == systemId }) {
            layers[idx] = systemLayer
        } else {
            layers.insert(systemLayer, at: 0)
        }
        airspaceVisible = wasVisible
    }

    // MARK: - Map rendering helpers

    // These functions only return USER (non-system) shapes.
    // Airspace (system layer) is rendered separately from AirspaceService.zones
    // so it doesn't re-render on every VectorStore state change.

    func visiblePolygons() -> [FlatVectorPolygon] {
        var result: [FlatVectorPolygon] = []
        collectByType(from: layers.filter { !$0.isSystem }, parentVisible: true, isSystem: false) { shape, layerId, _ in
            if case .polygon(let coords) = shape.geometry {
                let cl = coords.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                result.append(FlatVectorPolygon(id: shape.id, layerId: layerId, name: shape.name,
                                               coordinates: cl, style: shape.style, isSystem: false))
            }
        }
        return result
    }

    func visiblePolylines() -> [FlatVectorPolyline] {
        var result: [FlatVectorPolyline] = []
        collectByType(from: layers.filter { !$0.isSystem }, parentVisible: true, isSystem: false) { shape, layerId, _ in
            if case .polyline(let coords) = shape.geometry {
                let cl = coords.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                result.append(FlatVectorPolyline(id: shape.id, layerId: layerId, name: shape.name,
                                                coordinates: cl, style: shape.style, isSystem: false))
            }
        }
        return result
    }

    func visibleCircles() -> [FlatVectorCircle] {
        var result: [FlatVectorCircle] = []
        collectByType(from: layers.filter { !$0.isSystem }, parentVisible: true, isSystem: false) { shape, layerId, _ in
            if case .circle(let lat, let lon, let r) = shape.geometry {
                result.append(FlatVectorCircle(
                    id: shape.id, layerId: layerId, name: shape.name,
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    radiusMeters: r, style: shape.style, isSystem: false))
            }
        }
        return result
    }

    func visiblePoints() -> [FlatVectorPoint] {
        var result: [FlatVectorPoint] = []
        collectByType(from: layers.filter { !$0.isSystem }, parentVisible: true, isSystem: false) { shape, layerId, _ in
            if case .point(let lat, let lon) = shape.geometry {
                result.append(FlatVectorPoint(
                    id: shape.id, layerId: layerId, name: shape.name,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    style: shape.style, isSystem: false))
            }
        }
        return result
    }

    // MARK: - Drawing commit

    func commitDrawing(name: String) {
        let effectiveStyle: VectorStyle
        if activeTool == .point {
            var s = newShapeStyle
            s.strokeColor = "#FFFFFF"
            effectiveStyle = s
        } else if activeTool == .corridor {
            var s = newShapeStyle
            s.fillColor = "#00000000" // transparent fill
            effectiveStyle = s
        } else {
            effectiveStyle = newShapeStyle
        }
        let toolWidth = corridorWidth
        guard activeTool != .none,
              let shape = drawing.commitAndReset(tool: activeTool, name: name, style: effectiveStyle, widthMeters: toolWidth)
        else { return }

        let targetLayerId: UUID
        if let layerId = activeLayerId {
            targetLayerId = layerId
        } else if let firstUser = layers.first(where: { !$0.isSystem }) {
            targetLayerId = firstUser.id
            activeLayerId = targetLayerId
        } else {
            // No layer exists — auto-create one so the shape isn't lost
            let newLayer = VectorLayer(name: "Layer 1")
            layers.append(newLayer)
            activeLayerId = newLayer.id
            targetLayerId = newLayer.id
        }
        addShape(shape, to: targetLayerId)
        selectShape(id: shape.id, layerId: targetLayerId)
    }

    // MARK: - Private helpers

    @discardableResult
    private func mutateLayer(id: UUID, in layers: inout [VectorLayer],
                              mutation: (inout VectorLayer) -> Void) -> Bool {
        for i in layers.indices {
            if layers[i].id == id { mutation(&layers[i]); return true }
            if mutateLayer(id: id, in: &layers[i].children, mutation: mutation) { return true }
        }
        return false
    }

    @discardableResult
    private func removeLayer(id: UUID, from layers: inout [VectorLayer]) -> Bool {
        if let idx = layers.firstIndex(where: { $0.id == id && !$0.isSystem }) {
            layers.remove(at: idx)
            return true
        }
        for i in layers.indices {
            if removeLayer(id: id, from: &layers[i].children) { return true }
        }
        return false
    }

    private func collectByType(from layers: [VectorLayer], parentVisible: Bool, isSystem: Bool,
                               handler: (VectorShape, UUID, Bool) -> Void) {
        for layer in layers {
            let visible = parentVisible && layer.isVisible
            let sys = isSystem || layer.isSystem
            if visible { layer.shapes.filter { $0.isVisible }.forEach { handler($0, layer.id, sys) } }
            collectByType(from: layer.children, parentVisible: visible, isSystem: sys, handler: handler)
        }
    }
}
