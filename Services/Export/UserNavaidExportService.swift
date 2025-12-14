import Foundation

// MARK: - NAV Services (User Navaids)

struct NAVExportService: RouteExporting {
    let id = "nav"
    let displayName = "Rut User Navaids (.NAV)"
    let supportedExtensions = ["nav"]
    
    func export(document: NavigationDocument, selectedRoutes: [Route]) throws -> [ExportedFile] {
        let navaids = document.userNavaids
        guard !navaids.isEmpty else { return [] }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(navaids)
        return [ExportedFile(filename: "UserNavaids.nav", data: data)]
    }
}
