import Foundation

struct NAVImportService: RouteImporting {
    let supportedExtensions = ["nav"]
    
    func importDocument(from url: URL) throws -> NavigationDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        
        // Vi förväntar oss en array av UserNavaid: [UserNavaid]
        let navaids = try decoder.decode([UserNavaid].self, from: data)
        
        return NavigationDocument(
            createdAt: Date(),
            routes: [],
            userAirports: [],
            userNavaids: navaids,
            userWaypoints: [],
            systemAirports: [],
            systemNavaids: []
        )
    }
}
