import Foundation
import CoreLocation

// MARK: - ACOImportService
// Parses two ACO text formats:
//   • NATO USMTF  – ACMID/SHAPE/LATLONG/POINT/ALT fields
//   • OpenAir     – AC/AN/DP/DC/DA/V tokens

struct ACOImportService: RouteImporting {

    let supportedExtensions = ["aco", "txt"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        let (layer, _) = try importLayerWithWarnings(from: url)
        var doc = NavigationDocument()
        if !layer.shapes.isEmpty { doc.vectorLayers = [layer] }
        return doc
    }

    /// Import and return both the layer and any parse warnings (unparseable records).
    func importLayerWithWarnings(from url: URL) throws -> (VectorLayer, [String]) {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let isUsmtf = raw.contains("ACMID/") || raw.contains("SHAPE/") || raw.contains("LATLONG/")
            || raw.contains("GRID/") || raw.contains("MGRS/")
        let name = isUsmtf ? (extractMsgid(from: raw) ?? url.deletingPathExtension().lastPathComponent)
                           : url.deletingPathExtension().lastPathComponent
        let (shapes, warnings) = isUsmtf ? parseUsmtfWithWarnings(raw) : parseOpenAirWithWarnings(raw)
        var layer = VectorLayer(name: name)
        layer.shapes = shapes
        return (layer, warnings)
    }

    func importLayer(from url: URL) throws -> VectorLayer {
        let (layer, _) = try importLayerWithWarnings(from: url)
        return layer
    }

    // -------------------------------------------------------------------------
    // MARK: - MSGID extraction
    // -------------------------------------------------------------------------

    /// Extracts the exercise/operation name from MSGID/ACO/<originator>/<serial>//
    /// Returns the first token after "MSGID/" that isn't "ACO" or a serial number.
    private func extractMsgid(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("MSGID/") else { continue }
            let parts = t
                .replacingOccurrences(of: "//", with: "")
                .components(separatedBy: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // parts[0] = "MSGID", keep everything except "ACO" and "MSGID"
            let candidates = parts.dropFirst().filter {
                $0.uppercased() != "ACO" && $0.uppercased() != "MSGID"
            }
            if !candidates.isEmpty { return candidates.joined(separator: "/") }
        }
        return nil
    }

    // -------------------------------------------------------------------------
    // MARK: - NATO USMTF parser
    // -------------------------------------------------------------------------

    private func parseUsmtf(_ text: String) -> [VectorShape] {
        parseUsmtfWithWarnings(text).0
    }

    private func parseUsmtfWithWarnings(_ text: String) -> ([VectorShape], [String]) {
        // Split into records at each ACMID/ occurrence
        var records: [String] = []
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ACMID/") && !current.isEmpty {
                records.append(current)
                current = t
            } else {
                current += "\n" + t
            }
        }
        if !current.isEmpty { records.append(current) }

        var shapes: [VectorShape] = []
        var warnings: [String] = []
        for record in records {
            // Skip file-level header blocks (no ACMID/ line = not a shape record)
            guard record.contains("ACMID/") else { continue }
            if let shape = parseUsmtfRecord(record) {
                shapes.append(shape)
            } else {
                let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
                warnings.append(trimmed)
            }
        }
        return (shapes, warnings)
    }

    /// Returns a human-readable label for an unparseable USMTF record.
    private func usmtfRecordLabel(_ block: String) -> String {
        var name = "", type = "", shape = ""
        for rawLine in block.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "//", with: "").trimmingCharacters(in: .whitespaces)
            let fields = line.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let key = fields.first else { continue }
            switch key {
            case "ACMID":
                for f in fields.dropFirst() {
                    if f.hasPrefix("NAME:") { name = String(f.dropFirst(5)) }
                    if f.hasPrefix("TYPE:") { type = String(f.dropFirst(5)) }
                }
            case "SHAPE": shape = fields.dropFirst().first ?? ""
            default: break
            }
        }
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        if !type.isEmpty { parts.append("TYPE:\(type)") }
        if !shape.isEmpty { parts.append("SHAPE:\(shape)") }
        return parts.isEmpty ? "(unknown record)" : parts.joined(separator: " ")
    }

    private func parseUsmtfRecord(_ block: String) -> VectorShape? {
        var name     = ""
        var type     = ""
        var shape    = ""
        var widthNM  = 0.0
        var altLow   = ""
        var altHigh  = ""
        var coords:  [CLLocationCoordinate2D] = []
        var center:  CLLocationCoordinate2D?
        var radiusNM = 0.0

        for rawLine in block.components(separatedBy: .newlines) {
            // Strip trailing //
            let line = rawLine.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "//", with: "")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }

            let fields = line.components(separatedBy: "/").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let key = fields.first else { continue }

            switch key {
            case "ACMID":
                for f in fields.dropFirst() {
                    if f.hasPrefix("NAME:") { name = String(f.dropFirst(5)) }
                    if f.hasPrefix("TYPE:") { type = String(f.dropFirst(5)) }
                }
            case "SHAPE":
                shape = fields.dropFirst().first ?? ""
                for f in fields {
                    if f.hasPrefix("WIDTH:") {
                        let w = f.dropFirst(6).replacingOccurrences(of: "NM", with: "")
                        widthNM = Double(w) ?? 0
                    }
                }
            case "ALT":
                for f in fields.dropFirst() {
                    if f.hasPrefix("LOW:") { altLow = String(f.dropFirst(4)) }
                    else if f.hasPrefix("HIGH:") { altHigh = String(f.dropFirst(5)) }
                    else if altLow.isEmpty { altLow = f }
                    else if altHigh.isEmpty { altHigh = f }
                }
            case "LATLONG":
                for f in fields.dropFirst() {
                    if let c = parseCompact(f) { coords.append(c) }
                }
            case "GRID", "MGRS":
                for f in fields.dropFirst() {
                    if let c = MGRSConverter.toCoordinate(f) { coords.append(c) }
                }
            case "POINT":
                for f in fields.dropFirst() {
                    if f.hasPrefix("RADIUS:") {
                        let r = f.dropFirst(7).replacingOccurrences(of: "NM", with: "")
                        radiusNM = Double(r) ?? 0
                    } else if f.hasPrefix("GRID:") || f.hasPrefix("MGRS:") {
                        let mgrs = String(f.drop(while: { $0 != ":" }).dropFirst())
                        center = MGRSConverter.toCoordinate(mgrs)
                    } else if let c = parseCompact(f) {
                        center = c
                    } else if let c = MGRSConverter.toCoordinate(f) {
                        center = c
                    }
                }
            default: break
            }
        }

        let displayName = name.isEmpty ? type : name
        guard !displayName.isEmpty else { return nil }
        let style = styleForType(type)

        var noteParts: [String] = []
        if !type.isEmpty                  { noteParts.append("Type: \(type)") }
        if !altLow.isEmpty || !altHigh.isEmpty {
            let alt = [altLow.isEmpty ? nil : "Low: \(altLow)",
                       altHigh.isEmpty ? nil : "High: \(altHigh)"]
                        .compactMap { $0 }.joined(separator: ", ")
            noteParts.append("Alt: \(alt)")
        }
        if widthNM > 0                    { noteParts.append("Width: \(widthNM) NM") }
        if radiusNM > 0                   { noteParts.append("Radius: \(radiusNM) NM") }
        let notes = noteParts.joined(separator: "\n")

        switch shape {
        case "CIRCLE":
            guard let c = center else { return nil }
            return VectorShape(
                name: displayName, notes: notes,
                geometry: .circle(lat: c.latitude, lon: c.longitude,
                                  radiusMeters: radiusNM * 1_852),
                style: style)

        case "POINT":
            guard let c = center ?? coords.first else { return nil }
            return VectorShape(
                name: displayName, notes: notes,
                geometry: .point(lat: c.latitude, lon: c.longitude),
                style: style)

        case "POLYGON":
            guard coords.count >= 3 else { return nil }
            var ring = coords.map { [$0.latitude, $0.longitude] }
            if ring.first! != ring.last! { ring.append(ring[0]) }
            return VectorShape(name: displayName, notes: notes, geometry: .polygon(coordinates: ring), style: style)

        case "CORRIDOR", "LINE":
            guard coords.count >= 2 else { return nil }
            if widthNM > 0 {
                let poly = corridorPolygon(points: coords, halfWidthM: widthNM * 926)
                return VectorShape(name: displayName, notes: notes, geometry: .polygon(coordinates: poly), style: style)
            }
            return VectorShape(
                name: displayName, notes: notes,
                geometry: .polyline(coordinates: coords.map { [$0.latitude, $0.longitude] }),
                style: style)

        default:
            if coords.count >= 3 {
                var ring = coords.map { [$0.latitude, $0.longitude] }
                if ring.first! != ring.last! { ring.append(ring[0]) }
                return VectorShape(name: displayName, notes: notes, geometry: .polygon(coordinates: ring), style: style)
            } else if coords.count == 2 {
                return VectorShape(name: displayName, notes: notes,
                    geometry: .polyline(coordinates: coords.map { [$0.latitude, $0.longitude] }),
                    style: style)
            } else if let c = coords.first ?? center {
                return VectorShape(name: displayName, notes: notes,
                    geometry: .point(lat: c.latitude, lon: c.longitude), style: style)
            }
            return nil
        }
    }

    // Compact coordinate: "593000N0170000E"
    private func parseCompact(_ s: String) -> CLLocationCoordinate2D? {
        let up = s.uppercased()
        guard let nsIdx = up.firstIndex(where: { $0 == "N" || $0 == "S" }),
              let ewIdx = up.firstIndex(where: { $0 == "E" || $0 == "W" }),
              nsIdx < ewIdx else { return nil }
        let latStr = String(up[up.startIndex..<nsIdx])
        let lonStr = String(up[up.index(after: nsIdx)..<ewIdx])
        guard let lat = dmsCompact(latStr), let lon = dmsCompact(lonStr) else { return nil }
        let latS: Double = up[nsIdx] == "S" ? -1 : 1
        let lonS: Double = up[ewIdx] == "W" ? -1 : 1
        return CLLocationCoordinate2D(latitude: lat * latS, longitude: lon * lonS)
    }

    private func dmsCompact(_ s: String) -> Double? {
        let d = s.filter { $0.isNumber }
        switch d.count {
        case 4: // DDMM
            guard let deg = Double(d.prefix(2)), let min = Double(d.suffix(2)) else { return nil }
            return deg + min / 60
        case 5: // DDDMM
            guard let deg = Double(d.prefix(3)), let min = Double(d.suffix(2)) else { return nil }
            return deg + min / 60
        case 6: // DDMMSS
            guard let deg = Double(d.prefix(2)),
                  let min = Double(d.prefix(4).suffix(2)),
                  let sec = Double(d.suffix(2)) else { return nil }
            return deg + min / 60 + sec / 3600
        case 7: // DDDMMSS
            guard let deg = Double(d.prefix(3)),
                  let min = Double(d.prefix(5).suffix(2)),
                  let sec = Double(d.suffix(2)) else { return nil }
            return deg + min / 60 + sec / 3600
        default: return nil
        }
    }

    // Expand polyline to filled corridor polygon
    private func corridorPolygon(points: [CLLocationCoordinate2D],
                                  halfWidthM: Double) -> [[Double]] {
        var left:  [CLLocationCoordinate2D] = []
        var right: [CLLocationCoordinate2D] = []

        for i in 0..<points.count {
            let prev = i > 0 ? points[i-1] : points[i]
            let next = i < points.count-1 ? points[i+1] : points[i]
            // Average bearing from prev→this and this→next
            let b1 = i > 0 ? bearing(from: prev, to: points[i]) : bearing(from: points[i], to: next)
            let b2 = i < points.count-1 ? bearing(from: points[i], to: next) : b1
            let avg = ((b1 + b2) / 2 + 360).truncatingRemainder(dividingBy: 360)
            let perpL = (avg + 270).truncatingRemainder(dividingBy: 360)
            let perpR = (avg +  90).truncatingRemainder(dividingBy: 360)
            left.append(offset(points[i], bearing: perpL, meters: halfWidthM))
            right.append(offset(points[i], bearing: perpR, meters: halfWidthM))
        }

        var ring = left + right.reversed()
        ring.append(ring[0])
        return ring.map { [$0.latitude, $0.longitude] }
    }

    private func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func offset(_ coord: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let d = meters / R
        let b = bearing * .pi / 180
        let lat1 = coord.latitude  * .pi / 180
        let lon1 = coord.longitude * .pi / 180
        let lat2 = asin(sin(lat1)*cos(d) + cos(lat1)*sin(d)*cos(b))
        let lon2 = lon1 + atan2(sin(b)*sin(d)*cos(lat1), cos(d)-sin(lat1)*sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * (180 / .pi), longitude: lon2 * (180 / .pi))
    }

    private func styleForType(_ type: String) -> VectorStyle {
        var s = VectorStyle()
        s.strokeWidth = 2
        s.opacity = 0.85
        switch type.uppercased() {
        case "ROZ", "RESTRICTED", "R":
            s.strokeColor = "#EF4444"; s.fillColor = "#EF444425"
        case "HIDACZ", "PROHIBITED", "P":
            s.strokeColor = "#DC2626"; s.fillColor = "#DC262625"
        case "NFA":
            s.strokeColor = "#F97316"; s.fillColor = "#F9731625"
        case "MRR", "AAR", "TRANSIT", "CORRIDOR":
            s.strokeColor = "#3B82F6"; s.fillColor = "#3B82F625"
        case "BULLSEYE":
            s.strokeColor = "#FBBF24"; s.fillColor = "#FBBF2425"
        case "AEW", "CTR":
            s.strokeColor = "#8B5CF6"; s.fillColor = "#8B5CF625"
        default:
            s.strokeColor = "#6366F1"; s.fillColor = "#6366F125"
        }
        return s
    }

    // -------------------------------------------------------------------------
    // MARK: - OpenAir parser (AC/AN/DP/DC/DA/V tokens)
    // -------------------------------------------------------------------------

    private func parseOpenAir(_ text: String) -> [VectorShape] {
        parseOpenAirWithWarnings(text).0
    }

    private func parseOpenAirWithWarnings(_ text: String) -> ([VectorShape], [String]) {
        var shapes: [VectorShape] = []
        var warnings: [String] = []
        var cls = "", name = ""
        var points: [CLLocationCoordinate2D] = []
        var center: CLLocationCoordinate2D?
        var circleNM: Double?
        var arcDir = 1

        func flush() {
            guard !cls.isEmpty else { return }
            let n = name.isEmpty ? cls : name
            let style = styleForClass(cls)
            var noteParts: [String] = []
            noteParts.append("Class: \(cls)")
            if !name.isEmpty && name != cls { noteParts.append("Name: \(name)") }
            let notes = noteParts.joined(separator: "\n")
            if let r = circleNM, let c = center {
                shapes.append(VectorShape(name: n, notes: notes,
                    geometry: .circle(lat: c.latitude, lon: c.longitude, radiusMeters: r * 1_852),
                    style: style))
            } else if points.count >= 3 {
                var ring = points.map { [$0.latitude, $0.longitude] }
                if ring.first! != ring.last! { ring.append(ring[0]) }
                shapes.append(VectorShape(name: n, notes: notes, geometry: .polygon(coordinates: ring), style: style))
            } else if points.count == 2 {
                shapes.append(VectorShape(name: n, notes: notes,
                    geometry: .polyline(coordinates: points.map { [$0.latitude, $0.longitude] }),
                    style: style))
            } else if let p = points.first {
                shapes.append(VectorShape(name: n, notes: notes,
                    geometry: .point(lat: p.latitude, lon: p.longitude), style: style))
            } else {
                // Reconstruct raw OpenAir block for display
                let raw = "AC \(cls)\(name.isEmpty ? "" : "\nAN \(name)")\n(no parseable coordinates)"
                warnings.append(raw)
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("*") { continue }
            if line.hasPrefix("AC ") {
                flush()
                cls = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                name = ""; points = []; center = nil; circleNM = nil; arcDir = 1
            } else if line.hasPrefix("AN ") { name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("DP "), let c = parseOpenAirCoord(String(line.dropFirst(3))) { points.append(c)
            } else if line.hasPrefix("V X=") { center = parseOpenAirCoord(String(line.dropFirst(4)))
            } else if line.hasPrefix("V D=") { arcDir = line.contains("-") ? -1 : 1
            } else if line.hasPrefix("DC ") { circleNM = Double(line.dropFirst(3).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("DA ") {
                let p = line.dropFirst(3).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count >= 3, let r = Double(p[0]), let s = Double(p[1]), let e = Double(p[2]), let c = center {
                    points.append(contentsOf: arcPts(center: c, nm: r, from: s, to: e, dir: arcDir))
                }
            }
        }
        flush()
        return (shapes, warnings)
    }

    private func parseOpenAirCoord(_ raw: String) -> CLLocationCoordinate2D? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for h in ["N","S","E","W"] { s = s.replacingOccurrences(of: h, with: " \(h) ") }
        let t = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let ni = t.firstIndex(where: { $0=="N"||$0=="S" }),
              let ei = t.firstIndex(where: { $0=="E"||$0=="W" }), ni < ei else { return nil }
        guard let lat = dmsSpaced(Array(t[..<ni])), let lon = dmsSpaced(Array(t[(ni+1)..<ei])) else { return nil }
        return CLLocationCoordinate2D(latitude: lat * (t[ni]=="S" ? -1 : 1),
                                     longitude: lon * (t[ei]=="W" ? -1 : 1))
    }

    private func dmsSpaced(_ t: [String]) -> Double? {
        let parts = t.joined(separator: ":").components(separatedBy: ":")
        switch parts.count {
        case 1: return Double(parts[0])
        case 2: guard let d=Double(parts[0]),let m=Double(parts[1]) else{return nil}; return d+m/60
        case 3: guard let d=Double(parts[0]),let m=Double(parts[1]),let s=Double(parts[2]) else{return nil}; return d+m/60+s/3600
        default: return nil
        }
    }

    private func arcPts(center: CLLocationCoordinate2D, nm: Double,
                         from: Double, to: Double, dir: Int, n: Int = 24) -> [CLLocationCoordinate2D] {
        var end = to
        if dir > 0 && end < from { end += 360 }
        if dir < 0 && end > from { end -= 360 }
        let rM = nm * 1_852
        return (0...n).map { i in
            let a = (from + (end-from)*Double(i)/Double(n)) * .pi / 180
            let lat = center.latitude  + (rM/111_320)*cos(a)
            let lon = center.longitude + (rM/(111_320*cos(center.latitude * .pi/180)))*sin(a)
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private func styleForClass(_ cls: String) -> VectorStyle {
        var s = VectorStyle(); s.opacity = 0.8
        switch cls.uppercased() {
        case "R","P": s.strokeColor="#EF4444"; s.fillColor="#EF444420"
        case "D":     s.strokeColor="#F97316"; s.fillColor="#F9731620"
        case "CTR":   s.strokeColor="#3B82F6"; s.fillColor="#3B82F620"
        default:      s.strokeColor="#8B5CF6"; s.fillColor="#8B5CF620"
        }
        return s
    }
}
