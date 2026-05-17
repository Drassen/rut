import Foundation

struct GeoJSONVectorExportService: RouteExporting {
    let id = "geojson-vector"
    let displayName = "GeoJSON (.geojson)"
    let supportedExtensions = ["geojson"]

    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile] {
        let exportLayers = document.vectorLayers.filter { !$0.isSystem }
        guard !exportLayers.isEmpty else {
            throw RutError.invalidFormat("No vector layers to export")
        }

        var features: [[String: Any]] = []
        collectFeatures(from: exportLayers, into: &features)

        let geojson: [String: Any] = [
            "type": "FeatureCollection",
            "features": features
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: geojson, options: [.prettyPrinted, .sortedKeys])
        else {
            throw RutError.invalidFormat("GeoJSON serialization failed")
        }

        return [ExportedFile(filename: "VectorLayers.geojson", data: data)]
    }

    // MARK: - Feature collection

    private func collectFeatures(from layers: [VectorLayer], into features: inout [[String: Any]]) {
        for layer in layers {
            for shape in layer.shapes {
                if let feature = shapeToFeature(shape, layerName: layer.name) {
                    features.append(feature)
                }
            }
            collectFeatures(from: layer.children, into: &features)
        }
    }

    private func shapeToFeature(_ shape: VectorShape, layerName: String) -> [String: Any]? {
        var properties: [String: Any] = [
            "name": shape.name,
            "layer": layerName,
            "strokeColor": shape.style.strokeColor,
            "fillColor": shape.style.fillColor,
            "strokeWidth": shape.style.strokeWidth,
            "opacity": shape.style.opacity
        ]

        if !shape.notes.isEmpty {
            properties["notes"] = shape.notes
        }

        var geometry: [String: Any]?
        switch shape.geometry {
        case .point(let lat, let lon):
            geometry = [
                "type": "Point",
                "coordinates": [lon, lat]
            ]

        case .polyline(let coords):
            let flipped = coords.map { [$0[1], $0[0]] }
            geometry = [
                "type": "LineString",
                "coordinates": flipped
            ]

        case .polygon(let coords):
            let flipped = coords.map { [$0[1], $0[0]] }
            geometry = [
                "type": "Polygon",
                "coordinates": [flipped]
            ]

        case .circle(let lat, let lon, let r):
            let ring = circlePolygon(lat: lat, lon: lon, radiusMeters: r, points: 36)
            let flipped = ring.map { [$0[1], $0[0]] }
            geometry = [
                "type": "Polygon",
                "coordinates": [flipped]
            ]
        }

        guard let geometry = geometry else { return nil }

        return [
            "type": "Feature",
            "geometry": geometry,
            "properties": properties
        ]
    }

    private func circlePolygon(lat: Double, lon: Double, radiusMeters: Double, points: Int) -> [[Double]] {
        let earthRadius = 6_371_000.0
        let latRad = lat * .pi / 180
        return (0..<points).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(points)
            let dLat  = (radiusMeters / earthRadius) * cos(angle) * (180 / .pi)
            let dLon  = (radiusMeters / (earthRadius * cos(latRad))) * sin(angle) * (180 / .pi)
            return [lat + dLat, lon + dLon]
        }
    }
}
