import Foundation
import MapKit
import Combine

// MARK: - Flat renderable types (for MapKit ForEach)

struct FlatVectorPolygon: Identifiable {
    let id: UUID
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    let style: VectorStyle
}

struct FlatVectorPolyline: Identifiable {
    let id: UUID
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    let style: VectorStyle
}

struct FlatVectorCircle: Identifiable {
    let id: UUID
    let name: String
    let center: CLLocationCoordinate2D
    let radiusMeters: Double
    let style: VectorStyle
}

struct FlatVectorPoint: Identifiable {
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
    let style: VectorStyle
}

// MARK: - DrawingTool

enum DrawingTool: Equatable {
    case none
    case point
    case polyline
    case polygon
    case circle
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
        }
    }

    func handleTap(at coord: CLLocationCoordinate2D, tool: DrawingTool) {
        switch tool {
        case .none:    break
        case .point:   vertices = [coord]
        case .polyline, .polygon: vertices.append(coord)
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

    func commitAndReset(tool: DrawingTool, name: String, style: VectorStyle) -> VectorShape? {
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
        }
    }

    func cancel() { reset() }

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

    let drawing = DrawingStateMachine()
    private var drawingSink: AnyCancellable?

    private static let airspaceSystemLayerId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    init() {
        // Forward DrawingStateMachine changes so observers of VectorStore re-render
        drawingSink = drawing.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - Layer CRUD

    func addLayer(name: String, parentId: UUID? = nil) {
        let newLayer = VectorLayer(name: name)
        if let parentId {
            mutateLayer(id: parentId, in: &layers) { $0.children.append(newLayer) }
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
    }

    func toggleLayerExpanded(id: UUID) {
        mutateLayer(id: id, in: &layers) { $0.isExpanded.toggle() }
    }

    func renameLayer(id: UUID, name: String) {
        mutateLayer(id: id, in: &layers) { $0.name = name }
    }

    func setActiveLayer(_ id: UUID) {
        activeLayerId = id
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
        let wasVisible = layers.first(where: { $0.id == systemId })?.isVisible ?? true

        let typeOrder: [AirspaceZone.ZoneType] = [.ctr, .atz, .rsta, .dnga]
        let typeNames: [AirspaceZone.ZoneType: String] = [
            .ctr: "CTR", .atz: "ATZ", .rsta: "RSTA", .dnga: "DNGA"
        ]
        let typeColors: [AirspaceZone.ZoneType: (stroke: String, fill: String)] = [
            .ctr:  ("#3366FF", "#3366FF14"),
            .atz:  ("#00CCCC", "#00CCCC14"),
            .rsta: ("#FF3322", "#FF33221E"),
            .dnga: ("#FF8800", "#FF88001E"),
        ]

        var children: [VectorLayer] = []
        for zoneType in typeOrder {
            let matching = zones.filter { $0.type == zoneType }
            guard !matching.isEmpty else { continue }
            let colors = typeColors[zoneType]!
            let shapes = matching.map { zone in
                VectorShape(
                    name: zone.name,
                    geometry: .polygon(coordinates: zone.coordinates.map { [$0.latitude, $0.longitude] }),
                    style: VectorStyle(strokeColor: colors.stroke, fillColor: colors.fill,
                                      strokeWidth: 1.0, opacity: 1.0)
                )
            }
            var child = VectorLayer(name: typeNames[zoneType]!, isSystem: true, isExpanded: false)
            child.shapes = shapes
            children.append(child)
        }

        var systemLayer = VectorLayer(id: systemId, name: "LFV Luftrum", isSystem: true)
        systemLayer.isVisible = wasVisible
        systemLayer.children = children

        if let idx = layers.firstIndex(where: { $0.id == systemId }) {
            layers[idx] = systemLayer
        } else {
            layers.insert(systemLayer, at: 0)
        }
    }

    // MARK: - Map rendering helpers

    func visiblePolygons() -> [FlatVectorPolygon] {
        var result: [FlatVectorPolygon] = []
        collectByType(from: layers, parentVisible: true) { shape in
            if case .polygon(let coords) = shape.geometry {
                let cl = coords.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                result.append(FlatVectorPolygon(id: shape.id, name: shape.name,
                                               coordinates: cl, style: shape.style))
            }
        }
        return result
    }

    func visiblePolylines() -> [FlatVectorPolyline] {
        var result: [FlatVectorPolyline] = []
        collectByType(from: layers, parentVisible: true) { shape in
            if case .polyline(let coords) = shape.geometry {
                let cl = coords.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                result.append(FlatVectorPolyline(id: shape.id, name: shape.name,
                                                coordinates: cl, style: shape.style))
            }
        }
        return result
    }

    func visibleCircles() -> [FlatVectorCircle] {
        var result: [FlatVectorCircle] = []
        collectByType(from: layers, parentVisible: true) { shape in
            if case .circle(let lat, let lon, let r) = shape.geometry {
                result.append(FlatVectorCircle(
                    id: shape.id, name: shape.name,
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    radiusMeters: r, style: shape.style))
            }
        }
        return result
    }

    func visiblePoints() -> [FlatVectorPoint] {
        var result: [FlatVectorPoint] = []
        collectByType(from: layers, parentVisible: true) { shape in
            if case .point(let lat, let lon) = shape.geometry {
                result.append(FlatVectorPoint(
                    id: shape.id, name: shape.name,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    style: shape.style))
            }
        }
        return result
    }

    // MARK: - Drawing commit

    func commitDrawing(name: String) {
        guard activeTool != .none,
              let shape = drawing.commitAndReset(tool: activeTool, name: name, style: newShapeStyle)
        else { return }

        if let layerId = activeLayerId {
            addShape(shape, to: layerId)
        } else if let firstUser = layers.first(where: { !$0.isSystem }) {
            addShape(shape, to: firstUser.id)
        }
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

    private func collectByType(from layers: [VectorLayer], parentVisible: Bool,
                               handler: (VectorShape) -> Void) {
        for layer in layers {
            let visible = parentVisible && layer.isVisible
            if visible { layer.shapes.filter { $0.isVisible }.forEach(handler) }
            collectByType(from: layer.children, parentVisible: visible, handler: handler)
        }
    }
}
