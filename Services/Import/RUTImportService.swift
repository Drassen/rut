import Foundation

/// Import of the app's own generic format (.rut).
/// Since JSON arrays are ordered, this preserves the export order exactly.
struct RUTImportService: RouteImporting {
    let supportedExtensions = ["rut"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        if url.pathExtension.lowercased() == "zip" {
            throw RutError.zipNotSupported
        }
        
        // Data(contentsOf: ...) läser filen sekventiellt -> datan hamnar i minnet
        let data = try Data(contentsOf: url)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        do {
            // JSONDecoder läser arrayer i den ordning de ligger i filen.
            // Resultatet blir en NavigationDocument med arrayer i exakt samma ordning som exporten.
            let doc = try decoder.decode(NavigationDocument.self, from: data)
            return doc
        } catch {
            throw RutError.importFailed("Failed to decode .RUT file: \(error)")
        }
    }
}
