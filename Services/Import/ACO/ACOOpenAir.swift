import Foundation

// Port of acoparse/openair.py — OpenAir airspace files, read into the same ACODocument model.
// AC opens a record; DP adds a vertex; V X= sets the centre for DC (circle) and DA/DB (arcs);
// V D= picks the sweep direction; V W= plus DY describes an airway. Radii and widths are NM.

enum ACOOpenAir {
    static let nmToM = 1852.0
    /// OpenAir altitudes are whole feet, and normally carry their unit anyway.
    static let altScaleFt = 1.0

    // 59:30:00 N 017:00:00 E, 59:30 N 017:00 E, 59.5 N 17.0 E
    private static let coordPattern = ACORegex(
        #"(?<lat>[\d.]+(?:[:\s]+[\d.]+){0,2})\s*(?<lah>[NS])[\s,]*(?<lon>[\d.]+(?:[:\s]+[\d.]+){0,2})\s*(?<loh>[EW])"#)
    private static let openAirLine = ACORegex(#"^\s*(?:AC|AN|AL|AH)\s+\S"#, multiline: true)
    private static let usmtfLine = ACORegex(#"^\s*(?:ACMID|MSGID|SHAPE|LATLONG)/"#, multiline: true)
    private static let degreeSeparators = ACORegex(#"[:\s]+"#)

    /// The characters `str.splitlines()` breaks on (after "\r\n" and "\r" are normalised).
    static let lineBreaks: Set<Character> = ["\n", "\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}"]

    /// Whether `text` reads as OpenAir rather than a USMTF message.
    static func looksLikeOpenAir(_ text: String) -> Bool {
        if text.contains("//") && usmtfLine.contains(text) { return false }
        return openAirLine.contains(text)
    }

    /// `59:30:00` or `59 30 00` or `59.5` to decimal degrees.
    static func degrees(_ text: String, _ hemisphere: String) -> Double? {
        let parts = degreeSeparators.split(ACOPy.strip(text)).filter { !$0.isEmpty }
        var values: [Double] = []
        for part in parts {
            guard let value = Double(part) else { return nil }
            values.append(value)
        }
        guard !values.isEmpty, values.count <= 3 else { return nil }

        let scale = [1.0, 1 / 60.0, 1 / 3600.0]
        var total = 0.0
        for (value, factor) in zip(values, scale) { total += value * factor }
        return hemisphere == "S" || hemisphere == "W" ? -total : total
    }

    /// Decode one OpenAir position.
    static func parseCoordinate(_ text: String) -> ACOCoordinate? {
        guard let m = coordPattern.firstMatch(in: text.uppercased()),
              let lat = degrees(m["lat"]!, m["lah"]!),
              let lon = degrees(m["lon"]!, m["loh"]!) else { return nil }
        let c = ACOCoordinate(lat: lat, lon: lon, raw: m.text)
        return c.isValid() ? c : nil
    }

    static func number(_ text: String) -> Double? { Double(ACOPy.strip(text)) }

    /// Points along an arc, swept the way `V D=` said to sweep it.
    static func arc(center: ACOCoordinate, radiusM: Double, start: Double, end: Double, clockwise: Bool,
                    resolution: Int = ACOGeometry.defaultResolution) -> [ACOCoordinate] {
        let origin = center.latLon
        var sweep = ACOPy.mod(end - start, 360.0)
        if !clockwise { sweep -= 360.0 }
        if sweep == 0.0 { sweep = clockwise ? 360.0 : -360.0 }

        let steps = max(2, ACOPy.round(Double(resolution) * abs(sweep) / 360.0))
        return (0...steps).map { i in
            let p = ACOGeo.destination(origin, start + sweep * Double(i) / Double(steps), radiusM)
            return ACOCoordinate(lat: p.lat, lon: p.lon)
        }
    }
}

final class ACOOpenAirParser {
    private var doc = ACODocument()
    private var klass: String?
    private var type: String?
    private var name = ""
    private var points: [ACOCoordinate] = []
    private var airway: [ACOCoordinate] = []
    private var center: ACOCoordinate?
    private var radiusM: Double?
    private var widthM: Double?
    // The sweep direction resets to clockwise at the start of every record.
    private var clockwise = true
    private var lower: String?
    private var upper: String?
    private var extras: [String: String] = [:]
    private var activation: String?
    private var line = 0

    private func reset() {
        klass = nil
        type = nil
        name = ""
        points = []
        airway = []
        center = nil
        radiusM = nil
        widthM = nil
        clockwise = true
        lower = nil
        upper = nil
        extras = [:]
        activation = nil
        line = 0
    }

    func parse(_ text: String, source: String?) -> ACODocument {
        doc = ACODocument(source: source)
        reset()

        let lines = ACOPy.normalizeNewlines(text)
            .split(omittingEmptySubsequences: false, whereSeparator: { ACOOpenAir.lineBreaks.contains($0) })
        for (index, rawLine) in lines.enumerated() {
            let line = ACOPy.strip(String(rawLine))
            if line.isEmpty || line.hasPrefix("*") { continue }
            handle(line, index + 1)
        }

        flush()
        return doc
    }

    private func handle(_ line: String, _ number: Int) {
        let upperLine = line.uppercased()
        var body = ""
        if line.contains(" "), let gap = line.rangeOfCharacter(from: .whitespacesAndNewlines) {
            body = ACOPy.strip(String(line[gap.upperBound...]))
        }

        if upperLine.hasPrefix("AC ") {
            flush()
            reset()
            klass = body.uppercased()
            self.line = number
        } else if klass == nil {
            return  // anything before the first AC is a file header
        } else if upperLine.hasPrefix("AN ") {
            name = body
        } else if upperLine.hasPrefix("AY ") {
            // openAIP's airspace type, which says what "AC D" alone cannot.
            type = body.uppercased()
        } else if upperLine.hasPrefix("AL ") {
            lower = body
        } else if upperLine.hasPrefix("AH ") {
            upper = body
        } else if upperLine.hasPrefix("AF ") {
            extras["FREQUENCY"] = body
        } else if upperLine.hasPrefix("AG ") {
            extras["GROUND_STATION"] = body
        } else if upperLine.hasPrefix("AX ") {
            extras["TRANSPONDER"] = body
        } else if upperLine.hasPrefix("AA ") {
            activation = body
        } else if upperLine.hasPrefix("DP ") {
            guard let c = ACOOpenAir.parseCoordinate(body) else {
                warn("DP position \(ACOPy.repr(body)) could not be read", number)
                return
            }
            points.append(c)
        } else if upperLine.hasPrefix("DY ") {
            // DY is an airway centreline point, widened by V W=.
            guard let c = ACOOpenAir.parseCoordinate(body) else {
                warn("DY position \(ACOPy.repr(body)) could not be read", number)
                return
            }
            airway.append(c)
        } else if upperLine.hasPrefix("V ") {
            variable(body)
        } else if upperLine.hasPrefix("DC ") {
            if let radiusNM = ACOOpenAir.number(body), radiusNM != 0 {
                radiusM = radiusNM * ACOOpenAir.nmToM
            } else {
                radiusM = nil
                warn("DC radius \(ACOPy.repr(body)) is not a number", number)
            }
        } else if upperLine.hasPrefix("DA ") {
            arcByBearings(body, number)
        } else if upperLine.hasPrefix("DB ") {
            arcBetween(body, number)
        }
        // AT (label position), SP and SB (pen and brush) carry no geometry.
    }

    /// `V X=<centre>` sets the arc centre, `V D=-` reverses the sweep, `V W=` the airway width.
    private func variable(_ body: String) {
        let p = ACOPy.partition(body, "=")
        let key = ACOPy.strip(p.head).uppercased()
        if key == "X" {
            center = ACOOpenAir.parseCoordinate(p.tail)
        } else if key == "D" {
            clockwise = !p.tail.contains("-")
        } else if key == "W" {
            if let widthNM = ACOOpenAir.number(p.tail), widthNM != 0 {
                widthM = widthNM * ACOOpenAir.nmToM
            } else {
                widthM = nil
            }
        }
        // V Z= is a zoom threshold and has no bearing on the geometry.
    }

    /// `DA <radius NM>,<start bearing>,<end bearing>`
    private func arcByBearings(_ body: String, _ number: Int) {
        let parts = body.components(separatedBy: ",").map(ACOPy.strip)
        let values = parts.prefix(3).map(ACOOpenAir.number)
        guard values.count >= 3, values.allSatisfy({ $0 != nil }), let center else {
            warn("DA arc \(ACOPy.repr(body)) could not be read", number)
            return
        }
        points.append(contentsOf: ACOOpenAir.arc(center: center, radiusM: values[0]! * ACOOpenAir.nmToM,
                                                 start: values[1]!, end: values[2]!, clockwise: clockwise))
    }

    /// `DB <from>,<to>` — an arc around the current centre between two points.
    private func arcBetween(_ body: String, _ number: Int) {
        let parts = body.components(separatedBy: ",").map(ACOPy.strip)
        guard parts.count >= 2, let center else {
            warn("DB arc \(ACOPy.repr(body)) could not be read", number)
            return
        }
        guard let first = ACOOpenAir.parseCoordinate(parts[0]),
              let second = ACOOpenAir.parseCoordinate(parts[1]) else {
            warn("DB arc \(ACOPy.repr(body)) could not be read", number)
            return
        }

        let origin = center.latLon
        let radius = ACOGeo.distance(origin, first.latLon)
        points.append(contentsOf: ACOOpenAir.arc(center: center, radiusM: radius,
                                                 start: ACOGeo.bearing(origin, first.latLon),
                                                 end: ACOGeo.bearing(origin, second.latLon),
                                                 clockwise: clockwise))
    }

    private func geometry() -> ACOGeometry? {
        if airway.count >= 2 {
            if let widthM, widthM != 0 { return .corridor(airway, widthM: widthM) }
            return .polyline(airway, kind: "AIRWAY")
        }
        if let radiusM, radiusM != 0, let center { return .circle([center], radiusM: radiusM) }
        if points.count >= 3 { return .polygon(points) }
        if points.count == 2 { return .polyline(points) }
        if let first = points.first { return .point([first]) }
        if let center { return .point([center]) }
        return nil
    }

    private func flush() {
        guard let klass else { return }

        // AY names the airspace type; AC only gives a class letter.
        let typeName = type.flatMap { $0.isEmpty ? nil : $0 }
        var air = ACOAirspace()
        air.name = !name.isEmpty ? name : (typeName ?? klass)
        air.acmType = typeName ?? klass
        air.geometry = geometry()
        air.line = line

        if !(lower ?? "").isEmpty || !(upper ?? "").isEmpty {
            air.vertical = ACOAltitudeParser.makeExtent(lower: lower, upper: upper, scaleFt: ACOOpenAir.altScaleFt)
        }
        air.attributes["CLASS"] = klass
        for (key, value) in extras { air.attributes[key] = value }
        if let activation, !activation.isEmpty {
            air.periods.append(ACOTimePeriod(raw: activation))
        }

        if air.geometry == nil { warn("[\(air.name)] no readable coordinates", line) }
        doc.airspaces.append(air)
    }

    private func warn(_ message: String, _ line: Int) {
        doc.warnings.append(ACOParseWarning(message: message, line: line))
    }
}
