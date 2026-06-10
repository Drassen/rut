import Foundation

/// `.rutvector` — Rut's own lossless vector format.
///
/// Stores the raw `VectorLayer` tree (Codable) in a JSON envelope, so
/// everything round-trips exactly: layer hierarchy, shape ids, names,
/// notes, geometry, full style, visibility and the Euronav5 export
/// properties. Counterpart: `RutVectorImportService`.
struct RutVectorDocument: Codable {
    static let formatName = "rutvector"
    static let currentVersion = 1

    var format: String = RutVectorDocument.formatName
    var version: Int = RutVectorDocument.currentVersion
    var exported: Date = Date()
    var layers: [VectorLayer]
}

struct RutVectorExportService: RouteExporting {
    let id = "rutvector"
    let displayName = "Rut Vector (.rutvector)"
    let supportedExtensions = ["rutvector"]

    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile] {
        let exportLayers = document.vectorLayers.filter { !$0.isSystem }
        guard !exportLayers.isEmpty else {
            throw RutError.invalidFormat("No vector layers to export")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(RutVectorDocument(layers: exportLayers))
        return [ExportedFile(filename: "VectorLayers.rutvector", data: data)]
    }
}
