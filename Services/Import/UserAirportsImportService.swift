import Foundation

// MARK: - APT Services (User Airports)


struct APTImportService: RouteImporting {
    let supportedExtensions = ["apt"]
    
    func importDocument(from url: URL) throws -> NavigationDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        
        // Vi förväntar oss en array av UserAirport: [UserAirport]
        let airports = try decoder.decode([UserAirport].self, from: data)
        
        // Returnera ett dokument med BARA airports
        return NavigationDocument(
            createdAt: Date(),
            routes: [],
            userAirports: airports,
            userNavaids: [],
            userWaypoints: [],
            systemAirports: [],
            systemNavaids: []
        )
    }
}
