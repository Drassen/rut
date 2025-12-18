import Foundation

// MARK: - Data Models

/// Full A109 file set for one export operation.
struct A109FileSet {
    let piloteHD: Data
    let airportP01: Data
    let navaidP01: Data
    let waypointP01: Data
    let routeP01: Data
    let caracterP01: Data
}

// MARK: - Export Service

struct A109PCMCIAExportService: RouteExporting {
    
    // Protocol requirements
    let id = "A109 PCMCIA"
    let displayName = "A109 PCMCIA"
    let supportedExtensions = ["zip"]
    
    // Max records according to the A109 limits
    private static let maxAirports = 100
    private static let maxNavaids  = 100
    private static let maxWaypoints = 100
    private static let maxRoutes   = 100
    
    /// Main entry point
    func export(document: NavigationDocument, selectedRoutes: [Route]) throws -> [ExportedFile] {
        
        let fileSet = A109PCMCIAExportService.generateFileSet(document: document)
        
        return [
            ExportedFile(filename: "PILOTE.HD", data: fileSet.piloteHD),
            ExportedFile(filename: "AIRPORT.P01", data: fileSet.airportP01),
            ExportedFile(filename: "NAVAID.P01", data: fileSet.navaidP01),
            ExportedFile(filename: "WAYPOINT.P01", data: fileSet.waypointP01),
            ExportedFile(filename: "ROUTE.P01", data: fileSet.routeP01),
            ExportedFile(filename: "CARACTER.P01", data: fileSet.caracterP01)
        ]
    }
    
    // Intern logik
    static func generateFileSet(document: NavigationDocument, date: Date = Date()) -> A109FileSet {
        
        
        // --- DEBUG: Tvinga datum
        //let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2025, month: 11, day: 07)) ?? date
        
        // 1. Clamp to A109 limits
        let airports = Array(document.userAirports.prefix(maxAirports))
        let navaids  = Array(document.userNavaids.prefix(maxNavaids))
        let waypoints = Array(document.userWaypoints.prefix(maxWaypoints))
        let routes   = Array(document.routes.prefix(maxRoutes))
        
        // 2. Calculate helpers
        let airportUsage = usageCountsForAirports(routes: routes)
        let navaidUsage  = usageCountsForNavaids(routes: routes)
        let waypointRouteMembership = waypointRouteMembershipMap(waypoints: waypoints, routes: routes)
        
        // 3. Build individual P01 files
        let airportP01 = makeAirportFile(
            airports: airports,
            usage: airportUsage
        )
        
        let navaidP01 = makeNavaidFile(
            navaids: navaids,
            usage: navaidUsage
        )
        
        let waypointP01 = makeWaypointFile(
            waypoints: waypoints,
            routeMembership: waypointRouteMembership
        )
        
        let routeP01 = makeRouteFile(
            routes: routes,
            userAirports: airports,
            userNavaids: navaids,
            userWaypoints: waypoints
        )
        
        let caracterP01 = makeCaracterFile(
            date: date,
            waypointFile: waypointP01,
            airportFile: airportP01,
            navaidFile: navaidP01,
            routeFile: routeP01
        )
        
        let piloteHD = makePiloteFile(
            date: date,
            airportSize: airportP01.count,
            navaidSize: navaidP01.count,
            waypointSize: waypointP01.count,
            routeSize: routeP01.count,
            caracterSize: caracterP01.count
        )
        
        return A109FileSet(
            piloteHD: piloteHD,
            airportP01: airportP01,
            navaidP01: navaidP01,
            waypointP01: waypointP01,
            routeP01: routeP01,
            caracterP01: caracterP01
        )
    }
}

// MARK: - File Generators (Private Extensions)

private extension A109PCMCIAExportService {
    
    // MARK: AIRPORT.P01
    static func makeAirportFile(airports: [UserAirport], usage: [String: Int]) -> Data {
        var data = Data()
        let count = min(airports.count, maxAirports)
        
        var header = makePresenceHeader(count: count)
        let byte13 = (count == 100) ? 128 : (129 + count)
        header.append(UInt8(byte13))
        header.append(UInt8(count * 2))
        header.append(0x00)
        data.append(contentsOf: header)
        
        for i in 0..<maxAirports {
            var record = [UInt8](repeating: 0, count: 40)
            
            if i < count {
                let ap = airports[i]
                
                // ID (Byte 0-3)
                let idBytes = A109SixBitEncoder.encodeString(ap.id, maxChars: 5, totalBytes: 4)
                record[0..<4] = idBytes[0..<4]
                
                // Namn (Byte 4-11)
                let nameBytes = A109SixBitEncoder.encodeString(ap.name, maxChars: 10, totalBytes: 8)
                record[4..<12] = nameBytes[0..<8]
                
                // Byte 12-15: rawUnknown1 (Bevarad data)
                if ap.rawUnknown1.count == 4 {
                    record[12..<16] = Array(ap.rawUnknown1)[0..<4]
                }
                
                // Byte 16-19: Usage
                if ap.usage.count == 4 {
                    record[16..<20] = Array(ap.usage)[0..<4]
                } else {
                    let u = usage[ap.id] ?? 0
                    record[17] = (u == 0) ? 6 : (u == 1 ? 14 : 30)
                }
                
                // Koordinater (Byte 20-27)
                record[20..<24] = float32BigEndian(Float(ap.latitude))[0..<4]
                record[24..<28] = float32BigEndian(Float(ap.longitude))[0..<4]
                
                // Byte 28-31: Longest Runway
                if ap.longestRunway.count == 4 {
                    record[28..<32] = Array(ap.longestRunway)[0..<4]
                }
                
                // Byte 32-35: Magnetic Variation
                record[32..<36] = float32BigEndian(Float(ap.magneticVariation))[0..<4]
                
                // Byte 36-39: Elevation
                record[36..<40] = float32BigEndian(Float(ap.elevation))[0..<4]
            }
            data.append(contentsOf: record)
        }
        
        // Padding
        if data.count < 4020 {
            data.append(Data(repeating: 0x00, count: 4020 - data.count))
        } else if data.count > 4020 {
            data = data.prefix(4020)
        }
        
        return data
    }
    
    // MARK: NAVAID.P01
    static func makeNavaidFile(navaids: [UserNavaid], usage: [String: Int]) -> Data {
        var data = Data()
        let count = min(navaids.count, maxNavaids)
        
        var header = makePresenceHeader(count: count)
        let byte13 = (count == 100) ? 128 : (129 + count)
        header.append(UInt8(byte13))
        header.append(UInt8(count * 2))
        header.append(0x00)
        data.append(contentsOf: header)
        
        for i in 0..<maxNavaids {
            var record = [UInt8](repeating: 0, count: 40)
            
            if i < count {
                let nv = navaids[i]
                
                record[0] = 0xE0 // Fast värde
                
                // Usage (Byte 2)
                let u = usage[nv.id] ?? 0
                record[2] = (u == 0) ? 0x30 : (u == 1 ? 0x70 : 0xF0)
                
                // ID (Byte 4-7)
                let idBytes = A109SixBitEncoder.encodeString(nv.id, maxChars: 5, totalBytes: 4)
                record[4..<8] = idBytes[0..<4]
                
                // Namn (Byte 8-15)
                let nameBytes = A109SixBitEncoder.encodeString(nv.name, maxChars: 10, totalBytes: 8)
                record[8..<16] = nameBytes[0..<8]
                
                // Dataordning
                record[20..<24] = float32BigEndian(Float(nv.frequency))[0..<4]
                record[24..<28] = float32BigEndian(Float(nv.longitude))[0..<4]
                record[28..<32] = float32BigEndian(Float(nv.latitude))[0..<4]
                record[32..<36] = float32BigEndian(Float(nv.magneticVariation))[0..<4]
                record[36..<40] = float32BigEndian(Float(nv.elevation))[0..<4]
            }
            data.append(contentsOf: record)
        }
        
        // Padding
        if data.count < 4020 {
            data.append(Data(repeating: 0x00, count: 4020 - data.count))
        } else if data.count > 4020 {
            data = data.prefix(4020)
        }
        
        return data
    }
    
    // MARK: WAYPOINT.P01
    static func makeWaypointFile(waypoints: [UserWaypoint], routeMembership: [String: Int]) -> Data {
        var data = Data()
        let count = min(waypoints.count, maxWaypoints)
        
        var header = makePresenceHeader(count: count)
        let byte13 = (count == 100) ? 128 : (129 + count)
        header.append(UInt8(byte13))
        header.append(UInt8(count * 2))
        header.append(0x00)
        data.append(contentsOf: header)
        
        for i in 0..<maxWaypoints {
            var record = [UInt8](repeating: 0, count: 28)
            
            if i < count {
                let wp = waypoints[i]
                
                // Lat/Lon
                record[0..<4] = float32BigEndian(Float(wp.latitude))[0..<4]
                record[4..<8] = float32BigEndian(Float(wp.longitude))[0..<4]
                
                // Namn (Byte 8-19)
                let nameBytes = A109SixBitEncoder.encodeString(wp.name, maxChars: 15, totalBytes: 12)
                record[8..<20] = nameBytes[0..<12]
                
                // Route membership (Byte 21)
                record[21] = UInt8(routeMembership[wp.id] ?? 0)
                
                // ID (Byte 24-27) - Special encoding
                let idBytes = A109SixBitEncoder.encodeWaypointID(wp.id)
                record[24..<28] = idBytes[0..<4]
            }
            data.append(contentsOf: record)
        }
        
        // Padding
        if data.count < 2820 {
            data.append(Data(repeating: 0x00, count: 2820 - data.count))
        } else if data.count > 2820 {
            data = data.prefix(2820)
        }
        
        return data
    }
    
    // MARK: ROUTE.P01
    static func makeRouteFile(routes: [Route],
                              userAirports: [UserAirport],
                              userNavaids: [UserNavaid],
                              userWaypoints: [UserWaypoint]) -> Data {
        var data = Data()
        let count = min(routes.count, maxRoutes)
        
        // Header
        var header = makePresenceHeader(count: count)
        let byte13 = (count == 100) ? 128 : (129 + count)
        header.append(UInt8(byte13))
        header.append(UInt8(count * 2))
        header.append(0x00)
        data.append(contentsOf: header)
        
        // Index Maps för User objects
        let aptIdxMap = Dictionary(uniqueKeysWithValues: userAirports.enumerated().map { ($0.element.id, $0.offset) })
        let navIdxMap = Dictionary(uniqueKeysWithValues: userNavaids.enumerated().map { ($0.element.id, $0.offset) })
        let wptIdxMap = Dictionary(uniqueKeysWithValues: userWaypoints.enumerated().map { ($0.element.id, $0.offset) })
        
        for i in 0..<maxRoutes {
            var record = [UInt8](repeating: 0, count: 500)
            
            if i < count {
                let route = routes[i]
                
                // 1. Namn (Byte 0-7)
                // --- FIX: Sanitera namnet (Endast A-Z, 0-9 och bindestreck tillåts) ---
                let allowedChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
                let cleanName = route.name.uppercased().filter { allowedChars.contains($0) }
                
                let nameBytes = A109SixBitEncoder.encodeString(cleanName, maxChars: 10, totalBytes: 8)
                record[0..<8] = nameBytes[0..<8]
                
                // 2. Analysera Start/Slut
                let first = route.pointRefs.first
                let last = route.pointRefs.last
                
                let startIsSystem = (first?.kind == .systemAirport)
                let endIsSystem = (last?.kind == .systemAirport)
                
                let startIsAnyApt = (first?.kind == .userAirport || first?.kind == .systemAirport)
                let lastIsAnyApt = (last?.kind == .userAirport || last?.kind == .systemAirport)
                
                var statusByte: UInt8 = 0x48 // Default
                
                // Logistical Header (Byte 8-16)
                if startIsAnyApt || lastIsAnyApt {
                    var startTypeBits: UInt8 = 0b010 // Ingen
                    var destTypeBits: UInt8 = 0b010  // Ingen
                    
                    if let start = first, startIsAnyApt {
                        let info = resolveLogistics(ref: start, aptMap: aptIdxMap)
                        record[8] = info.idBytes[0]; record[9] = info.idBytes[1]; record[10] = info.idBytes[2]
                        record[11] = info.dbIndex
                        startTypeBits = info.typeBits
                    }
                    
                    if let end = last, lastIsAnyApt {
                        let info = resolveLogistics(ref: end, aptMap: aptIdxMap)
                        record[12] = info.idBytes[0]; record[13] = info.idBytes[1]; record[14] = info.idBytes[2]
                        record[15] = info.dbIndex
                        destTypeBits = info.typeBits
                    }
                    
                    statusByte = (startTypeBits << 5) | (destTypeBits << 2)
                }
                record[16] = statusByte
                
                // 3. Filtrera punktlista (Exkludera System start/slut)
                var pointsToList: [RoutePointRef] = []
                for (idx, ref) in route.pointRefs.enumerated() {
                    let isFirst = (idx == 0)
                    let isLast = (idx == route.pointRefs.count - 1)
                    
                    if isFirst && startIsSystem { continue }
                    if isLast && endIsSystem { continue }
                    
                    pointsToList.append(ref)
                }
                
                if pointsToList.count > 40 {
                    print("Warning: Route '\(route.name)' truncated to 40 points.")
                }
                
                // 4. Skriv punktlista (Byte 17-499)
                let pts = min(pointsToList.count, 40)
                record[17] = UInt8(pts / 8)
                record[18] = UInt8((pts % 8) * 32)
                
                var ptOffset = 20
                for pIdx in 0..<40 {
                    if pIdx < pts {
                        let ref = pointsToList[pIdx]
                        var dbIdx: UInt8 = 0
                        var typeCode: UInt8 = 0x8C
                        var ptName = ""
                        
                        switch ref.kind {
                        case .userAirport:
                            typeCode = 0x5C
                            if let idx = aptIdxMap[ref.refId] { dbIdx = UInt8((idx + 1) * 2); ptName = userAirports[idx].id }
                            else { dbIdx = 0; ptName = ref.refId }
                            
                        case .userWaypoint:
                            typeCode = 0x6C
                            if let idx = wptIdxMap[ref.refId] { dbIdx = UInt8((idx + 1) * 2); ptName = userWaypoints[idx].id }
                            else { dbIdx = 0; ptName = ref.refId }
                            
                        case .userNavaid:
                            typeCode = 0x7C
                            if let idx = navIdxMap[ref.refId] { dbIdx = UInt8((idx + 1) * 2); ptName = userNavaids[idx].id }
                            else { dbIdx = 0; ptName = ref.refId }
                            
                        case .systemAirport:
                            typeCode = 0x5C
                            dbIdx = 0
                            ptName = ref.refId
                            
                        case .systemNavaid:
                            typeCode = 0x7C
                            dbIdx = 0
                            ptName = ref.refId
                        }
                        
                        record[ptOffset] = dbIdx
                        let nameB = A109SixBitEncoder.encodeString(ptName, maxChars: 5, totalBytes: 4)
                        record[(ptOffset+4)..<(ptOffset+8)] = nameB[0..<4]
                        record[ptOffset+11] = typeCode
                        
                    } else {
                        // Padding
                        record[ptOffset+11] = 0x8C
                    }
                    ptOffset += 12
                }
                
            } else {
                // Tom rutt
                record[16] = 0x48
                var ptOffset = 20
                for _ in 0..<40 {
                    record[ptOffset+11] = 0x8C
                    ptOffset += 12
                }
            }
            
            data.append(contentsOf: record)
        }
        
        // Padding
        if data.count < 50020 {
            data.append(Data(repeating: 0x00, count: 50020 - data.count))
        } else if data.count > 50020 {
            data = data.prefix(50020)
        }
        
        return data
    }
    
    struct LogInfo {
        let idBytes: [UInt8]
        let dbIndex: UInt8
        let typeBits: UInt8
    }
    
    static func resolveLogistics(ref: RoutePointRef, aptMap: [String: Int]) -> LogInfo {
        let idB = A109SixBitEncoder.encodeString(ref.refId, maxChars: 4, totalBytes: 4)
        let id3 = Array(idB.prefix(3))
        
        if ref.kind == .userAirport {
            if let idx = aptMap[ref.refId] {
                // User Airport: Type 101 (5), Index > 0
                return LogInfo(idBytes: id3, dbIndex: UInt8((idx+1)*2), typeBits: 0b101)
            }
        } else if ref.kind == .systemAirport {
            // System Airport: Type 100 (4), Index 0
            return LogInfo(idBytes: id3, dbIndex: 0, typeBits: 0b100)
        }
        
        // Fallback
        return LogInfo(idBytes: id3, dbIndex: 0, typeBits: 0b010)
    }
    
    // MARK: CARACTER.P01
    static func makeCaracterFile(date: Date,
                                 waypointFile: Data,
                                 airportFile: Data,
                                 navaidFile: Data,
                                 routeFile: Data) -> Data {
        var data = Data(repeating: 0x00, count: 116)
        
        data[0] = 0x55; data[1] = 0xAA; data[2] = 0x55; data[3] = 0xAA
        
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let yearFull = comps.year ?? 2000
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        
        let dateString = String(format: "DTD%d%02d%04d", day, month, yearFull)
        var dateBytes = A109SixBitEncoder.encodeString(dateString, maxChars: 10, totalBytes: 8)
        
        if dateBytes.count >= 8 {
            dateBytes[7] = (dateBytes[7] & 0xFC) | 0x02
        }
        data.replaceSubrange(4..<12, with: dateBytes)
        
        let yearOffset = yearFull - 2000
        let mVal = month - 1
        
        let b12 = (day << 3) | (mVal >> 1)
        let b13 = ((mVal & 1) << 7) | (yearOffset & 0x1F)
        
        data[12] = UInt8(b12 & 0xFF)
        data[13] = UInt8(b13 & 0xFF)
        
        data[14] = 0x40
        data[16] = 0x80; data[28] = 0x80; data[40] = 0x80; data[52] = 0x80
        
        func writeChk(source: Data, offset: Int) {
            let (sumLo, sumHi) = twoSigned16Sums(data: source)
            let b1 = int32BigEndian(sumLo)
            let b2 = int32BigEndian(sumHi)
            data.replaceSubrange(offset..<(offset+4), with: b1)
            data.replaceSubrange((offset+4)..<(offset+8), with: b2)
        }
        
        writeChk(source: waypointFile, offset: 68)
        writeChk(source: airportFile, offset: 80)
        writeChk(source: navaidFile, offset: 92)
        writeChk(source: routeFile, offset: 104)
        
        return data
    }
    
    // MARK: PILOTE.HD
    static func makePiloteFile(date: Date,
                               airportSize: Int,
                               navaidSize: Int,
                               waypointSize: Int,
                               routeSize: Int,
                               caracterSize: Int) -> Data {
        var data = Data()
        
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 2000
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        
        let dateString = String(format: "DTD%d%02d%04d", day, month, year)
        let ascii = Array(dateString.utf8.prefix(12))
        data.append(contentsOf: ascii)
        if data.count < 12 {
            data.append(Data(repeating: 0x20, count: 12 - data.count))
        }
        
        func appendInt32(_ value: Int) {
            let v = UInt32(value)
            data.append(UInt8((v >> 24) & 0xFF))
            data.append(UInt8((v >> 16) & 0xFF))
            data.append(UInt8((v >> 8) & 0xFF))
            data.append(UInt8(v & 0xFF))
        }
        
        appendInt32(year)
        appendInt32(month)
        appendInt32(day)
        appendInt32(airportSize)
        appendInt32(navaidSize)
        appendInt32(waypointSize)
        appendInt32(routeSize)
        appendInt32(caracterSize)
        
        return data
    }
}

// MARK: - Common Helpers

private extension A109PCMCIAExportService {
    
    static func usageCountsForAirports(routes: [Route]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for route in routes {
            if let first = route.pointRefs.first, first.kind == .userAirport {
                counts[first.refId, default: 0] += 1
            }
            if let last = route.pointRefs.last, last.kind == .userAirport {
                counts[last.refId, default: 0] += 1
            }
            for ref in route.pointRefs {
                if ref.kind == .userAirport {
                    counts[ref.refId, default: 0] += 1
                }
            }
        }
        return counts
    }
    
    static func usageCountsForNavaids(routes: [Route]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for route in routes {
            for ref in route.pointRefs {
                if ref.kind == .userNavaid {
                    counts[ref.refId, default: 0] += 1
                }
            }
        }
        return counts
    }
    
    static func waypointRouteMembershipMap(waypoints: [UserWaypoint], routes: [Route]) -> [String: Int] {
        var membership: [String: Int] = [:]
        for (routeIndex, route) in routes.enumerated() {
            let baseValue = (routeIndex + 1) * 8
            for ref in route.pointRefs where ref.kind == .userWaypoint {
                if membership[ref.refId] == nil {
                    membership[ref.refId] = baseValue
                }
            }
        }
        return membership
    }
    
    static func makePresenceHeader(count: Int) -> [UInt8] {
        let n = max(0, min(100, count))
        var header = [UInt8](repeating: 0, count: 13)
        for i in 0..<n {
            let byteIndex = i / 8
            let bitInByte = 7 - (i % 8)
            header[byteIndex] |= (1 << bitInByte)
        }
        return header
    }
    
    static func float32BigEndian(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return [
            UInt8((bits >> 24) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8(bits & 0xFF)
        ]
    }
    
    static func twoSigned16Sums(data: Data) -> (Int32, Int32) {
        var sumLo: Int32 = 0
        var sumHi: Int32 = 0
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if i + 1 < bytes.count {
                let hi = bytes[i]
                let lo = bytes[i+1]
                let word = Int16(bitPattern: (UInt16(hi) << 8) | UInt16(lo))
                sumLo = sumLo &+ Int32(word)
            }
            if i + 3 < bytes.count {
                let hi = bytes[i+2]
                let lo = bytes[i+3]
                let word = Int16(bitPattern: (UInt16(hi) << 8) | UInt16(lo))
                sumHi = sumHi &+ Int32(word)
            }
            i += 4
        }
        return (sumLo, sumHi)
    }
    
    static func int32BigEndian(_ value: Int32) -> [UInt8] {
        let v = UInt32(bitPattern: value)
        return [
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF)
        ]
    }
}

// MARK: - 6-bit Encoder

struct A109SixBitEncoder {
    
    private static let charToCode: [Character: UInt8] = [
        "-": 11,
        "0": 14, "1": 15, "2": 16, "3": 17, "4": 18,
        "5": 19, "6": 20, "7": 21, "8": 22, "9": 23,
        "A": 30, "B": 31, "C": 32, "D": 33, "E": 34,
        "F": 35, "G": 36, "H": 37, "I": 38, "J": 39,
        "K": 40, "L": 41, "M": 42, "N": 43, "O": 44,
        "P": 45, "Q": 46, "R": 47, "S": 48, "T": 49,
        "U": 50, "V": 51, "W": 52, "X": 53, "Y": 54,
        "Z": 55
    ]
    
    static func encodeString(_ string: String,
                             maxChars: Int,
                             totalBytes: Int) -> [UInt8] {
        let upper = string.uppercased()
        var codes: [UInt8] = []
        codes.reserveCapacity(maxChars)
        
        for ch in upper {
            guard codes.count < maxChars else { break }
            codes.append(charToCode[ch] ?? 0)
        }
        while codes.count < maxChars {
            codes.append(0)
        }
        
        var out = [UInt8]()
        
        for chunkIndex in 0..<(maxChars + 4) / 5 {
            let start = chunkIndex * 5
            let end = min(start + 5, maxChars)
            let chunk = codes[start..<end]
            
            var val: UInt32 = 0
            for (i, code) in chunk.enumerated() {
                let shift = 26 - (i * 6)
                val |= (UInt32(code) & 0x3F) << shift
            }
            out.append(UInt8((val >> 24) & 0xFF))
            out.append(UInt8((val >> 16) & 0xFF))
            out.append(UInt8((val >> 8) & 0xFF))
            out.append(UInt8(val & 0xFF))
        }
        
        if out.count < totalBytes {
            out.append(contentsOf: repeatElement(0, count: totalBytes - out.count))
        } else if out.count > totalBytes {
            out = Array(out.prefix(totalBytes))
        }
        return out
    }
    
    static func encodeWaypointID(_ string: String) -> [UInt8] {
        let standard = encodeString(string, maxChars: 5, totalBytes: 4)
        
        let val32 = (UInt32(standard[0]) << 24) |
                    (UInt32(standard[1]) << 16) |
                    (UInt32(standard[2]) << 8)  |
                    UInt32(standard[3])
        
        let shifted = (val32 >> 1) | 0x80000000
        
        return [
            UInt8((shifted >> 24) & 0xFF),
            UInt8((shifted >> 16) & 0xFF),
            UInt8((shifted >> 8) & 0xFF),
            UInt8(shifted & 0xFF)
        ]
    }
}
