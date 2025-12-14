import Foundation

// MARK: - APT Services (User Airports)

struct APTExportService: RouteExporting {
    let id = "apt"
    let displayName = "Rut User Airports (.APT)"
    let supportedExtensions = ["apt"]
    
    func export(document: NavigationDocument, selectedRoutes: [Route]) throws -> [ExportedFile] {
        // Vi exporterar ALLA user airports, oavsett vald rutt, eftersom detta är en DB-export
        let airports = document.userAirports
        guard !airports.isEmpty else { return [] }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(airports)
        return [ExportedFile(filename: "UserAirports.apt", data: data)]
    }
}
