import Foundation
import CoreLocation

// MARK: - MGRS → WGS84 converter
// Supports standard MGRS strings: e.g. "33VXF1234567890" or "33V XF 12345 67890"
// Uses the WGS84 ellipsoid and standard UTM projection.

enum MGRSConverter {

    // MARK: - WGS84 → MGRS (1m precision = 5+5 digits)

    static func fromCoordinate(_ coord: CLLocationCoordinate2D, precision: Int = 5) -> String? {
        let lat = coord.latitude
        let lon = coord.longitude
        guard lat >= -80, lat <= 84, lon >= -180, lon <= 180 else { return nil }

        // UTM zone
        let zoneNum = Int((lon + 180) / 6) + 1
        let isNorth = lat >= 0

        guard let (easting, northing) = latLonToUTM(lat: lat, lon: lon, zone: zoneNum) else { return nil }

        // Band letter
        let bandLetters: [Character] = ["C","D","E","F","G","H","J","K","L","M",
                                        "N","P","Q","R","S","T","U","V","W","X"]
        let bandIdx = max(0, min(Int((lat + 80) / 8), 19))
        let band = bandLetters[bandIdx]

        // 100km column letter (sq1)
        let setNum = (zoneNum - 1) % 3
        let colSets: [[Character]] = [
            ["A","B","C","D","E","F","G","H"],
            ["J","K","L","M","N","P","Q","R"],
            ["S","T","U","V","W","X","Y","Z"]
        ]
        let colIdx = Int(easting / 100_000) - 1   // 1-based column → 0-based index
        guard colIdx >= 0 && colIdx < 8 else { return nil }
        let sq1 = colSets[setNum][colIdx]

        // 100km row letter (sq2)
        let rowLetters: [Character] = ["A","B","C","D","E","F","G","H","J","K",
                                       "L","M","N","P","Q","R","S","T","U","V"]
        let rowOffset = (zoneNum % 2 == 0) ? 5 : 0
        let rowIdx = (Int(northing / 100_000) + rowOffset) % 20
        let sq2 = rowLetters[rowIdx]

        // Numeric part: easting and northing within 100km square, zero-padded to `precision` digits
        let e = Int(easting.truncatingRemainder(dividingBy: 100_000))
        let n = Int(northing.truncatingRemainder(dividingBy: 100_000))
        let fmt = "%0\(precision)d"
        let eStr = String(format: fmt, e / Int(pow(10.0, Double(5 - precision))))
        let nStr = String(format: fmt, n / Int(pow(10.0, Double(5 - precision))))

        return "\(zoneNum)\(band)\(sq1)\(sq2)\(eStr)\(nStr)"
    }

    private static func latLonToUTM(lat: Double, lon: Double, zone: Int) -> (easting: Double, northing: Double)? {
        let a  = 6_378_137.0
        let f  = 1.0 / 298.257_223_563
        let b  = a * (1 - f)
        let e2 = 1 - (b * b) / (a * a)
        let k0 = 0.9996

        let latR = lat * .pi / 180
        let lonR = lon * .pi / 180
        let lon0 = Double(zone * 6 - 183) * .pi / 180

        let N = a / sqrt(1 - e2 * sin(latR) * sin(latR))
        let T = tan(latR) * tan(latR)
        let C = e2 / (1 - e2) * cos(latR) * cos(latR)
        let A = cos(latR) * (lonR - lon0)

        let e4 = e2 * e2; let e6 = e4 * e2
        let M = a * ((1 - e2/4 - 3*e4/64 - 5*e6/256) * latR
                   - (3*e2/8 + 3*e4/32 + 45*e6/1024) * sin(2*latR)
                   + (15*e4/256 + 45*e6/1024) * sin(4*latR)
                   - (35*e6/3072) * sin(6*latR))

        let easting = k0 * N * (A + (1 - T + C) * A*A*A/6
            + (5 - 18*T + T*T + 72*C - 58*e2/(1-e2)) * A*A*A*A*A/120) + 500_000

        var northing = k0 * (M + N * tan(latR) * (A*A/2
            + (5 - T + 9*C + 4*C*C) * A*A*A*A/24
            + (61 - 58*T + T*T + 600*C - 330*e2/(1-e2)) * A*A*A*A*A*A/720))
        if lat < 0 { northing += 10_000_000 }

        return (easting, northing)
    }

    // MARK: - MGRS → WGS84

    /// Converts an MGRS string to WGS84 lat/lon. Returns nil if the string is invalid.
    static func toCoordinate(_ raw: String) -> CLLocationCoordinate2D? {
        let s = raw.trimmingCharacters(in: .whitespaces)
                   .replacingOccurrences(of: " ", with: "")
                   .uppercased()

        // Minimum: zone digits + band letter + 2 square letters = 4 chars before digits
        // e.g. "33VXF" = 5 chars prefix, then even-length digit string (0–10 digits each axis)
        guard s.count >= 5 else { return nil }

        // Split zone number (1-2 digits) + band letter (C-X) + 100km square (2 letters) + digits
        var idx = s.startIndex
        // Zone number: 1 or 2 digits
        var zoneEnd = idx
        var zoneDigits = 0
        while zoneEnd < s.endIndex && s[zoneEnd].isNumber && zoneDigits < 2 {
            zoneEnd = s.index(after: zoneEnd)
            zoneDigits += 1
        }
        guard zoneDigits >= 1, let zoneNum = Int(s[idx..<zoneEnd]) else { return nil }
        idx = zoneEnd

        // Band letter
        guard idx < s.endIndex, let band = s[idx].asciiValue else { return nil }
        let bandChar = s[idx]
        idx = s.index(after: idx)

        // 100km square: 2 letters
        guard s.distance(from: idx, to: s.endIndex) >= 2 else { return nil }
        let sq1 = s[idx]
        idx = s.index(after: idx)
        let sq2 = s[idx]
        idx = s.index(after: idx)

        // Remaining digits: split evenly between easting and northing
        let digits = String(s[idx...])
        guard digits.count % 2 == 0 else { return nil }
        let halfLen = digits.count / 2
        let eastingStr  = String(digits.prefix(halfLen))
        let northingStr = String(digits.suffix(halfLen))

        // Precision: 1m = 5 digits, 10m = 4 digits, etc.
        let multiplier = pow(10.0, Double(5 - halfLen))
        guard let eRaw = Double(eastingStr), let nRaw = Double(northingStr) else { return halfLen == 0 ? approxFromSquare(zoneNum: zoneNum, bandChar: bandChar, sq1: sq1, sq2: sq2) : nil }

        let easting  = eRaw * multiplier + multiplier / 2   // centre of cell
        let northing = nRaw * multiplier + multiplier / 2

        return mgrsToLatLon(zoneNum: zoneNum, bandChar: bandChar, sq1: sq1, sq2: sq2,
                            easting: easting, northing: northing)
    }

    // MARK: - MGRS square → UTM easting/northing

    private static func mgrsToLatLon(zoneNum: Int, bandChar: Character,
                                     sq1: Character, sq2: Character,
                                     easting: Double, northing: Double) -> CLLocationCoordinate2D? {
        // Column letters (sq1): set depends on zone number mod 3
        // Row letters (sq2): set depends on zone number mod 2
        let col100 = columnOffset(sq1: sq1, zoneNum: zoneNum)
        guard let col100 else { return nil }
        let row100 = rowOffset(sq2: sq2, zoneNum: zoneNum)
        guard let row100 else { return nil }

        let utmEasting  = col100 * 100_000 + easting
        let utmNorthing = northingForBand(row100: row100, bandChar: bandChar, zoneNum: zoneNum, rawNorthing: northing)

        let isNorth = bandChar >= "N"
        return utmToLatLon(zone: zoneNum, isNorth: isNorth,
                           easting: utmEasting, northing: utmNorthing)
    }

    // Square col letter → column index (1-8), false easting = index * 100000
    // The column letter set cycles A-H / J-R / S-Z per zone mod 3
    private static func columnOffset(sq1: Character, zoneNum: Int) -> Double? {
        let setNum = (zoneNum - 1) % 3
        let sets: [[Character]] = [
            ["A","B","C","D","E","F","G","H"],
            ["J","K","L","M","N","P","Q","R"],
            ["S","T","U","V","W","X","Y","Z"]
        ]
        let set = sets[setNum]
        guard let idx = set.firstIndex(of: sq1) else { return nil }
        return Double(idx + 1)  // 1-based
    }

    // Square row letter → northing index within 2M-metre repeat cycle
    // Row letters A-V (skipping I and O) cycle per zone parity
    private static func rowOffset(sq2: Character, zoneNum: Int) -> Double? {
        // Letters used: A B C D E F G H J K L M N P Q R S T U V (20 letters, skip I & O)
        let allRows: [Character] = ["A","B","C","D","E","F","G","H","J","K",
                                    "L","M","N","P","Q","R","S","T","U","V"]
        // Odd zones start at A, even zones start at F (index 5)
        let offset = (zoneNum % 2 == 0) ? 5 : 0
        guard let rawIdx = allRows.firstIndex(of: sq2) else { return nil }
        let idx = (rawIdx + (20 - offset)) % 20
        return Double(idx)   // 0-based; northing = idx * 100000
    }

    // Determine the actual northing within the UTM zone band
    // Row index cycles every 2,000,000 m; pick the one inside the band.
    private static func northingForBand(row100: Double, bandChar: Character,
                                        zoneNum: Int, rawNorthing: Double) -> Double {
        let baseN = row100 * 100_000 + rawNorthing  // within 2M cycle
        // Each MGRS band is ~8° tall; approximate band minimum northing
        let bandMinLat = bandMinLatitude(bandChar)
        // Convert band min lat to approximate UTM northing
        let isNorth = bandChar >= "N"
        let approxMinN: Double
        if isNorth {
            approxMinN = latToUTMNorthing(lat: bandMinLat)
        } else {
            approxMinN = 10_000_000 + latToUTMNorthing(lat: bandMinLat)  // southern hemisphere offset
        }
        // Add enough 2M cycles to get above the band minimum
        var n = baseN
        while n < approxMinN - 100_000 { n += 2_000_000 }
        while n > approxMinN + 900_000 { n -= 2_000_000 }
        return n
    }

    private static func bandMinLatitude(_ c: Character) -> Double {
        // C=-80, D=-72, E=-64 ... N=0, P=8 ... X=72 (X is 12° wide)
        let bands: [Character] = ["C","D","E","F","G","H","J","K","L","M",
                                  "N","P","Q","R","S","T","U","V","W","X"]
        guard let i = bands.firstIndex(of: c) else { return 0 }
        return -80.0 + Double(i) * 8.0
    }

    private static func latToUTMNorthing(lat: Double) -> Double {
        // Approximate: 1° latitude ≈ 110574 m
        return lat * 110_574
    }

    // Approximate centre of a 100km square when no digit precision given
    private static func approxFromSquare(zoneNum: Int, bandChar: Character,
                                         sq1: Character, sq2: Character) -> CLLocationCoordinate2D? {
        return mgrsToLatLon(zoneNum: zoneNum, bandChar: bandChar, sq1: sq1, sq2: sq2,
                            easting: 50_000, northing: 50_000)
    }

    // MARK: - UTM → WGS84

    private static func utmToLatLon(zone: Int, isNorth: Bool,
                                    easting: Double, northing: Double) -> CLLocationCoordinate2D? {
        // WGS84 ellipsoid constants
        let a  = 6_378_137.0
        let f  = 1.0 / 298.257_223_563
        let b  = a * (1 - f)
        let e2 = 1 - (b * b) / (a * a)
        let e  = sqrt(e2)
        let k0 = 0.9996

        let x = easting - 500_000.0
        let y = isNorth ? northing : northing - 10_000_000.0

        let M  = y / k0
        let mu = M / (a * (1 - e2/4 - 3*e2*e2/64 - 5*e2*e2*e2/256))

        let e1 = (1 - sqrt(1 - e2)) / (1 + sqrt(1 - e2))
        let phi1 = mu
            + (3*e1/2 - 27*e1*e1*e1/32) * sin(2*mu)
            + (21*e1*e1/16 - 55*e1*e1*e1*e1/32) * sin(4*mu)
            + (151*e1*e1*e1/96) * sin(6*mu)
            + (1097*e1*e1*e1*e1/512) * sin(8*mu)

        let N1  = a / sqrt(1 - e2 * sin(phi1)*sin(phi1))
        let T1  = tan(phi1)*tan(phi1)
        let C1  = e2 / (1 - e2) * cos(phi1)*cos(phi1)
        let R1  = a * (1 - e2) / pow(1 - e2*sin(phi1)*sin(phi1), 1.5)
        let D   = x / (N1 * k0)

        let lat = phi1
            - (N1 * tan(phi1) / R1)
            * (D*D/2
               - (5 + 3*T1 + 10*C1 - 4*C1*C1 - 9*e2/(1-e2)) * D*D*D*D/24
               + (61 + 90*T1 + 298*C1 + 45*T1*T1 - 252*e2/(1-e2) - 3*C1*C1) * D*D*D*D*D*D/720)

        let lon0 = Double(zone * 6 - 183) * .pi / 180
        let lon = lon0 + (D
            - (1 + 2*T1 + C1) * D*D*D/6
            + (5 - 2*C1 + 28*T1 - 3*C1*C1 + 8*e2/(1-e2) + 24*T1*T1) * D*D*D*D*D/120) / cos(phi1)

        let latDeg = lat * 180 / .pi
        let lonDeg = lon * 180 / .pi
        guard latDeg >= -90, latDeg <= 90, lonDeg >= -180, lonDeg <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: latDeg, longitude: lonDeg)
    }
}
