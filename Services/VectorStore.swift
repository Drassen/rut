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
    case zigzag
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
        case .zigzag:  return 2
        }
    }

    func handleGhostMove(to coord: CLLocationCoordinate2D) {
        ghostCoord = coord
    }

    func handleTap(at coord: CLLocationCoordinate2D, tool: DrawingTool) {
        switch tool {
        case .none:    break
        case .point:   vertices = [coord]
        case .polyline, .polygon, .zigzag: vertices.append(coord)
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
        case .zigzag:
            guard vertices.count >= 2 else { return nil }
            let zigzagCoords = Self.makeZigzagCoords(from: vertices, widthMeters: widthMeters)
            return VectorShape(name: name,
                               geometry: .polyline(coordinates: zigzagCoords.map { [$0.latitude, $0.longitude] }),
                               style: style)
        }
    }

    func cancel() { reset() }

    // MARK: - Zigzag geometry

    /// Converts an axis polyline into a zigzag polyline.
    /// Teeth are at 30° to the axis, total width 50 m (±25 m from center).
    static func makeZigzagCoords(from axis: [CLLocationCoordinate2D], widthMeters: Double = 50) -> [CLLocationCoordinate2D] {
        let halfWidth = widthMeters / 2                        // meters each side
        let angleRad  = 30.0 * .pi / 180.0
        let stepAlong = halfWidth / tan(angleRad)              // ~43.3 m along axis per half-period

        var result: [CLLocationCoordinate2D] = [axis[0]]
        var distSinceLastPeak = 0.0
        var side = 1.0

        for segIdx in 0 ..< axis.count - 1 {
            let from = axis[segIdx]
            let to   = axis[segIdx + 1]
            let segLen = geoDistance(from, to)
            guard segLen > 0 else { continue }
            let bear = geoBearing(from, to)

            var walked = 0.0
            while walked < segLen {
                let nextPeakAt = stepAlong - distSinceLastPeak
                if nextPeakAt > segLen - walked {
                    distSinceLastPeak += segLen - walked
                    break
                }
                walked += nextPeakAt
                distSinceLastPeak = 0.0
                let center = geoInterpolate(from: from, to: to, fraction: walked / segLen)
                let peak   = geoOffset(from: center, bearingDeg: bear + 90.0, meters: side * halfWidth)
                result.append(peak)
                side = -side
            }
        }
        result.append(axis.last!)
        return result
    }

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
    @Published var zigzagWidth: Double = 50

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
        let clampedDest = max(0, min(flat.count - 1, dest))
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

    /// Replaces user (non-system) layers with those from an imported document.
    func syncFromDocument(_ doc: NavigationDocument) {
        let systemLayers = layers.filter { $0.isSystem }
        layers = doc.vectorLayers.filter { !$0.isSystem } + systemLayers
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
        guard activeTool != .none,
              let shape = drawing.commitAndReset(tool: activeTool, name: name, style: newShapeStyle, widthMeters: zigzagWidth)
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
