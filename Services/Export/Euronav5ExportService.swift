import Foundation

/// Exports the app's vector layers as a Euronav5 USER-database card layer
/// (USERN.tbl + USERN-{ID,LN,OI}.idx under db/SQL/).
///
/// All binary encoding lives in `Euronav5Encoder` (byte-exact port of the
/// verified reference implementation — see `Docs/Euronav5/`). This service
/// only maps the app's `VectorShape` model onto encoder figures.
struct Euronav5ExportService {

    enum Euronav5Layer: Int, CaseIterable {
        case zero = 0
        case one = 1
        case two = 2
        case three = 3
        case four = 4

        var filename: String {
            "USER\(rawValue + 1).tbl"
        }

        var displayName: String {
            "Layer \(rawValue)"
        }
    }

    /// Export all visible shapes of the given layers into one Euronav5
    /// layer file (plus its three index files). Returns relative card
    /// paths mapped to file contents; empty if there is nothing to export.
    func exportEuronav5Card(vectorLayers: [VectorLayer],
                            to layer: Euronav5Layer,
                            date: Date = Date()) -> [String: Data] {
        var shapes: [VectorShape] = []
        for vectorLayer in vectorLayers {
            collectShapesFlat(from: vectorLayer, into: &shapes)
        }

        // Shape order is the creation-order proxy for the session counter.
        let figures = shapes.compactMap(figure(from:))
        let objectIds = Euronav5Encoder.assignObjectIds(figures)
        guard let files = Euronav5Encoder.exportLayer(
            figures: figures, objectIds: objectIds,
            ts: Euronav5Encoder.Timestamp(date: date)) else {
            return [:]
        }

        let base = "db/SQL/USER\(layer.rawValue + 1)"
        return [
            "\(base).tbl": files.tbl,
            "\(base)-ID.idx": files.idIdx,
            "\(base)-LN.idx": files.lnIdx,
            "\(base)-OI.idx": files.oiIdx,
        ]
    }

    // MARK: - VectorShape -> Figure mapping

    private func figure(from shape: VectorShape) -> Euronav5Encoder.Figure? {
        guard shape.isVisible else { return nil }
        // Zone type is only meaningful for area shapes; plain drawings
        // carry an empty TYPE (APPERANCE is derived from it).
        let type = shape.dmgCategory == .area ? shape.dmgAreaType.rawValue : ""

        switch shape.geometry {
        case .point(let lat, let lon):
            guard let center = microdegrees(lat: lat, lon: lon) else { return nil }
            return Euronav5Encoder.Figure(
                kind: .point, name: shape.name, type: type, points: [center])

        case .circle(let lat, let lon, let radiusMeters):
            guard let center = microdegrees(lat: lat, lon: lon),
                  radiusMeters >= 0.5 else { return nil }
            return Euronav5Encoder.Figure(
                kind: .circle, name: shape.name, type: type, points: [center],
                radiusMeters: Int32(radiusMeters.rounded()))

        case .polyline(let coordinates):
            guard let points = microdegrees(coordinates: coordinates) else { return nil }
            // The planner classifies by geometric closure, not by tool:
            // a polyline ending on its first vertex is a closed polygon
            // (negative object id) — observed as "draw4" in set1.
            if points.count > 3, points.first! == points.last! {
                return Euronav5Encoder.Figure(
                    kind: .polygon, name: shape.name, type: type,
                    points: Array(points.dropLast()))
            }
            guard points.count >= 2 else { return nil }
            return Euronav5Encoder.Figure(
                kind: .line, name: shape.name, type: type, points: points)

        case .polygon(let coordinates):
            guard var points = microdegrees(coordinates: coordinates) else { return nil }
            if points.count > 1, points.first! == points.last! {
                points.removeLast()  // encoder appends the closing repeat
            }
            guard points.count >= 3 else { return nil }
            return Euronav5Encoder.Figure(
                kind: .polygon, name: shape.name, type: type, points: points)
        }
    }

    private func microdegrees(lat: Double, lon: Double) -> (Int32, Int32)? {
        guard lat.isFinite, lon.isFinite,
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (Euronav5Encoder.microdegrees(lat), Euronav5Encoder.microdegrees(lon))
    }

    private func microdegrees(coordinates: [[Double]]) -> [(Int32, Int32)]? {
        let pts = coordinates.compactMap { pair -> (Int32, Int32)? in
            guard pair.count >= 2 else { return nil }
            return microdegrees(lat: pair[0], lon: pair[1])
        }
        return pts.count == coordinates.count ? pts : nil
    }

    private func collectShapesFlat(from layer: VectorLayer,
                                   into shapes: inout [VectorShape]) {
        shapes.append(contentsOf: layer.shapes)
        for child in layer.children {
            collectShapesFlat(from: child, into: &shapes)
        }
    }
}
