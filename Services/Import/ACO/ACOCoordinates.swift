import Foundation

// Port of acoparse/coordinates.py — the position formats that appear inside ACO sets.

struct ACOLatLon: Equatable {
    var lat: Double
    var lon: Double
}

/// A geographic position in decimal degrees, WGS84.
struct ACOCoordinate {
    var lat: Double
    var lon: Double
    /// The source text this was decoded from.
    var raw: String = ""

    var latLon: ACOLatLon { ACOLatLon(lat: lat, lon: lon) }

    func isValid() -> Bool { lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 }
}

enum ACOCoordinates {
    // 574141N0135112E and its coarser, finer and decimal relatives.
    private static let latLonPattern = ACORegex(
        #"(?<lat>\d{1,7})(?:\.(?<latf>\d+))?(?<lah>[NS])\s*(?<lon>\d{1,7})(?:\.(?<lonf>\d+))?(?<loh>[EW])"#)

    /// How to slice a run of digits into degrees, minutes and seconds.
    private static let layouts: [Int: (d: Int, m: Int, s: Int)] = [
        4: (2, 2, 0),  // DDMM
        5: (3, 2, 0),  // DDDMM
        6: (2, 2, 2),  // DDMMSS
        7: (3, 2, 2),  // DDDMMSS
    ]

    private static let spaced = ACORegex(#"\d[\d\s]*\d\s*[NS]"#)
    private static let spacesAndTabs = ACORegex(#"[ \t]+"#)
    private static let gridSeparators = ACORegex(#"[/,]"#)

    /// A run of digits plus a hemisphere letter to decimal degrees. Up to three digits is
    /// already a decimal degree; four or more packs degrees, minutes and maybe seconds.
    static func decode(_ digits: String, _ frac: String?, _ hemisphere: String) -> Double? {
        let negative = hemisphere == "S" || hemisphere == "W"
        let chars = Array(digits)

        if chars.count <= 3 {
            guard let value = Double(frac.map { "\(digits).\($0)" } ?? digits) else { return nil }
            return negative ? -value : value
        }

        guard let layout = layouts[chars.count] else { return nil }
        let (d, m, s) = layout
        let minutesText = String(chars[d..<(d + m)])
        guard let degrees = Int(String(chars[0..<d])), let minutes = Int(minutesText) else { return nil }

        var value = Double(degrees) + Double(minutes) / 60.0
        if s > 0 {
            let secondsText = String(chars[(d + m)...])
            guard let seconds = Double(frac.map { "\(secondsText).\($0)" } ?? secondsText) else { return nil }
            value += seconds / 3600.0
        } else if let frac {
            // No seconds field, so the fraction belongs to the minutes.
            guard let fractionalMinutes = Double("\(minutesText).\(frac)") else { return nil }
            value = Double(degrees) + fractionalMinutes / 60.0
        }
        return negative ? -value : value
    }

    private static func fromMatch(_ m: ACORegex.Match) -> ACOCoordinate? {
        guard let lat = decode(m["lat"]!, m["latf"], m["lah"]!),
              let lon = decode(m["lon"]!, m["lonf"], m["loh"]!) else { return nil }
        return ACOCoordinate(lat: lat, lon: lon, raw: m.text)
    }

    /// Every lat/long pair in `text`, in the order they appear.
    static func findCoordinates(_ text: String) -> [ACOCoordinate] {
        latLonPattern.matches(in: text).compactMap(fromMatch)
    }

    /// A single MGRS grid reference, or nil if it is not one.
    static func parseGridRef(_ token: String) -> ACOCoordinate? {
        guard let result = ACOMGRS.toLatLon(token) else { return nil }
        return ACOCoordinate(lat: result.lat, lon: result.lon, raw: ACOPy.strip(token))
    }

    /// Every MGRS grid reference among the `/`-separated tokens of `text`.
    static func findGridRefs(_ text: String) -> [ACOCoordinate] {
        gridSeparators.split(text).compactMap { piece in
            var token = ACOPy.strip(piece)
            if token.contains(":") { token = ACOPy.strip(ACOPy.partition(token, ":").tail) }
            return parseGridRef(token)
        }
    }

    /// Every position in `text`: lat/long, then spaced lat/long, then MGRS.
    static func findPositions(_ text: String) -> [ACOCoordinate] {
        let coords = findCoordinates(text)
        if !coords.isEmpty { return coords }

        if spaced.contains(text) {
            let squeezed = findCoordinates(spacesAndTabs.replacing(in: text, with: ""))
            if !squeezed.isEmpty { return squeezed }
        }
        return findGridRefs(text)
    }
}
