import Foundation

/// Export the app's own generic navigation format (.rut).
///
/// Uses JSONEncoder to ensure compatibility with RUTImportService's JSONDecoder.
struct RUTExportService: RouteExporting {
    let id = "rut"
    let displayName = "Rut .RUT"
    let supportedExtensions = ["rut"]
    
    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile] {
        
        // 1. Förbered dokumentet för export
        // Om användaren valt specifika rutter, exporterar vi bara dem.
        // Annars exporterar vi hela dokumentet.
        var docToExport = document
        
        if !selectedRoutes.isEmpty {
            docToExport.routes = selectedRoutes
        }
        
        // 2. Använd JSONEncoder istället för manuell ordbok.
        // Detta garanterar att nycklarna matchar modellerna i Models.swift (latitude vs lat etc).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // Snyggt och deterministiskt
        
        let data = try encoder.encode(docToExport)
        
        let filename = "backup.rut"
        return [ExportedFile(filename: filename, data: data)]
    }
}
