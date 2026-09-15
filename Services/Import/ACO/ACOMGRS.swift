import Foundation

// Port of acoparse/mgrs.py — MGRS grid references to WGS84 latitude/longitude via the
// standard UTM projection. The returned point is the centre of the square the reference names.

enum ACOMGRS {
    // Grid letters skip I and O throughout, so they cannot be confused with 1 and 0.
    private static let bandLetters = Array("CDEFGHJKLMNPQRSTUVWX")
    private static let columnSets = ["ABCDEFGH", "JKLMNPQR", "STUVWXYZ"].map { Array($0) }
    private static let rowLetters = Array("ABCDEFGHJKLMNPQRSTUV")

    private static let pattern = ACORegex(
        #"^(?<zone>\d{1,2})(?<band>[C-HJ-NP-X])\s*(?<sq>[A-HJ-NP-Z]{2})\s*(?<digits>[\d\s]*)$"#)
    private static let whitespace = ACORegex(#"\s"#)

    // WGS84
    private static let a = 6378137.0
    private static let f = 1.0 / 298.257223563
    private static let e2 = 1 - pow(1 - f, 2)
    private static let k0 = 0.9996

    static func isMGRS(_ text: String) -> Bool { parseParts(text) != nil }

    /// Decode an MGRS reference to (lat, lon), or nil if it is not one.
    static func toLatLon(_ text: String) -> (lat: Double, lon: Double)? {
        guard let p = parseParts(text),
              let column = columnOffset(p.sq1, p.zone),
              let row = rowOffset(p.sq2, p.zone) else { return nil }
        let utmEasting = column * 100_000 + p.easting
        let utmNorthing = northingForBand(row, p.band, p.northing)
        return utmToLatLon(p.zone, p.band >= "N", utmEasting, utmNorthing)
    }

    private static func parseParts(_ text: String)
        -> (zone: Int, band: String, sq1: Character, sq2: Character, easting: Double, northing: Double)? {
        let cleaned = ACOPy.strip(text).uppercased()
        guard let m = pattern.firstMatch(in: cleaned), let zone = Int(m["zone"]!), (1...60).contains(zone) else {
            return nil
        }

        let digits = whitespace.replacing(in: m["digits"] ?? "", with: "")
        guard digits.count % 2 == 0, digits.count <= 10 else { return nil }

        let easting: Double
        let northing: Double
        if digits.isEmpty {
            // No numeric part: the reference names a 100 km square, so take its centre.
            easting = 50_000.0
            northing = 50_000.0
        } else {
            let half = digits.count / 2
            // 5 digits resolve to 1 m, 4 to 10 m, and so on; offset to the cell centre.
            let scale = pow(10.0, Double(5 - half))
            guard let e = Int(digits.prefix(half)), let n = Int(digits.suffix(half)) else { return nil }
            easting = Double(e) * scale + scale / 2
            northing = Double(n) * scale + scale / 2
        }

        let square = Array(m["sq"]!)
        return (zone, m["band"]!, square[0], square[1], easting, northing)
    }

    /// 100 km column index; the letter set cycles every three zones.
    private static func columnOffset(_ sq1: Character, _ zone: Int) -> Double? {
        guard let idx = columnSets[(zone - 1) % 3].firstIndex(of: sq1) else { return nil }
        return Double(idx + 1)
    }

    /// 100 km row index; even zones start five letters further along.
    private static func rowOffset(_ sq2: Character, _ zone: Int) -> Double? {
        guard let idx = rowLetters.firstIndex(of: sq2) else { return nil }
        let offset = zone % 2 == 0 ? 5 : 0
        return Double((idx + (20 - offset)) % 20)
    }

    /// Resolve which 2 000 km cycle the row falls in, using the band letter.
    private static func northingForBand(_ row: Double, _ band: String, _ northing: Double) -> Double {
        var value = row * 100_000 + northing

        let bandIndex = bandLetters.firstIndex(of: Character(band)) ?? -1
        let bandMinLat = -80.0 + Double(bandIndex) * 8.0
        var approxMin = bandMinLat * 110_574
        if band < "N" {
            approxMin += 10_000_000  // southern hemisphere false northing
        }

        while value < approxMin - 100_000 { value += 2_000_000 }
        while value > approxMin + 900_000 { value -= 2_000_000 }
        return value
    }

    /// Inverse transverse Mercator, WGS84.
    private static func utmToLatLon(_ zone: Int, _ northern: Bool, _ easting: Double, _ northing: Double)
        -> (lat: Double, lon: Double)? {
        let x = easting - 500_000.0
        let y = northern ? northing : northing - 10_000_000.0

        let m = y / k0
        let muDenominator = a * (1 - e2 / 4 - 3 * pow(e2, 2) / 64 - 5 * pow(e2, 3) / 256)
        let mu = m / muDenominator

        let e1 = (1 - sqrt(1 - e2)) / (1 + sqrt(1 - e2))
        let phiTerm1 = (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu)
        let phiTerm2 = (21 * pow(e1, 2) / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu)
        let phiTerm3 = (151 * pow(e1, 3) / 96) * sin(6 * mu)
        let phiTerm4 = (1097 * pow(e1, 4) / 512) * sin(8 * mu)
        let phi1 = mu + phiTerm1 + phiTerm2 + phiTerm3 + phiTerm4

        let sinPhi1 = sin(phi1), cosPhi1 = cos(phi1), tanPhi1 = tan(phi1)
        if abs(cosPhi1) < 1e-12 { return nil }

        let n1 = a / sqrt(1 - e2 * pow(sinPhi1, 2))
        let t1 = pow(tanPhi1, 2)
        let c1 = e2 / (1 - e2) * pow(cosPhi1, 2)
        let r1 = a * (1 - e2) / pow(1 - e2 * pow(sinPhi1, 2), 1.5)
        let d = x / (n1 * k0)
        let ep2 = e2 / (1 - e2)

        let latA = pow(d, 2) / 2
        let latB = (5 + 3 * t1 + 10 * c1 - 4 * pow(c1, 2) - 9 * ep2) * pow(d, 4) / 24
        let latC = (61 + 90 * t1 + 298 * c1 + 45 * pow(t1, 2) - 252 * ep2 - 3 * pow(c1, 2)) * pow(d, 6) / 720
        let lat = phi1 - (n1 * tanPhi1 / r1) * (latA - latB + latC)

        let lon0 = ACOPy.radians(Double(zone * 6 - 183))
        let lonB = (1 + 2 * t1 + c1) * pow(d, 3) / 6
        let lonC = (5 - 2 * c1 + 28 * t1 - 3 * pow(c1, 2) + 8 * ep2 + 24 * pow(t1, 2)) * pow(d, 5) / 120
        let lon = lon0 + (d - lonB + lonC) / cosPhi1

        let latDeg = ACOPy.degrees(lat), lonDeg = ACOPy.degrees(lon)
        guard latDeg >= -90, latDeg <= 90, lonDeg >= -180, lonDeg <= 180 else { return nil }
        return (latDeg, lonDeg)
    }
}
