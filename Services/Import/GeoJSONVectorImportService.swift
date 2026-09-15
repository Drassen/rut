import Foundation

struct GeoJSONVectorImportService: RouteImporting {
    let supportedExtensions = ["geojson", "json"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        try importDocumentWithWarnings(from: url).0
    }

    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String]) {
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
        var warnings: [String] = []

        for (index, feature) in features.enumerated() {
            if let shape = parseFeature(feature, index: index, warnings: &warnings) {
                shapes.append(shape)
            }
        }

        let layer = VectorLayer(name: layerName, shapes: shapes)
        var doc = NavigationDocument()
        doc.vectorLayers = [layer]
        return (doc, warnings)
    }

    private func parseFeature(_ feature: [String: Any], index: Int, warnings: inout [String]) -> VectorShape? {
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

        let label = "Feature \(index + 1) '\(name)'"
        guard let geom = GeoJSONGeometryReader.read(feature["geometry"], label: label, warnings: &warnings) else {
            return nil
        }
        return VectorShape(name: name, notes: notes, geometry: geom, style: style)
    }
}
