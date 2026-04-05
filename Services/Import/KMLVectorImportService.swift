import Foundation

// Imports a KML file directly as VectorLayers (instead of nav data).
// Uses the same KMLVectorParser as KMZImportService.

struct KMLVectorImportService: RouteImporting {
    let supportedExtensions = ["kml"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        guard let data = try? Data(contentsOf: url) else {
            throw RutError.importFailed("Could not read KML file.")
        }
        let defaultName = url.deletingPathExtension().lastPathComponent
        let layers = try KMLVectorParser.parse(kmlData: data, defaultLayerName: defaultName)
        var doc = NavigationDocument()
        doc.vectorLayers = layers
        return doc
    }
}
