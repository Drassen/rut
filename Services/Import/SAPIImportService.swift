import Foundation

struct SAPIImportService: RouteImporting {
    let supportedExtensions = ["sapi"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        guard let data = try? Data(contentsOf: url) else {
            throw RutError.importFailed("Could not read SAPI file.")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RutError.importFailed("Invalid SAPI format: expected JSON object.")
        }

        // Detect weather.sapi by presence of _metadata (instead of metadata + features)
        if json["_metadata"] != nil && json["features"] == nil {
            throw RutError.importFailed("Weather SAPI files contain no geometry and cannot be imported as vectors.")
        }

        guard let features = json["features"] as? [[String: Any]] else {
            throw RutError.importFailed("Invalid SAPI format: expected FeatureCollection with 'features' array.")
        }

        // Group shapes by layer_id
        var shapesByLayerId: [String: [VectorShape]] = [:]

        for (index, feature) in features.enumerated() {
            if let shape = parseFeature(feature, index: index) {
                let layerId = (feature["properties"] as? [String: Any])?["layer_id"] as? String ?? "Default"
                if shapesByLayerId[layerId] == nil {
                    shapesByLayerId[layerId] = []
                }
                shapesByLayerId[layerId]?.append(shape)
            }
        }

        // Build hierarchy: top layer (file name) with child layers per layer_id
        let fileName = url.deletingPathExtension().lastPathComponent
        let sortedLayerIds = shapesByLayerId.keys.sorted()

        var children: [VectorLayer] = []
        for layerId in sortedLayerIds {
            if let shapes = shapesByLayerId[layerId] {
                let childLayer = VectorLayer(name: layerId, shapes: shapes)
                children.append(childLayer)
            }
        }

        let topLayer = VectorLayer(name: fileName, children: children)

        var doc = NavigationDocument()
        doc.vectorLayers = [topLayer]
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

        // Build notes from altitude and raw text
        var notes = ""
        if let upperText = properties["upper_text"] as? String,
           let lowerText = properties["lower_text"] as? String {
            notes = "\(lowerText) – \(upperText)"
        }
        if let rawText = properties["raw_text"] as? String, !rawText.isEmpty {
            if !notes.isEmpty {
                notes.append("\n\n")
            }
            notes.append(rawText)
        }

        // Build style from color and opacity
        var style = VectorStyle()
        if let colorHex = properties["color"] as? String {
            style.strokeColor = colorHex
            style.fillColor = colorHex + opacityToHex(properties["opacity"] as? Double ?? 0.3)
        }
        style.strokeWidth = 1.5
        style.opacity = 1.0

        var vectorGeometry: VectorGeometry?

        switch type {
        case "Point":
            if let coords = geometryDict["coordinates"] as? [Double], coords.count == 2 {
                let lon = coords[0], lat = coords[1]
                // Check if we have a radius to make a circle
                if let radiusM = properties["radius_m"] as? Double {
                    vectorGeometry = .circle(lat: lat, lon: lon, radiusMeters: radiusM)
                } else {
                    vectorGeometry = .point(lat: lat, lon: lon)
                }
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

    private func opacityToHex(_ opacity: Double) -> String {
        let clipped = max(0.0, min(1.0, opacity))
        let alpha = Int(clipped * 255)
        return String(format: "%02X", alpha)
    }
}
