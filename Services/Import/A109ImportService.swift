import Foundation
import CoreLocation

/// Importör för A109 P01 set.
struct A109ImportService: RouteImporting {
    
    let supportedExtensions = ["zip", "p01"]
    
    // --- NYTT: Context för att kunna slå upp rutt-punkter ---
    var existingAirports: [UserAirport] = []
    var existingNavaids: [UserNavaid] = []
    var existingWaypoints: [UserWaypoint] = []
    
    // Default init
    init() {}
    
    // Init med context (används av CoreServices vid rutt-import)
    init(existingAirports: [UserAirport], existingNavaids: [UserNavaid], existingWaypoints: [UserWaypoint]) {
        self.existingAirports = existingAirports
        self.existingNavaids = existingNavaids
        self.existingWaypoints = existingWaypoints
    }
    
    private enum A109FileType {
        case airport, navaid, waypoint, route, zip, unknown
    }
    
    func importDocument(from url: URL) throws -> NavigationDocument {
        // 1. Identifiera filtyp
        let fileType = try detectFileType(url: url)
        
        switch fileType {
        case .zip:
            return try importZipArchive(url)
            
        case .airport:
            let airports = try readAirports(url: url)
            return NavigationDocument(
                createdAt: Date(), routes: [],
                userAirports: airports, userNavaids: [], userWaypoints: []
            )
            
        case .navaid:
            let navaids = try readNavaids(url: url)
            return NavigationDocument(
                createdAt: Date(), routes: [],
                userAirports: [], userNavaids: navaids, userWaypoints: []
            )
            
        case .waypoint:
            let waypoints = try readWaypoints(url: url)
            return NavigationDocument(
                createdAt: Date(), routes: [],
                userAirports: [], userNavaids: [], userWaypoints: waypoints
            )
            
        case .route:
            // --- HÄR ÄR ÄNDRINGEN FÖR RUTTER ---
            // Vi använder de "existing"-listor vi fick i init() för att slå upp punkter.
            let routes = try readRoutes(
                url: url,
                airports: existingAirports,
                navaids: existingNavaids,
                waypoints: existingWaypoints
            )
            return NavigationDocument(
                createdAt: Date(),
                routes: routes, // Här kommer de inlästa rutterna
                userAirports: [], userNavaids: [], userWaypoints: []
            )
            
        case .unknown:
            throw RutError.invalidFormat("Could not identify A109 file type. File: \(url.lastPathComponent)")
        }
    }
    
    // MARK: - File Type Detection
    
    private func detectFileType(url: URL) throws -> A109FileType {
        let filename = url.lastPathComponent.uppercased()
        let ext = url.pathExtension.lowercased()
        
        if ext == "zip" { return .zip }
        
        // 1. Lita på filnamnet först
        if filename.contains("AIRPORT") { return .airport }
        if filename.contains("NAVAID") { return .navaid }
        if filename.contains("WAYPOINT") { return .waypoint }
        if filename.contains("ROUTE") { return .route }
        
        // 2. Fallback: Analysera storlek/innehåll
        let fileData = try Data(contentsOf: url)
        let totalSize = fileData.count
        if totalSize < 16 { return .unknown }
        let payloadSize = totalSize - 16
        if payloadSize == 0 { return .unknown }
        
        // Navaid har 0xE0 i första byte av record
        if payloadSize % 40 == 0 {
            if fileData.count > 16 && fileData[16] == 0xE0 { return .navaid }
            return .airport
        }
        if payloadSize % 28 == 0 { return .waypoint }
        if payloadSize % 500 == 0 { return .route }
        
        return .unknown
    }
    
    // MARK: - Import Logic (ZIP etc)
    
    private func importZipArchive(_ zipURL: URL) throws -> NavigationDocument {
        throw RutError.importFailed("ZIP import logic not implemented.")
    }
    
    private func readAirports(url: URL?) throws -> [UserAirport] {
            guard let url = url else { return [] }
            let data = try Data(contentsOf: url)
            guard data.count >= 16 else { return [] }
            
            var airports: [UserAirport] = []
            let recordSize = 40
            let startOffset = 16
            
            var i = 0
            while true {
                let offset = startOffset + (i * recordSize)
                if offset + recordSize > data.count { break }
                let record = data.subdata(in: offset..<offset+recordSize)
                i += 1
                
                // Byte 0-3: ID
                let idRaw = record.subdata(in: 0..<4)
                let id = A109SixBitEncoder.decodeString(idRaw).trimmingCharacters(in: .whitespaces)
                if id.isEmpty { continue }
                
                // Byte 4-11: Name
                let nameRaw = record.subdata(in: 4..<12)
                let name = A109SixBitEncoder.decodeString(nameRaw).trimmingCharacters(in: .whitespaces)
                
                // Byte 12-15: rawUnknown1
                let rawUnknown1 = record.subdata(in: 12..<16)
                
                // Byte 16-19: usage
                let usage = record.subdata(in: 16..<20)
                
                // Byte 20-23: Latitude (Float BE)
                let lat = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self) }))
                
                // Byte 24-27: Longitude (Float BE)
                let lon = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }))
                
                // Byte 28-31: longestRunway
                let longestRunway = record.subdata(in: 28..<32)
                
                // Byte 32-35: Magnetic Variation (Float BE)
                let magVar = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 32..<36).withUnsafeBytes { $0.load(as: UInt32.self) }))
                
                // Byte 36-39: Elevation (Float BE)
                let elev = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 36..<40).withUnsafeBytes { $0.load(as: UInt32.self) }))
                
                let ap = UserAirport(
                    id: id,
                    name: name,
                    latitude: Double(lat),
                    longitude: Double(lon),
                    elevation: Double(elev),
                    magneticVariation: Double(magVar), // Nu laddar vi in den korrekt!
                    
                    rawUnknown1: rawUnknown1,
                    usage: usage,
                    longestRunway: longestRunway
                )
                airports.append(ap)
            }
            return airports
        }
    
    private func readNavaids(url: URL?) throws -> [UserNavaid] {
        guard let url = url else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count >= 16 else { return [] }
        
        var navaids: [UserNavaid] = []
        let recordSize = 40
        let startOffset = 16
        var i = 0
        
        while true {
            let offset = startOffset + (i * recordSize)
            if offset + recordSize > data.count { break }
            let record = data.subdata(in: offset..<offset+recordSize)
            i += 1
            
            if record[0] != 0xE0 { continue }
            
            let idRaw = record.subdata(in: 4..<8)
            let id = A109SixBitEncoder.decodeString(idRaw).trimmingCharacters(in: .whitespaces)
            if id.isEmpty { continue }
            
            let nameRaw = record.subdata(in: 8..<16)
            let name = A109SixBitEncoder.decodeString(nameRaw).trimmingCharacters(in: .whitespaces)
            
            // Navaid specific structure
            let freq = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let lon = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let lat = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 28..<32).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let elev = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 36..<40).withUnsafeBytes { $0.load(as: UInt32.self) }))
            
            let nv = UserNavaid(id: id, name: name, latitude: Double(lat), longitude: Double(lon), elevation: Double(elev), magneticVariation: 0, frequency: Double(freq))
            navaids.append(nv)
        }
        return navaids
    }
    
    private func readWaypoints(url: URL?) throws -> [UserWaypoint] {
            guard let url = url else { return [] }
            let data = try Data(contentsOf: url)
            
            // Waypoint-filer har header (16) + records (28 bytes)
            if data.count < 16 { return [] }
            
            var waypoints: [UserWaypoint] = []
            let recordSize = 28
            let startOffset = 16
            
            var i = 0
            while true {
                let offset = startOffset + (i * recordSize)
                if offset + recordSize > data.count { break }
                
                let record = data.subdata(in: offset..<offset+recordSize)
                i += 1
                
                // Byte 24-27: ID (Special 6-bit)
                let idRaw = record.subdata(in: 24..<28)
                
                // CHECK: Om ID-bytes är 0, är posten tom. Hoppa över.
                // Vi kollar om alla 4 bytes är 0.
                if idRaw.allSatisfy({ $0 == 0 }) {
                    continue
                }
                
                var id = A109SixBitEncoder.decodeWaypointID(idRaw).trimmingCharacters(in: .whitespaces)
                
                // Fallback: Standard avkodning om specialformatet misslyckades (men bara om det fanns data)
                if id.isEmpty {
                    id = A109SixBitEncoder.decodeString(idRaw).trimmingCharacters(in: .whitespaces)
                }
                
                // Om ID fortfarande är tomt efter avkodning -> Hoppa över (Skapa INTE "UNK"!)
                if id.isEmpty {
                    continue
                }
                
                // Byte 0-3: Lat - Changed var to let
                let lat = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }))
                
                // Byte 4-7: Lon - Changed var to let
                let lon = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }))
                
                // Säkerställ att vi inte kastar bort 0,0-punkter om de har ett giltigt ID,
                // men "nudga" dem för MapKit om det behövs (detta görs i display-lagret, men vi kan säkra upp här också om du vill)
                if lat == 0.0 && lon == 0.0 {
                    // Vi behåller dem som 0.0 här. MapView sköter visualiseringen.
                }
                
                // Byte 8-19: Name
                let nameRaw = record.subdata(in: 8..<20)
                let name = A109SixBitEncoder.decodeString(nameRaw).trimmingCharacters(in: .whitespaces)
                
                let wp = UserWaypoint(
                    id: id,
                    name: name.isEmpty ? id : name,
                    type: .wpt,
                    latitude: Double(lat),
                    longitude: Double(lon),
                    elevation: 0
                )
                waypoints.append(wp)
            }
            return waypoints
        }
    
    private func readRoutes(url: URL?,
                            airports: [UserAirport],
                            navaids: [UserNavaid],
                            waypoints: [UserWaypoint]) throws -> [Route] {
        guard let url = url else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count >= 16 else { return [] }
        
        var routes: [Route] = []
        let recordSize = 500
        let startOffset = 16
        var i = 0
        
        while true {
            let offset = startOffset + (i * recordSize)
            if offset + recordSize > data.count { break }
            let record = data.subdata(in: offset..<offset+recordSize)
            i += 1
            
            if record[0] == 0 { continue }
            
            let nameRaw = record.subdata(in: 0..<8)
            let name = A109SixBitEncoder.decodeString(nameRaw).trimmingCharacters(in: .whitespaces)
            
            let b17 = Int(record[17])
            let b18 = Int(record[18])
            let ptCount = (b17 * 8) + (b18 >> 5)
            let safeCount = min(ptCount, 40)
            
            var points: [RoutePointRef] = []
            var ptOffset = 20
            
            for _ in 0..<safeCount {
                let ptRec = record.subdata(in: ptOffset..<ptOffset+12)
                let idxByte = ptRec[0]
                let typeByte = ptRec[11] // Byte 11 determines type
                
                if typeByte == 0x8C { break } // Terminator
                
                // Row_Nr = (Byte0 / 2) - 1
                let recIndex = (Int(idxByte) / 2) - 1
                
                if idxByte == 0 {
                    // Custom Point (Byte0 == 0)
                    // TODO: Custom points saknar ofta koordinater i ruttfilen, hanterar dem som namn-referens
                    let ptNameRaw = ptRec.subdata(in: 4..<8)
                    // Removed unused 'ptName' assignment
                    _ = A109SixBitEncoder.decodeString(ptNameRaw).trimmingCharacters(in: .whitespaces)
                    
                    // Vi lägger till den, men den kommer antagligen inte synas på kartan om vi inte skapar en fake-waypoint
                    // points.append(RoutePointRef(kind: .userWaypoint, refId: ptName))
                } else {
                    // Database Point Lookup
                    if typeByte == 0x5C { // AIRPORT
                        if recIndex >= 0 && recIndex < airports.count {
                            points.append(RoutePointRef(kind: .userAirport, refId: airports[recIndex].id))
                        }
                    } else if typeByte == 0x7C { // NAVAID
                        if recIndex >= 0 && recIndex < navaids.count {
                            points.append(RoutePointRef(kind: .userNavaid, refId: navaids[recIndex].id))
                        }
                    } else if typeByte == 0x6C { // WAYPOINT
                        if recIndex >= 0 && recIndex < waypoints.count {
                            points.append(RoutePointRef(kind: .userWaypoint, refId: waypoints[recIndex].id))
                        }
                    }
                }
                ptOffset += 12
            }
            
            // Skapa bara rutt om den har punkter
            if !points.isEmpty {
                let r = Route(
                    routeId: "R\(i)-\(UUID().uuidString.prefix(4))",
                    name: name,
                    pointRefs: points
                )
                routes.append(r)
            }
        }
        return routes
    }
}
// MARK: - Decoder Helper

extension A109SixBitEncoder {
    
    static func decodeString(_ data: Data) -> String {
        // Tabell för 6-bit avkodning
        let codeToChar: [UInt8: Character] = [
            11: "-", 14: "0", 15: "1", 16: "2", 17: "3", 18: "4",
            19: "5", 20: "6", 21: "7", 22: "8", 23: "9",
            30: "A", 31: "B", 32: "C", 33: "D", 34: "E", 35: "F",
            36: "G", 37: "H", 38: "I", 39: "J", 40: "K", 41: "L",
            42: "M", 43: "N", 44: "O", 45: "P", 46: "Q", 47: "R",
            48: "S", 49: "T", 50: "U", 51: "V", 52: "W", 53: "X",
            54: "Y", 55: "Z"
        ]
        
        var result = ""
        var i = 0
        // Vi läser 4 bytes (32 bitar) i taget
        while i + 4 <= data.count {
            let val32 = UInt32(bigEndian: data.subdata(in: i..<i+4).withUnsafeBytes { $0.load(as: UInt32.self) })
            
            // Varje tecken är 6 bitar. I en 32-bitars chunk ligger de shiftade:
            // Char 1: >> 26
            // Char 2: >> 20
            // Char 3: >> 14
            // Char 4: >> 8
            // Char 5: >> 2
            // De sista 2 bitarna är padding/oanvända.
            
            let shifts = [26, 20, 14, 8, 2]
            for s in shifts {
                let code = UInt8((val32 >> s) & 0x3F)
                if code == 0 { return result } // Null terminator
                if let ch = codeToChar[code] {
                    result.append(ch)
                } else {
                    // Unknown char or space (code 0x20 usually space in ASCII but here mapping differs)
                    // If logic requires space handling:
                    if code == 32 { result.append(" ") } // Just in case, though 32 is 'C' in your map
                    else { result.append(" ") } // Fallback
                }
            }
            i += 4
        }
        return result
    }
    
    static func decodeWaypointID(_ data: Data) -> String {
        // ID använder specialformatet: (val32 >> 1) | 0x80000000 vid encoding.
        // För decoding reverserar vi det.
        
        // 1. Läs 32-bitars värdet
        let val32 = UInt32(bigEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) })
        
        // 2. Ta bort MSB (som sattes vid encoding)
        let raw = val32 & 0x7FFFFFFF
        
        // 3. Skifta tillbaka vänster 1 steg för att återställa originalbitarna
        let restored = raw << 1
        
        // 4. Gör om till Data (4 bytes) för att använda decodeString
        var temp = Data(count: 4)
        temp[0] = UInt8((restored >> 24) & 0xFF)
        temp[1] = UInt8((restored >> 16) & 0xFF)
        temp[2] = UInt8((restored >> 8) & 0xFF)
        temp[3] = UInt8(restored & 0xFF)
        
        return decodeString(temp)
    }
}
