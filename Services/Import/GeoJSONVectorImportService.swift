import Foundation

struct GeoJSONVectorImportService: RouteImporting {
    let supportedExtensions = ["geojson", "json"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        guard let data = try? Data(contentsOf: url) else {
            throw RutError.importFailed("Could not read GeoJSON file.")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]]
        else {
            throw RutError.importFailed("Invalid GeoJSON format: expected FeatureCollection.")
        }

        let layerName = url.deletingPathExtension().lastPathComponent
        var shapes: [VectorShape] = []

        for (index, feature) in features.enumerated() {
            if let shape = parseFeature(feature, index: index) {
                shapes.append(shape)
            }
        }

        let layer = VectorLayer(name: layerName, shapes: shapes)
        var doc = NavigationDocument()
        doc.vectorLayers = [layer]
        return doc
    }

    private func parseFeature(_ feature: [String: Any], index: Int) -> VectorShape? {
        guard let geometryDict = feature["geometry"] as? [String: Any],
              let type = geometryDict["type"] as? String
        else {
            return nil
        }

        let properties = feature["properties"] as? [String: Any] ?? [:]
        let name = properties["name"] as? String ?? "Shape \(index + 1)"
        var notes = ""

        var style = VectorStyle()
        if let strokeColor = properties["strokeColor"] as? String {
            style.strokeColor = strokeColor
        }
        if let fillColor = properties["fillColor"] as? String {
            style.fillColor = fillColor
        }
        if let strokeWidth = properties["strokeWidth"] as? Double {
            style.strokeWidth = strokeWidth
        }
        if let opacity = properties["opacity"] as? Double {
            style.opacity = opacity
        }

        if let propertiesNotes = properties["notes"] as? String {
            notes = propertiesNotes
        }

        var vectorGeometry: VectorGeometry?

        switch type {
        case "Point":
            if let coords = geometryDict["coordinates"] as? [Double], coords.count == 2 {
                let lon = coords[0], lat = coords[1]
                vectorGeometry = .point(lat: lat, lon: lon)
            }

        case "LineString":
            if let coords = geometryDict["coordinates"] as? [[Double]] {
                let flipped = coords.compactMap { c -> [Double]? in
                    guard c.count == 2 else { return nil }
                    return [c[1], c[0]]
                }
                if !flipped.isEmpty {
                    vectorGeometry = .polyline(coordinates: flipped)
                }
            }

        case "Polygon":
            if let rings = geometryDict["coordinates"] as? [[[Double]]], !rings.isEmpty {
                let outerRing = rings[0]
                let flipped = outerRing.compactMap { c -> [Double]? in
                    guard c.count == 2 else { return nil }
                    return [c[1], c[0]]
                }
                if !flipped.isEmpty {
                    vectorGeometry = .polygon(coordinates: flipped)
                }
            }

        case "MultiLineString":
            if let lineStrings = geometryDict["coordinates"] as? [[[Double]]] {
                for lineCoords in lineStrings {
                    let flipped = lineCoords.compactMap { c -> [Double]? in
                        guard c.count == 2 else { return nil }
                        return [c[1], c[0]]
                    }
                    if !flipped.isEmpty {
                        vectorGeometry = .polyline(coordinates: flipped)
                        break
                    }
                }
            }

        case "MultiPolygon":
            if let polygons = geometryDict["coordinates"] as? [[[[Double]]]], !polygons.isEmpty {
                let rings = polygons[0]
                if !rings.isEmpty {
                    let outerRing = rings[0]
                    let flipped = outerRing.compactMap { c -> [Double]? in
                        guard c.count == 2 else { return nil }
                        return [c[1], c[0]]
                    }
                    if !flipped.isEmpty {
                        vectorGeometry = .polygon(coordinates: flipped)
                    }
                }
            }

        default:
            return nil
        }

        guard let geom = vectorGeometry else { return nil }
        return VectorShape(name: name, notes: notes, geometry: geom, style: style)
    }
}
