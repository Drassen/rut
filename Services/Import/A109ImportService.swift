import Foundation
import CoreLocation

/// Importör för A109 P01 set.
/// Self-contained: a card's files become generic navigation data without consulting the app's
/// database. Route points refer to record numbers in the card's own point files, so a card is
/// read as a whole; a ROUTE.P01 imported on its own falls back to the point IDs in the route.
struct A109ImportService: RouteImporting {
    
    let supportedExtensions = ["zip", "p01"]
    
    private enum A109FileType: String {
        case airport = "AIRPORT.P01", navaid = "NAVAID.P01", waypoint = "WAYPOINT.P01", route = "ROUTE.P01"
        case zip, unknown
    }

    /// Card files that are not navigation data (header, checksums, planning computer logs).
    static let cardSupportFiles: Set<String> = [
        "CARACTER.P01", "PILOTE.HD", "PILOTLOG.TXT", "PILOTREADLOG.TXT", "TACTICALREADLOG.TXT", "ICON",
    ]
    
    func importDocument(from url: URL) throws -> NavigationDocument {
        try importDocumentWithWarnings(from: url).0
    }

    /// One P01 file on its own.
    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String]) {
        try importCardWithWarnings(files: [url])
    }

    /// The P01 files of one card, read together. Records that cannot be read, and route points
    /// that cannot be resolved, are reported with the reason. Empty slots are not reported.
    func importCardWithWarnings(files: [URL]) throws -> (NavigationDocument, [String]) {
        var warnings: [String] = []
        var filesByType: [A109FileType: URL] = [:]

        for url in files {
            let fileType = try detectFileType(url: url)
            switch fileType {
            case .zip:
                return (try importZipArchive(url), [])
            case .unknown:
                throw RutError.invalidFormat("Could not identify A109 file type. File: \(url.lastPathComponent)")
            default:
                if let existing = filesByType[fileType] {
                    warnings.append("\(url.lastPathComponent) ignored: \(existing.lastPathComponent) is already the card's \(fileType.rawValue)")
                } else {
                    filesByType[fileType] = url
                }
            }
        }

        // Point files first: route record numbers refer to them
        // The slot tables hold the ID per record number, empty slots included
        var airportSlots: [String?] = [], navaidSlots: [String?] = [], waypointSlots: [String?] = []
        let airports = try filesByType[.airport].map { try readAirports(url: $0, slotIDs: &airportSlots, warnings: &warnings) }
        let navaids = try filesByType[.navaid].map { try readNavaids(url: $0, slotIDs: &navaidSlots, warnings: &warnings) }
        let waypoints = try filesByType[.waypoint].map { try readWaypoints(url: $0, slotIDs: &waypointSlots, warnings: &warnings) }
        let routes = try filesByType[.route].map {
            try readRoutes(url: $0,
                           airportSlots: airports == nil ? nil : airportSlots,
                           navaidSlots: navaids == nil ? nil : navaidSlots,
                           waypointSlots: waypoints == nil ? nil : waypointSlots,
                           warnings: &warnings)
        } ?? []

        return (NavigationDocument(
            createdAt: Date(),
            routes: routes,
            userAirports: airports ?? [],
            userNavaids: navaids ?? [],
            userWaypoints: waypoints ?? []
        ), warnings)
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

    /// The file is too short to hold the 16-byte header.
    private static let shortFileWarning = "File is shorter than its 16-byte header; nothing was read"

    private func readAirports(url: URL?, slotIDs: inout [String?], warnings: inout [String]) throws -> [UserAirport] {
            guard let url = url else { return [] }
            let data = try Data(contentsOf: url)
            guard data.count >= 16 else {
                warnings.append(Self.shortFileWarning)
                return []
            }

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
                if id.isEmpty {
                    // An all-zero record is an empty slot; anything else is unreadable data
                    if record.contains(where: { $0 != 0 }) {
                        warnings.append("Airport record \(i): no readable ID; skipped")
                    }
                    slotIDs.append(nil)
                    continue
                }

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
                slotIDs.append(id)
            }
            return airports
        }

    private func readNavaids(url: URL?, slotIDs: inout [String?], warnings: inout [String]) throws -> [UserNavaid] {
        guard let url = url else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count >= 16 else {
            warnings.append(Self.shortFileWarning)
            return []
        }

        var navaids: [UserNavaid] = []
        let recordSize = 40
        let startOffset = 16
        var i = 0

        while true {
            let offset = startOffset + (i * recordSize)
            if offset + recordSize > data.count { break }
            let record = data.subdata(in: offset..<offset+recordSize)
            i += 1

            // An all-zero record is an empty slot. Byte 0 is not always 0xE0: older DAP cards
            // write 0xA8, and the planning computer reads those navaids (T07-T09)
            if !record.contains(where: { $0 != 0 }) {
                slotIDs.append(nil)
                continue
            }

            let idRaw = record.subdata(in: 4..<8)
            let id = A109SixBitEncoder.decodeString(idRaw).trimmingCharacters(in: .whitespaces)
            if id.isEmpty {
                warnings.append("Navaid record \(i): no readable ID; skipped")
                slotIDs.append(nil)
                continue
            }

            let nameRaw = record.subdata(in: 8..<16)
            let name = A109SixBitEncoder.decodeString(nameRaw).trimmingCharacters(in: .whitespaces)

            // Navaid specific structure
            let freq = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let lon = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let lat = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 28..<32).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let elev = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 36..<40).withUnsafeBytes { $0.load(as: UInt32.self) }))

            let nv = UserNavaid(id: id, name: name, latitude: Double(lat), longitude: Double(lon), elevation: Double(elev), magneticVariation: 0, frequency: Double(freq))
            navaids.append(nv)
            slotIDs.append(id)
        }
        return navaids
    }

    private func readWaypoints(url: URL?, slotIDs: inout [String?], warnings: inout [String]) throws -> [UserWaypoint] {
            guard let url = url else { return [] }
            let data = try Data(contentsOf: url)

            // Waypoint-filer har header (16) + records (28 bytes)
            if data.count < 16 {
                warnings.append(Self.shortFileWarning)
                return []
            }

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
                // An all-zero record is an empty slot; data without an ID is reported.
                if idRaw.allSatisfy({ $0 == 0 }) {
                    if record.contains(where: { $0 != 0 }) {
                        warnings.append("Waypoint record \(i): empty ID; skipped")
                    }
                    slotIDs.append(nil)
                    continue
                }

                var id = A109SixBitEncoder.decodeWaypointID(idRaw).trimmingCharacters(in: .whitespaces)

                // Fallback: Standard avkodning om specialformatet misslyckades (men bara om det fanns data)
                if id.isEmpty {
                    id = A109SixBitEncoder.decodeString(idRaw).trimmingCharacters(in: .whitespaces)
                }

                // Om ID fortfarande är tomt efter avkodning -> Hoppa över (Skapa INTE "UNK"!)
                if id.isEmpty {
                    warnings.append("Waypoint record \(i): ID could not be decoded; skipped")
                    slotIDs.append(nil)
                    continue
                }

                // Byte 0-3: Lat
                let lat = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }))

                // Byte 4-7: Lon
                let lon = Float32(bitPattern: UInt32(bigEndian: record.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }))

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
                slotIDs.append(id)
            }
            return waypoints
        }

    private func readRoutes(url: URL?,
                            airportSlots: [String?]?,
                            navaidSlots: [String?]?,
                            waypointSlots: [String?]?,
                            warnings: inout [String]) throws -> [Route] {
        guard let url = url else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count >= 16 else {
            warnings.append(Self.shortFileWarning)
            return []
        }
        
        var routes: [Route] = []
        let recordSize = 500
        let startOffset = 16
        var i = 0
        // Points matched by ID because the card's point file was not part of the import
        var matchedByID: [A109FileType: Int] = [:]
        
        while true {
            let offset = startOffset + (i * recordSize)
            if offset + recordSize > data.count { break }
            let record = data.subdata(in: offset..<offset+recordSize)
            i += 1
            
            let b17 = Int(record[17])
            let b18 = Int(record[18])
            let ptCount = (b17 * 8) + (b18 >> 5)

            if record[0] == 0 {
                // An empty slot has no name and no points (status byte 0x48); a slot with
                // points but no name is unreadable data
                if ptCount > 0 {
                    warnings.append("Route record \(i): \(ptCount) point(s) but no name; skipped")
                }
                continue
            }
            
            let nameRaw = record.subdata(in: 0..<8)
            let name = A109SixBitEncoder.decodeString(nameRaw).trimmingCharacters(in: .whitespaces)
            let label = "Route '\(name)'"
            
            let safeCount = min(ptCount, 40)
            if ptCount > 40 {
                warnings.append("\(label): \(ptCount) points stated, only the first 40 were read")
            }
            
            var points: [RoutePointRef] = []
            var ptOffset = 20
            
            for pointNumber in 1...max(safeCount, 1) where safeCount > 0 {
                let ptRec = record.subdata(in: ptOffset..<ptOffset+12)
                ptOffset += 12
                let idxByte = ptRec[0]
                let typeByte = ptRec[11] // Byte 11 determines type
                
                if typeByte == 0x8C { break } // Terminator

                // The point's ID as written in the route (bytes 4-7)
                let idField = A109SixBitEncoder.decodeString(ptRec.subdata(in: 4..<8)).trimmingCharacters(in: .whitespaces)
                let where_ = "\(label) point \(pointNumber)"

                guard idxByte != 0 else {
                    // No record in the card's files: a point in the helicopter's internal (Jeppesen)
                    // database, referenced by ID. Skyflight writes airports as 0x0C, the app as 0x5C/0x7C.
                    let systemKind: RoutePointKind?
                    switch typeByte {
                    case 0x0C, 0x5C: systemKind = .systemAirport
                    case 0x7C:       systemKind = .systemNavaid
                    default:         systemKind = nil
                    }
                    if let systemKind, !idField.isEmpty {
                        points.append(RoutePointRef(kind: systemKind, refId: idField))
                    } else {
                        warnings.append("\(where_): point '\(idField)' (type 0x\(String(format: "%02X", typeByte))) refers to the helicopter's internal database, which has no such point type; skipped")
                    }
                    continue
                }

                let fileType: A109FileType
                let kind: RoutePointKind
                let recordIDs: [String?]?
                switch typeByte {
                case 0x5C: fileType = .airport;  kind = .userAirport;  recordIDs = airportSlots
                case 0x7C: fileType = .navaid;   kind = .userNavaid;   recordIDs = navaidSlots
                case 0x6C: fileType = .waypoint; kind = .userWaypoint; recordIDs = waypointSlots
                default:
                    warnings.append("\(where_): unknown point type 0x\(String(format: "%02X", typeByte)); skipped")
                    continue
                }
                let kindName = String(describing: fileType)
                
                // Row_Nr = (Byte0 / 2) - 1
                let recIndex = (Int(idxByte) / 2) - 1

                if let recordIDs {
                    if recIndex >= 0, recIndex < recordIDs.count, let recordID = recordIDs[recIndex] {
                        // The record number is the route's reference; the ID field is only checked
                        points.append(RoutePointRef(kind: kind, refId: recordID))
                        if !idField.isEmpty && idField != recordID {
                            warnings.append("\(where_): \(kindName) record #\(recIndex + 1) is '\(recordID)' but the route names '\(idField)'; the record number is used")
                        }
                    } else if !idField.isEmpty {
                        points.append(RoutePointRef(kind: kind, refId: idField))
                        warnings.append("\(where_): \(kindName) record #\(recIndex + 1) is empty or missing in \(fileType.rawValue); matched by ID '\(idField)' instead")
                    } else {
                        warnings.append("\(where_): \(kindName) record #\(recIndex + 1) is empty or missing in \(fileType.rawValue) and the route gives no ID; skipped")
                    }
                } else if !idField.isEmpty {
                    // The card's point file is not part of the import: record numbers cannot be read
                    points.append(RoutePointRef(kind: kind, refId: idField))
                    matchedByID[fileType, default: 0] += 1
                } else {
                    warnings.append("\(where_): \(fileType.rawValue) is not part of the import and the route gives no ID; skipped")
                }
            }
            
            // Skapa bara rutt om den har punkter
            if !points.isEmpty {
                let r = Route(
                    routeId: "R\(i)-\(UUID().uuidString.prefix(4))",
                    name: name,
                    pointRefs: points
                )
                routes.append(r)
            } else if safeCount == 0 {
                warnings.append("\(label): has no fix points (only start/destination airport); not imported")
            } else {
                warnings.append("\(label): no readable points; not imported")
            }
        }

        for fileType in [A109FileType.airport, .navaid, .waypoint] {
            if let count = matchedByID[fileType] {
                warnings.append("\(count) route point(s) matched by ID: \(fileType.rawValue) was not part of the import, so record numbers could not be used. Import all files of the card, or its folder, to read the routes exactly.")
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
