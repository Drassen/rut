import Foundation
import CoreLocation

/// Robust importör för ForeFlight/Garmin FPL.
class FPLImportService: NSObject, RouteImporting, XMLParserDelegate {
    
    let supportedExtensions = ["fpl"]
    
    // --- State under parsing ---
    private var currentElement = ""
    private var currentChars = ""
    
    private var tempID = ""
    private var tempLat = ""
    private var tempLon = ""
    private var tempType = ""
    
    // Lagring (Separerad User / System)
    private var importedSystemAirports: [String: JepAirport] = [:]
    private var importedSystemNavaids: [String: JepNavaid] = [:]
    private var importedUserWaypoints: [String: UserWaypoint] = [:]
    
    private var routeSequenceIDs: [String] = []
    private var idRenamingMap: [String: String] = [:]
    private var wptCounter = 1
    
    private var routeName = "IMPORTED"
    
    func importDocument(from url: URL) throws -> NavigationDocument {
        // Nollställ
        importedSystemAirports = [:]
        importedSystemNavaids = [:]
        importedUserWaypoints = [:]
        routeSequenceIDs = []
        idRenamingMap = [:]
        wptCounter = 1
        currentElement = ""
        currentChars = ""
        routeName = url.deletingPathExtension().lastPathComponent
        
        // 1. LÄS FILEN (Robust inläsning)
        var contentString = ""
        do {
            // Låt NSString gissa encoding (hanterar BOM bättre)
            var usedEnc: UInt = 0
            contentString = try NSString(contentsOf: url, usedEncoding: &usedEnc) as String
        } catch {
            // Fallback
            contentString = (try? String(contentsOf: url, encoding: .utf8)) ?? ((try? String(contentsOf: url, encoding: .isoLatin1)) ?? "")
        }
        
        guard !contentString.isEmpty else {
            throw RutError.importFailed("Could not read FPL file content.")
        }
        
        // 2. TVÄTTA XML (Ta bort sånt som kraschar Swifts XMLParser)
        
        // Ta bort encoding-attributet helt (tvinga parsern att lita på vår UTF-8 data)
        contentString = contentString.replacingOccurrences(of: " encoding=\"[^\"]+\"", with: "", options: .regularExpression)
        contentString = contentString.replacingOccurrences(of: " encoding='[^']+'", with: "", options: .regularExpression)
        
        // Ta bort xmlns namespace för att förenkla tagg-namn matchning
        contentString = contentString.replacingOccurrences(of: " xmlns=\"[^\"]+\"", with: "", options: .regularExpression)
        
        // Trimma whitespace
        contentString = contentString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let finalData = contentString.data(using: .utf8) else {
            throw RutError.importFailed("Failed to create UTF-8 buffer.")
        }
        
        // 3. PARSA
        let parser = XMLParser(data: finalData)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        
        if parser.parse() {
            return buildDocument()
        } else {
            let errorMsg = parser.parserError?.localizedDescription ?? "Unknown"
            print("DEBUG: XML Parser Error: \(errorMsg)")
            throw RutError.importFailed("XML Parsing failed: \(errorMsg)")
        }
    }
    
    private func buildDocument() -> NavigationDocument {
        var finalRoutePoints: [RoutePointRef] = []
        
        for originalID in routeSequenceIDs {
            let lookupID = idRenamingMap[originalID] ?? originalID
            
            // Prioritera System-objekt enligt din regel
            if importedSystemAirports[lookupID] != nil {
                finalRoutePoints.append(RoutePointRef(kind: .systemAirport, refId: lookupID))
            } else if importedSystemNavaids[lookupID] != nil {
                finalRoutePoints.append(RoutePointRef(kind: .systemNavaid, refId: lookupID))
            } else if importedUserWaypoints[lookupID] != nil {
                finalRoutePoints.append(RoutePointRef(kind: .userWaypoint, refId: lookupID))
            } else {
                // Fallback (om definition saknas i tabellen) -> Anta User Waypoint
                finalRoutePoints.append(RoutePointRef(kind: .userWaypoint, refId: lookupID))
            }
        }
        
        let route = Route(routeId: UUID().uuidString, name: routeName, pointRefs: finalRoutePoints)
        
        return NavigationDocument(
            createdAt: Date(),
            routes: [route],
            // Endast User Waypoints importeras till User-listorna
            userAirports: [],
            userNavaids: [],
            userWaypoints: Array(importedUserWaypoints.values),
            // System-listorna fylls på här
            systemAirports: Array(importedSystemAirports.values),
            systemNavaids: Array(importedSystemNavaids.values)
        )
    }
    
    // MARK: - XML Delegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentChars = ""
        
        if elementName == "waypoint" {
            tempID = ""; tempLat = ""; tempLon = ""; tempType = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentChars += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let content = currentChars.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch currentElement {
        case "identifier", "waypoint-identifier":
            if !content.isEmpty { tempID = content }
        case "lat":
            if !content.isEmpty { tempLat = content }
        case "lon":
            if !content.isEmpty { tempLon = content }
        case "type":
            if !content.isEmpty { tempType = content }
            
        case "route-name":
            if !content.isEmpty {
                // Sanitera ruttnamnet (Endast A-Z, 0-9 och bindestreck)
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
                let filtered = content.uppercased().unicodeScalars.filter { allowed.contains($0) }
                let cleanName = String(String.UnicodeScalarView(filtered))
                routeName = cleanName.isEmpty ? "ROUTE" : cleanName
            }
            
        default: break
        }
        
        // Slut på definition
        if elementName == "waypoint" {
            // Rensa koordinatsträngar från skräp
            let cleanLat = tempLat.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-").inverted)
            let cleanLon = tempLon.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-").inverted)
            
            if let lat = Double(cleanLat), let lon = Double(cleanLon) {
                
                // REGLER:
                // AIRPORT -> System (JepAirport)
                if tempType == "AIRPORT" {
                    let ap = JepAirport(id: tempID, latitude: lat, longitude: lon)
                    importedSystemAirports[tempID] = ap
                }
                // VOR/NDB -> System (JepNavaid)
                else if tempType == "VOR" || tempType == "NDB" {
                    let nv = JepNavaid(id: tempID, latitude: lat, longitude: lon, type: tempType)
                    importedSystemNavaids[tempID] = nv
                }
                // ALLT ANNAT -> User Waypoint
                else {
                    var finalID = tempID
                    var finalType: WaypointType = .custom
                    
                    // Kolla om vi måste döpa om (koordinat-ID etc)
                    if shouldRename(id: tempID) {
                        let newName = String(format: "WPT%02d", wptCounter)
                        wptCounter += 1
                        idRenamingMap[tempID] = newName
                        finalID = newName
                        finalType = .wpt // Sätt typen till triangel!
                    }
                    // Om det redan är ett WPT-namn (t.ex. WPT01 eller F001)
                    else if finalID.hasPrefix("WPT") || (finalID.hasPrefix("F") && finalID.dropFirst().allSatisfy({ $0.isNumber })) {
                        finalType = .wpt
                    }
                    
                    let wp = UserWaypoint(
                        id: finalID,
                        name: finalID,
                        type: finalType,
                        latitude: lat,
                        longitude: lon,
                        elevation: 0
                    )
                    importedUserWaypoints[finalID] = wp
                }
            } else {
                print("DEBUG: Skipped point '\(tempID)' due to invalid coords.")
            }
        }
        
        // Slut på ruttpunkt
        if elementName == "route-point" {
            if !tempID.isEmpty {
                routeSequenceIDs.append(tempID)
            }
            tempID = ""
        }
        
        currentElement = ""
    }
    
    // MARK: - Helpers
    
    private func shouldRename(id: String) -> Bool {
        // 1. Bara siffror
        if id.allSatisfy({ $0.isNumber }) { return true }
        
        // 2. Garmin Standard (5824N...)
        let standardPattern = #"^\d{4}[NSns]\d{5}[EWew]$"#
        if id.range(of: standardPattern, options: .regularExpression) != nil { return true }
        
        // 3. Decimalformat (58,47792N/15,58947E) - Innehåller kommatecken, slash och N/S
        if id.contains(",") && id.contains("/") && (id.lowercased().contains("n") || id.lowercased().contains("s")) {
            return true
        }
        
        return false
    }
}
