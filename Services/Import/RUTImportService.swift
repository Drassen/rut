import Foundation

/// Import of the app's own generic format (.rut).
/// For simplicity this is just JSON encoded NavigationDocument.
struct RUTImportService: RouteImporting {
    let supportedExtensions = ["rut"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        if url.pathExtension.lowercased() == "zip" {
            throw RutError.zipNotSupported
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let doc = try decoder.decode(NavigationDocument.self, from: data)
            return doc
        } catch {
            throw RutError.importFailed("Failed to decode .RUT file: \(error)")
        }
    }
}
