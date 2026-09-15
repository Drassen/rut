import Foundation

// Port of acoparse/parser.py — turn tokenized sets into an ACODocument.
// Every set contributes what it knows to one shape builder per airspace, and the geometry
// is built once the airspace is complete. Unrecognised sets are warned about and kept.

enum ACOReader {
    /// Parse airspace content; OpenAir is detected from the content, USMTF otherwise.
    static func parseText(_ text: String, source: String? = nil, defaultYear: Int? = nil) -> ACODocument {
        if ACOOpenAir.looksLikeOpenAir(text) {
            return ACOOpenAirParser().parse(text, source: source)
        }
        return ACOParser(defaultYear: defaultYear).parseText(text, source: source)
    }

    /// Parse an ACO or OpenAir file; falls back to Latin-1 when it is not valid UTF-8.
    static func parseFile(_ url: URL, defaultYear: Int? = nil) throws -> ACODocument {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return parseText(ACOPy.normalizeNewlines(text), source: url.path, defaultYear: defaultYear)
    }
}

/// Everything the sets under one ACMID said about its geometry.
private struct ACOShapeBuilder {
    var shape: String? = nil
    /// A weaker shape suggestion, from a bare field in the ACMID set.
    var hint: String? = nil
    /// The shape name as written, kept so an unknown one can be reported.
    var declared: String? = nil
    var coords: [ACOCoordinate] = []
    var center: ACOCoordinate? = nil
    var radiusM: Double? = nil
    var innerRadiusM: Double? = nil
    var widthM: Double? = nil
    var bearings: [Double] = []

    mutating func setShape(_ name: String, authoritative: Bool) {
        guard let resolved = ACOParser.shapeAliases[name.uppercased()] else {
            if (declared ?? "").isEmpty { declared = name }
            return
        }
        if authoritative || shape == nil {
            shape = resolved
            declared = name
        }
    }

    /// The geometry these sets describe, plus anything worth warning about.
    func build() -> (ACOGeometry?, [String]) {
        var warnings: [String] = []
        let coords = self.coords.filter { $0.isValid() }
        var center = (self.center?.isValid() ?? false) ? self.center : nil
        if center == nil, let first = coords.first { center = first }

        let shape = self.shape ?? hint
        if shape == nil, let declared, !declared.isEmpty {
            warnings.append("Unrecognised shape \(ACOPy.repr(declared)); geometry inferred from the coordinates")
        }

        switch shape {
        case "CIRCLE":
            guard let center else { return (nil, warnings + ["CIRCLE has no centre point"]) }
            guard let radiusM, radiusM != 0 else {
                return (.point([center]), warnings + ["CIRCLE has no readable radius; exported as a point"])
            }
            return (.circle([center], radiusM: radiusM), warnings)

        case "RADARC":
            return buildRadarc(center, warnings)

        case "CORRIDOR", "ORBIT":
            let name = shape!
            if coords.count < 2 { return degenerate(name, coords, center, warnings) }
            guard let widthM, widthM != 0 else {
                return (.polyline(coords, kind: name), warnings + ["\(name) has no readable width; exported as a centreline"])
            }
            return (name == "CORRIDOR" ? .corridor(coords, widthM: widthM) : .orbit(coords, widthM: widthM), warnings)

        case "POLYGON":
            if coords.count < 3 { return degenerate("POLYGON", coords, center, warnings) }
            return (.polygon(coords), warnings)

        case "LINE":
            if coords.count < 2 { return degenerate("LINE", coords, center, warnings) }
            return (.polyline(coords, kind: "LINE"), warnings)

        case "POINT":
            guard let center else { return (nil, warnings + ["POINT has no coordinates"]) }
            return (.point([center]), warnings)

        default:
            // No usable shape name: read it off the coordinates.
            if coords.count >= 3 { return (.polygon(coords), warnings) }
            if coords.count == 2 { return (.polyline(coords), warnings) }
            if let center { return (.point([center]), warnings) }
            return (nil, warnings + ["No coordinates found"])
        }
    }

    /// Too few points for the declared shape: fall back rather than drop it.
    private func degenerate(_ shape: String, _ coords: [ACOCoordinate], _ center: ACOCoordinate?,
                            _ warnings: [String]) -> (ACOGeometry?, [String]) {
        let need = shape == "POLYGON" ? 3 : 2
        let note = "\(shape) has only \(coords.count) coordinate(s), needs \(need)"
        if coords.count == 2 { return (.polyline(coords), warnings + [note]) }
        if let center { return (.point([center]), warnings + [note]) }
        return (nil, warnings + [note])
    }

    private func buildRadarc(_ center: ACOCoordinate?, _ warnings: [String]) -> (ACOGeometry?, [String]) {
        guard let center else { return (nil, warnings + ["RADARC has no centre point"]) }
        guard let radiusM, radiusM != 0 else {
            return (.point([center]), warnings + ["RADARC has no readable radius"])
        }
        let (begin, end) = bearings.count >= 2 ? (bearings[0], bearings[1]) : (0.0, 360.0)
        return (.radArc([center], innerRadiusM: innerRadiusM ?? 0.0, outerRadiusM: radiusM,
                        beginBearing: begin, endBearing: end), warnings)
    }
}

final class ACOParser {
    // Sets naming a shape and usually carrying its coordinates too.
    static let shapeSets: Set<String> = [
        "CIRCLE", "POLYGON", "CORRIDOR", "APOINT", "POINT", "GEOLINE", "LINE",
        "RADARC", "ORBIT", "AORBIT", "TRACK", "POLYARC", "ARCSEG", "ROUTE",
    ]
    // Sets carrying only positions, leaving the shape to be declared elsewhere.
    static let positionSets: Set<String> = ["LATLONG", "GRID", "MGRS", "LATLON", "LL"]
    // Every shape name seen in the wild, mapped onto the geometry it produces.
    static let shapeAliases: [String: String] = [
        "CIRCLE": "CIRCLE", "POLYGON": "POLYGON", "POLYARC": "POLYGON",
        "CORRIDOR": "CORRIDOR", "TRACK": "CORRIDOR", "ROUTE": "CORRIDOR",
        "ORBIT": "ORBIT", "AORBIT": "ORBIT", "RADARC": "RADARC",
        "POINT": "POINT", "APOINT": "POINT",
        "LINE": "LINE", "GEOLINE": "LINE", "ARCSEG": "LINE",
    ]
    // Sets whose whole body is free text.
    static let textSets: Set<String> = ["AMPN", "NARR", "GENTEXT", "RMKS", "REMARKS"]
    // Header sets that appear before the first ACMID.
    static let headerSets: Set<String> = [
        "EXER", "OPER", "MSGID", "TIMEFRM", "PERIOD", "REF", "ACOHDR", "ACOID", "GEODATUM", "AMPN",
    ]
    // Datums whose coordinates need no shifting.
    static let knownDatums: Set<String> = ["W84", "WGS84", "WGS-84", "WGE", "WE"]
    static let floorQualifiers: Set<String> = ["LOW", "MIN", "MINALT", "BASE", "FLOOR", "LOWER", "BOTTOM"]
    static let ceilingQualifiers: Set<String> = ["HIGH", "MAX", "MAXALT", "TOP", "CEILING", "UPPER"]
    // Qualifiers that introduce a position rather than a measurement.
    static let positionQualifiers: Set<String> = ["LATS", "LATM", "LL", "LATLON", "LATLONG", "GRID", "MGRS", "PT"]

    static let unitsM: [String: Double] = [
        "M": 1.0, "MTR": 1.0, "MTRS": 1.0, "METER": 1.0, "METERS": 1.0, "METRE": 1.0,
        "KM": 1000.0, "KMS": 1000.0,
        "NM": 1852.0, "NMI": 1852.0, "NAM": 1852.0,
        "FT": 0.3048, "FEET": 0.3048,
        "SM": 1609.344, "MI": 1609.344,
    ]
    /// Unit assumed when a radius or width carries none.
    static let defaultDistanceUnit = "M"

    private static let distancePattern = ACORegex(#"^(?<num>\d+(?:\.\d+)?)\s*(?<unit>[A-Z]*)$"#)
    private static let nilPattern = ACORegex(#"^-+$"#)
    // A date-time group that stops at the month: "180230ZMAR" with no year.
    private static let dtgNoYear = ACORegex(#"\d{6}Z(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)(?!\s*\d)"#)
    private static let bearingPattern = ACORegex(#"^(?<num>\d{1,3}(?:\.\d+)?)\s*(?<ref>[TMG]?)$"#)

    /// A distance token such as `3000M`, `5NM` or `10KM`, in metres.
    static func parseDistance(_ text: String, defaultUnit: String = defaultDistanceUnit) -> Double? {
        var token = ACOPy.strip(text).uppercased().replacingOccurrences(of: " ", with: "")
        if token.contains(":") { token = ACOPy.partition(token, ":").tail }
        guard let m = distancePattern.firstMatch(in: token), let number = Double(m["num"]!) else { return nil }
        let unitText = m["unit"] ?? ""
        guard let factor = unitsM[unitText.isEmpty ? defaultUnit : unitText] else { return nil }
        return number * factor
    }

    /// Whether a field or set is the USMTF no-data marker (a lone `-`, or a run of them).
    static func isNil(_ text: String) -> Bool {
        nilPattern.contains(ACOPy.strip(text))
    }

    /// A bearing token such as `090` or `090T`, in degrees.
    private static func parseBearing(_ text: String) -> Double? {
        var token = ACOPy.strip(text).uppercased().replacingOccurrences(of: " ", with: "")
        if token.contains(":") { token = ACOPy.partition(token, ":").tail }
        guard let m = bearingPattern.firstMatch(in: token), let value = Double(m["num"]!) else { return nil }
        return value >= 0 && value <= 360 ? ACOPy.mod(value, 360.0) : nil
    }

    /// Year to assume when a date-time group omits one.
    private var defaultYear: Int?
    private var doc = ACODocument()
    private var current: ACOAirspace?
    private var builder = ACOShapeBuilder()
    private var unknownSeen: Set<String> = []
    private var undated = 0

    init(defaultYear: Int? = nil) {
        self.defaultYear = defaultYear
    }

    func parseText(_ text: String, source: String? = nil) -> ACODocument {
        doc = ACODocument(source: source)
        current = nil
        builder = ACOShapeBuilder()
        unknownSeen = []
        undated = 0

        let sets = ACOLexer.tokenize(text)
        doc.sets = sets
        for s in sets { dispatch(s) }
        flush()

        if undated > 0 {
            warn("\(undated) APERIOD set(s) omit the year and the message header gives none; pass default_year to date them")
        }
        return doc
    }

    // MARK: - Dispatch

    private func dispatch(_ s: ACOSetLine) {
        let name = s.name

        if name == "ACMID" {
            flush()
            current = parseAcmid(s)
            return
        }

        guard current != nil else {
            if Self.headerSets.contains(name) { parseHeader(s) }
            return
        }

        current!.sets.append(s)

        if Self.isNil(name) {
            // A lone "-" where the geometry would go: the record is a placeholder.
            current!.isNil = true
            return
        }

        if name == "GEODATUM" {
            var datum = ACOPy.strip(ACOPy.partition(s.raw, "/").tail).uppercased()
            while datum.hasSuffix("/") { datum.removeLast() }
            current!.attributes["GEODATUM"] = datum
            if !datum.isEmpty && !Self.knownDatums.contains(datum) {
                warn("Geodetic datum is \(ACOPy.repr(datum)), not WGS84; positions are not shifted", s)
            }
            return
        }

        if name == "CONTAUTH" {
            current!.controllingAuthority = s.fields
                .first { !ACOPy.strip($0.raw).isEmpty && !Self.isNil($0.raw) }
                .map { ACOPy.strip($0.raw) }
            return
        }

        if name == "SHAPE" {
            parseShapeDeclaration(s)
        } else if Self.shapeSets.contains(name) {
            parseShapeSet(s)
        } else if Self.positionSets.contains(name) {
            collectPositions(s)
        } else if name == "EFFLEVEL" {
            parseEfflevel(s)
        } else if name == "ALT" {
            parseAlt(s)
        } else if name == "APERIOD" {
            parseAperiod(s)
        } else if Self.textSets.contains(name) {
            let body = ACOPy.strip(ACOPy.partition(s.raw, "/").tail)
            if !body.isEmpty { current!.remarks.append(body) }
        } else {
            collectAttributes(s)
            if !unknownSeen.contains(name) {
                unknownSeen.insert(name)
                warn("Unrecognised set '\(name)' kept as attributes only", s)
            }
        }
    }

    // MARK: - Header

    private func parseHeader(_ s: ACOSetLine) {
        let body = ACOPy.strip(ACOPy.partition(s.raw, "/").tail)

        func setIfAbsent(_ key: String, _ value: String) {
            if doc.header[key] == nil { doc.header[key] = value }
        }

        switch s.name {
        case "EXER":
            setIfAbsent("exercise", body)
        case "OPER":
            setIfAbsent("operation", body)
        case "MSGID":
            doc.header["message_type"] = s.positional(0) ?? ""
            doc.header["originator"] = s.positional(1) ?? ""
            if let serial = s.positional(2), !serial.isEmpty, !Self.isNil(serial) {
                doc.header["serial"] = serial
            }
            // Some producers put the validity window in MSGID and omit PERIOD.
            if doc.validFrom == nil {
                let dtgs = ACODTG.findAll(body, defaultYear: defaultYear)
                if let first = dtgs.first {
                    doc.validFrom = first
                    doc.validTo = dtgs.count > 1 ? dtgs.last : nil
                }
            }
        case "TIMEFRM", "PERIOD":
            // The message's own validity window, and the only place the year appears.
            let dtgs = ACODTG.findAll(body, defaultYear: defaultYear)
            if let first = dtgs.first {
                doc.validFrom = first
                doc.validTo = dtgs.count > 1 ? dtgs.last : nil
                if defaultYear == nil { defaultYear = first.year }
            }
            doc.header["timeframe"] = body
        case "ACOID":
            doc.header["aco_id"] = body
        case "GEODATUM":
            let datum = ACOPy.strip(body).uppercased()
            doc.header["geodatum"] = datum
            if !datum.isEmpty && !Self.knownDatums.contains(datum) {
                warn("Geodetic datum is \(ACOPy.repr(datum)), not WGS84; positions are not shifted", s)
            }
        case "AMPN":
            doc.header["amplification"] = body
        default:
            setIfAbsent(s.name.lowercased(), body)
        }
    }

    // MARK: - ACMID

    private func parseAcmid(_ s: ACOSetLine) -> ACOAirspace {
        var air = ACOAirspace()
        air.line = s.line
        air.sets = [s]
        builder = ACOShapeBuilder()

        var bare: [String] = []
        for (index, f) in s.fields.enumerated() {
            let qual = f.qualifier
            if qual == "NAME" {
                air.name = f.value
            } else if qual == "ACM" || qual == "TYPE" {
                // ACM: wins if both appear; an empty value means the record is a placeholder.
                if !f.value.isEmpty && (air.acmType == nil || qual == "ACM") {
                    air.acmType = f.value.uppercased()
                }
            } else if qual == "USE" {
                if !f.value.isEmpty { air.usage = f.value.uppercased() }
            } else if let qual, !qual.isEmpty {
                air.setAttributeIfAbsent(qual, f.value)
            } else if !ACOPy.strip(f.raw).isEmpty && !Self.isNil(f.raw) {
                let token = ACOPy.strip(f.raw)
                if let alias = Self.shapeAliases[token.uppercased()] {
                    builder.hint = alias
                    air.setAttributeIfAbsent("SHAPE_HINT", token.uppercased())
                } else {
                    bare.append(token)
                    air.setAttributeIfAbsent("FIELD\(index)", token)
                }
            }
        }

        // Some producers omit NAME: and give the identifier positionally.
        if air.name.isEmpty, let first = bare.first { air.name = first }
        return air
    }

    private func collectAttributes(_ s: ACOSetLine) {
        for f in s.fields {
            if let qual = f.qualifier, !qual.isEmpty {
                current!.setAttributeIfAbsent("\(s.name)_\(qual)", f.value)
            } else if !ACOPy.strip(f.raw).isEmpty {
                current!.setAttributeIfAbsent(s.name, ACOPy.strip(f.raw))
            }
        }
    }

    // MARK: - Vertical / time

    /// `EFFLEVEL/RARA:000GND-005GND//`, or a floor and ceiling as two fields.
    private func parseEfflevel(_ s: ACOSetLine) {
        // A field holding "<floor>-<ceiling>" is the usual form and wins outright.
        var partial: ACOVerticalExtent? = nil
        for f in s.fields {
            if ACOPy.strip(f.raw).isEmpty || Self.isNil(f.raw) { continue }
            let extent = ACOAltitudeParser.parseEfflevelValue(qualifier: f.qualifier, value: f.value)
            if extent.lower != nil && extent.upper != nil {
                current!.vertical = extent
                return
            }
            if partial == nil && (extent.lower != nil || extent.upper != nil) { partial = extent }
        }

        // Otherwise the two ends may be separate fields, as MINALT:/MAXALT:.
        if setExtentFromFields(s, scaleFt: ACOAltitudeParser.hundredsOfFeet ? 100.0 : 1.0) { return }

        // Failing that, keep whatever single altitude was readable.
        if let partial {
            current!.vertical = partial
            return
        }
        warn("EFFLEVEL had no readable altitude pair", s)
    }

    /// `ALT/LOW:1500/HIGH:FL200//`
    private func parseAlt(_ s: ACOSetLine) {
        if !setExtentFromFields(s, scaleFt: ACOAltitudeParser.altSetScaleFt) {
            warn("ALT had no readable altitudes", s)
        }
    }

    /// A floor and ceiling given as separate fields: LOW:/HIGH:, MINALT:/MAXALT:, or bare.
    private func setExtentFromFields(_ s: ACOSetLine, scaleFt: Double) -> Bool {
        var low: String? = nil
        var high: String? = nil
        var bare: [String] = []

        for f in s.fields {
            let qual = (f.qualifier ?? "").uppercased()
            if Self.floorQualifiers.contains(qual) {
                low = f.value
            } else if Self.ceilingQualifiers.contains(qual) {
                high = f.value
            } else if qual.isEmpty && !ACOPy.strip(f.raw).isEmpty && !Self.isNil(f.raw) {
                bare.append(ACOPy.strip(f.raw))
            }
        }

        if low == nil, let first = bare.first { low = first }
        if high == nil, bare.count > 1 { high = bare[1] }
        if low == nil && high == nil { return false }

        current!.vertical = ACOAltitudeParser.makeExtent(
            lower: low, upper: high, scaleFt: scaleFt, raw: ACOPy.strip(ACOPy.partition(s.raw, "/").tail))
        return true
    }

    private func parseAperiod(_ s: ACOSetLine) {
        let body = ACOPy.strip(ACOPy.partition(s.raw, "/").tail)
        var mode = s.positional(0)
        if let m = mode, m.contains(where: { $0.isNumber }) { mode = nil }

        let dtgs = ACODTG.findAll(body, defaultYear: defaultYear)
        let upperMode = (mode ?? "").uppercased()
        let period = ACOTimePeriod(start: dtgs.first, stop: dtgs.count > 1 ? dtgs[1] : nil,
                                   mode: upperMode.isEmpty ? nil : upperMode, raw: body)

        if period.start == nil && !period.isContinuous && body.contains(where: { $0.isNumber }) {
            if defaultYear == nil && Self.dtgNoYear.contains(body.uppercased()) {
                // The set is well-formed, the file just never says which year.
                undated += 1
            } else {
                warn("APERIOD contained no readable date-time group", s)
            }
        }
        current!.periods.append(period)
    }

    // MARK: - Shapes

    /// `SHAPE/CIRCLE/WIDTH:5NM//` — names the shape without any coordinates.
    private func parseShapeDeclaration(_ s: ACOSetLine) {
        for f in s.fields {
            let qual = (f.qualifier ?? "").uppercased()
            let token = ACOPy.strip(f.raw)
            if token.isEmpty { continue }
            if qual == "WIDTH" {
                builder.widthM = Self.parseDistance(token)
            } else if qual == "RADIUS" {
                builder.radiusM = Self.parseDistance(token)
            } else if qual.isEmpty {
                builder.setShape(token, authoritative: true)
            }
        }
    }

    /// A set named after its shape, which usually carries the coordinates too.
    private func parseShapeSet(_ s: ACOSetLine) {
        let coords = positions(s)
        let name = s.name

        // A POINT set carrying a radius is a circle's centre, not a point.
        let radius = distanceField(s, ["RAD", "RADIUS"])
        if (name == "POINT" || name == "APOINT") && radius != nil {
            builder.setShape("CIRCLE", authoritative: false)
        } else {
            builder.setShape(name, authoritative: false)
        }

        if name == "CIRCLE" || name == "RADARC" || radius != nil {
            if let first = coords.first { builder.center = first }
        } else {
            builder.coords.append(contentsOf: coords)
        }

        if name == "RADARC" {
            collectRadarc(s, coords)
            return
        }

        if let radius { builder.radiusM = radius }

        var width = distanceField(s, ["WIDTH", "WID"])
        if width == nil { width = firstDistance(s, coords) }
        if ["CORRIDOR", "TRACK", "ROUTE", "ORBIT", "AORBIT"].contains(name), let width {
            builder.widthM = width
        } else if name == "CIRCLE", builder.radiusM == nil, let width {
            builder.radiusM = width
        }

        if name == "POLYARC" {
            warn("POLYARC arc segments are not modelled; treated as a polygon", s)
        }
    }

    /// `RADARC/<centre>/<inner>/<outer>/<begin>/<end>//`, tolerantly read.
    private func collectRadarc(_ s: ACOSetLine, _ coords: [ACOCoordinate]) {
        var distances: [Double] = []
        var bearings: [Double] = []
        let skip = coords.first?.raw ?? ""

        for f in s.fields {
            let token = ACOPy.strip(f.raw)
            if token.isEmpty || (!skip.isEmpty && token.contains(skip)) { continue }
            if Self.positionQualifiers.contains((f.qualifier ?? "").uppercased()) { continue }
            let d = Self.parseDistance(token)
            let b = Self.parseBearing(token)
            // A bare number is a bearing; anything carrying a unit is a distance.
            if let b, d == nil || !token.contains(where: { $0.isLetter }) {
                bearings.append(b)
            } else if let d {
                distances.append(d)
            }
        }

        if let outer = distances.max() {
            builder.radiusM = outer
            if distances.count > 1 { builder.innerRadiusM = distances.min() }
        }
        builder.bearings = bearings
    }

    private func positions(_ s: ACOSetLine) -> [ACOCoordinate] {
        ACOCoordinates.findPositions(s.raw).filter { $0.isValid() }
    }

    /// `LATLONG/…//` or `GRID/…//` — coordinates with no shape of their own.
    private func collectPositions(_ s: ACOSetLine) {
        let coords = positions(s)
        guard !coords.isEmpty else {
            warn("No readable position in the set", s)
            return
        }
        builder.coords.append(contentsOf: coords)
    }

    /// Value of the first field with one of these qualifiers, in metres.
    private func distanceField(_ s: ACOSetLine, _ qualifiers: Set<String>) -> Double? {
        for f in s.fields where qualifiers.contains((f.qualifier ?? "").uppercased()) {
            return Self.parseDistance(ACOPy.strip(f.raw))
        }
        return nil
    }

    /// First field that reads as a distance, ignoring the position fields.
    private func firstDistance(_ s: ACOSetLine, _ coords: [ACOCoordinate]) -> Double? {
        let raws = coords.map(\.raw)
        for f in s.fields {
            let token = ACOPy.strip(f.raw)
            if token.isEmpty || raws.contains(where: { !$0.isEmpty && token.contains($0) }) { continue }
            if Self.positionQualifiers.contains((f.qualifier ?? "").uppercased()) { continue }
            if let value = Self.parseDistance(token), value > 0 { return value }
        }
        return nil
    }

    // MARK: - Bookkeeping

    private func flush() {
        guard var air = current else { return }

        let (geometry, notes) = builder.build()
        air.geometry = geometry

        if !air.isNil {
            let anchor = air.sets.first
            let label = air.name.isEmpty ? "<unnamed>" : air.name
            for note in notes { warn("[\(label)] \(note)", anchor) }
            if geometry == nil && notes.isEmpty { warn("Airspace '\(label)' has no geometry", anchor) }
        }

        doc.airspaces.append(air)
        current = nil
        builder = ACOShapeBuilder()
    }

    private func warn(_ message: String, _ s: ACOSetLine? = nil) {
        doc.warnings.append(ACOParseWarning(message: message, line: s?.line ?? 0, setName: s?.name, raw: s?.raw ?? ""))
    }
}
