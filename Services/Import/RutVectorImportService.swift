import Foundation

/// Imports `.rutvector` files — Rut's own lossless vector format.
/// See `RutVectorExportService` for the format definition.
struct RutVectorImportService: RouteImporting {
    let supportedExtensions = ["rutvector"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        guard let data = try? Data(contentsOf: url) else {
            throw RutError.importFailed("Could not read .rutvector file.")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let file = try? decoder.decode(RutVectorDocument.self, from: data),
              file.format == RutVectorDocument.formatName else {
            throw RutError.importFailed("Invalid .rutvector file.")
        }
        guard file.version <= RutVectorDocument.currentVersion else {
            throw RutError.importFailed(
                ".rutvector version \(file.version) is newer than this app supports.")
        }

        // System layers (e.g. LFV airspace) are app-managed; anything imported
        // from a file must be a normal user layer or the store would hide it.
        var doc = NavigationDocument()
        doc.vectorLayers = file.layers.map(clearSystemFlag)
        return doc
    }

    private func clearSystemFlag(_ layer: VectorLayer) -> VectorLayer {
        var l = layer
        l.isSystem = false
        l.children = l.children.map(clearSystemFlag)
        return l
    }
}
