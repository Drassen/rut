import Foundation

struct SAPIImportService: RouteImporting {
    let supportedExtensions = ["sapi"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        try importDocumentWithWarnings(from: url).0
    }

    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String]) {
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
        var warnings: [String] = []

        for (index, feature) in features.enumerated() {
            if let shape = parseFeature(feature, index: index, warnings: &warnings) {
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
        return (doc, warnings)
    }

    private func parseFeature(_ feature: [String: Any], index: Int, warnings: inout [String]) -> VectorShape? {
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

        // A Point with radius_m is a circle
        let label = "Feature \(index + 1) '\(name)'"
        guard let geom = GeoJSONGeometryReader.read(feature["geometry"], label: label,
                                                    pointRadiusM: properties["radius_m"] as? Double,
                                                    warnings: &warnings) else {
            return nil
        }
        return VectorShape(name: name, notes: notes, geometry: geom, style: style)
    }

    private func opacityToHex(_ opacity: Double) -> String {
        let clipped = max(0.0, min(1.0, opacity))
        let alpha = Int(clipped * 255)
        return String(format: "%02X", alpha)
    }
}
