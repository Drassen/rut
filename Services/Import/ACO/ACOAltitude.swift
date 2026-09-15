import Foundation

// Port of acoparse/altitude.py — vertical limits from EFFLEVEL and ALT sets.
// Numeric EFFLEVEL altitudes are hundreds of feet (005GND = 500 ft AGL); ALT/LOW:/HIGH: are whole feet.

/// One end of a vertical extent.
struct ACOAltitude {
    let raw: String
    /// `RA` (reference altitude), `FL` (flight level) or `UNKNOWN`.
    var kind: String = "UNKNOWN"
    /// The number exactly as written, before any unit scaling.
    var value: Double? = nil
    /// `AMSL`, `AGL`, … or nil for flight levels.
    var datum: String? = nil
    var unlimited: Bool = false
    /// Feet per unit of `value`. Flight levels always use 100.
    var scaleFt: Double = 100.0

    /// Altitude in feet, or nil when unlimited or unparseable. Not datum-corrected.
    var feet: Double? {
        guard !unlimited, let value else { return nil }
        return kind == "FL" ? value * 100.0 : value * scaleFt
    }
}

/// The floor/ceiling pair of an airspace.
struct ACOVerticalExtent {
    var lower: ACOAltitude? = nil
    var upper: ACOAltitude? = nil
    /// The four-letter qualifier, e.g. `RARA` or `RAFL`.
    var qualifier: String? = nil
    var raw: String = ""

    var lowerFt: Double? { lower?.feet }
    var upperFt: Double? { upper?.feet }
}

enum ACOAltitudeParser {
    /// Whether a bare numeric EFFLEVEL altitude is hundreds of feet (USMTF).
    static let hundredsOfFeet = true
    /// Feet per unit in an `ALT/LOW:…/HIGH:…` set.
    static let altSetScaleFt = 1.0
    static let feetPerMetre = 3.280839895

    private static let surface: Set<String> = ["SFC", "GND", "SURFACE", "GROUND"]
    private static let unlimited: Set<String> = ["UNL", "UNLTD", "UNLIM", "UNLIMITED"]
    private static let datums: Set<String> = ["AMSL", "AGL", "MSL", "GND", "SFC", "HAE", "BRL"]

    /// Units that override the scale convention, longest first (as the reference sorts them).
    private static let unitsFt: [(unit: String, feet: Double)] = [
        ("METERS", feetPerMetre), ("METRES", feetPerMetre), ("METER", feetPerMetre), ("METRE", feetPerMetre),
        ("FEET", 1.0), ("MTRS", feetPerMetre), ("MTR", feetPerMetre), ("FT", 1.0), ("M", feetPerMetre),
    ]

    private static let numeric = ACORegex(#"^(?<num>\d+(?:\.\d+)?)\s*(?<datum>[A-Z]*)$"#)
    private static let flightLevel = ACORegex(#"^FL\s*(?<num>\d+)$"#)
    private static let whitespace = ACORegex(#"\s+"#)

    /// Decode a single altitude token such as `005GND`, `FL660` or `UNL`.
    static func parseAltitude(_ token: String, kindHint: String? = nil, scaleFt: Double? = nil) -> ACOAltitude {
        var scale = scaleFt ?? (hundredsOfFeet ? 100.0 : 1.0)
        let hint = kindHint.flatMap { $0.isEmpty ? nil : $0 }
        let raw = ACOPy.strip(token)
        // "2000ft AGL" and "FL 65" mean what "2000FTAGL" and "FL65" mean.
        let upper = whitespace.replacing(in: raw.uppercased(), with: "")
        if upper.isEmpty { return ACOAltitude(raw: raw) }

        if unlimited.contains(upper) {
            return ACOAltitude(raw: raw, kind: hint ?? "RA", unlimited: true, scaleFt: scale)
        }
        if surface.contains(upper) {
            return ACOAltitude(raw: raw, kind: "RA", value: 0.0, datum: "AGL", scaleFt: scale)
        }
        if let fl = flightLevel.firstMatch(in: upper), let number = Double(fl["num"]!) {
            return ACOAltitude(raw: raw, kind: "FL", value: number, scaleFt: 100.0)
        }
        if let m = numeric.firstMatch(in: upper), let number = Double(m["num"]!) {
            var (unitFt, datum) = splitUnit(m["datum"] ?? "")
            if let unitFt { scale = unitFt }
            if datum == "GND" || datum == "SFC" {
                datum = "AGL"
            } else if datum == "MSL" {
                datum = "AMSL"
            }
            return ACOAltitude(raw: raw, kind: hint ?? "RA", value: number,
                               datum: datum.isEmpty ? nil : datum, scaleFt: scale)
        }
        return ACOAltitude(raw: raw, kind: hint ?? "UNKNOWN", scaleFt: scale)
    }

    /// Split an altitude's trailing letters into an optional unit and a datum.
    private static func splitUnit(_ suffix: String) -> (Double?, String) {
        if suffix.isEmpty || datums.contains(suffix) { return (nil, suffix) }
        for (unit, feet) in unitsFt where suffix.hasPrefix(unit) {
            let rest = String(suffix.dropFirst(unit.count))
            if rest.isEmpty || datums.contains(rest) { return (feet, rest) }
        }
        return (nil, suffix)
    }

    /// Decode the `<lower>-<upper>` body of an EFFLEVEL field.
    static func parseEfflevelValue(qualifier: String?, value: String) -> ACOVerticalExtent {
        let upperQualifier = (qualifier ?? "").uppercased()
        let qual: String? = upperQualifier.isEmpty ? nil : upperQualifier
        let lowerHint = qual.flatMap { $0.count == 4 ? String($0.prefix(2)) : nil }
        let upperHint = qual.flatMap { $0.count == 4 ? String($0.dropFirst(2)) : nil }

        let body = ACOPy.strip(value)
        let (lowerText, separated, upperText) = splitRange(body)
        guard separated else {
            return ACOVerticalExtent(lower: parseAltitude(body, kindHint: lowerHint), upper: nil,
                                     qualifier: qual, raw: body)
        }
        return ACOVerticalExtent(lower: parseAltitude(lowerText, kindHint: lowerHint),
                                 upper: parseAltitude(upperText, kindHint: upperHint),
                                 qualifier: qual, raw: body)
    }

    /// Build an extent from two separately written altitudes.
    static func makeExtent(lower: String?, upper: String?, scaleFt: Double, raw: String = "") -> ACOVerticalExtent {
        let lowerText = lower.flatMap { $0.isEmpty ? nil : $0 }
        let upperText = upper.flatMap { $0.isEmpty ? nil : $0 }
        return ACOVerticalExtent(
            lower: lowerText.map { parseAltitude($0, scaleFt: scaleFt) },
            upper: upperText.map { parseAltitude($0, scaleFt: scaleFt) },
            qualifier: nil,
            raw: raw.isEmpty ? [lowerText, upperText].compactMap { $0 }.joined(separator: " - ") : raw
        )
    }

    /// Split on the `-` that separates floor from ceiling (not one that starts a negative number).
    private static func splitRange(_ body: String) -> (String, Bool, String) {
        let chars = Array(body)
        guard chars.count > 1 else { return (body, false, "") }
        for i in 1..<chars.count where chars[i] == "-" && chars[i - 1] != "-" && chars[i - 1] != ":" {
            return (String(chars[..<i]), true, String(chars[(i + 1)...]))
        }
        return (body, false, "")
    }
}
