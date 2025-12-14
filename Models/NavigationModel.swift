import Foundation
import CoreLocation

// MARK: - Enums

enum WaypointType: String, Codable, CaseIterable {
    case custom = "CUSTOM" // Default / Visas som liten prick
    case wpt  = "WPT"  // Waypoint (Cirkel)
    case ip   = "IP"   // Initial Point (Fyrkant)
    case tgt  = "TGT"  // Target (Triangel)
    case hld  = "HLD"  // Holding (Cirkel)
    case cli  = "CLI"  // Climb Point (Upp-pil)
    case des  = "DES"  // Descent Point (Ner-pil)
}

enum RoutePointKind: String, Codable {
    case userAirport
    case userNavaid
    case userWaypoint
    // Nya typer för Jeppesen/System-data
    case systemAirport
    case systemNavaid
}

// MARK: - Route structs

struct RoutePointRef: Identifiable, Codable {
    var id = UUID()
    var kind: RoutePointKind
    var refId: String // ID på punkten i databasen (t.ex. "ESSA", "WPT01")
}

struct Route: Identifiable, Codable {
    var id = UUID()
    var routeId: String // Internt ID för A109 (max 15 tecken, unikt)
    var name: String
    var pointRefs: [RoutePointRef]
}

struct RouteMapPoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let name: String
    let indexInRoute: Int
    let kind: RoutePointKind
}

// MARK: - User Databases (Redigerbara, Exporteras till P01)

struct UserAirport: Identifiable, Codable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var elevation: Double
    var magneticVariation: Double
    
    // A109 Bevarande-data
    var rawUnknown1: Data = Data()
    var usage: Data = Data()
    var longestRunway: Data = Data()
    
    // Helper för MapKit
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension UserAirport {
    // Kompatibilitets-init
    init(id: String, name: String, latitude: Double, longitude: Double, elevation: Double, magneticVariation: Double = 0) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.magneticVariation = magneticVariation
    }
}

struct UserNavaid: Identifiable, Codable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var elevation: Double
    var magneticVariation: Double
    var frequency: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct UserWaypoint: Identifiable, Codable {
    var id: String
    var name: String
    var type: WaypointType
    var latitude: Double
    var longitude: Double
    var elevation: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - System/Jeppesen Databases (Read-only referenser, Exporteras INTE till P01)

struct JepAirport: Identifiable, Codable {
    var id: String      // T.ex. "ESSA"
    var latitude: Double
    var longitude: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct JepNavaid: Identifiable, Codable {
    var id: String      // T.ex. "SVD"
    var latitude: Double
    var longitude: Double
    var type: String    // "VOR", "NDB"
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Document

struct NavigationDocument: Codable {
    var createdAt: Date = Date()
    var routes: [Route] = []
    
    // User Data (Redigerbart, Exporteras)
    var userAirports: [UserAirport] = []
    var userNavaids: [UserNavaid] = []
    var userWaypoints: [UserWaypoint] = []
    
    // System Data (Read-only, Refereras, Exporteras EJ i DB-filer)
    var systemAirports: [JepAirport] = []
    var systemNavaids: [JepNavaid] = []
}
