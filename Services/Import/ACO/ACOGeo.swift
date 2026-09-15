import Foundation

// Port of acoparse/geo.py — spherical-earth helpers (sphere of radius EARTH_RADIUS_M).

enum ACOGeo {
    static let earthRadiusM = 6371008.8

    /// Great-circle distance in metres between two points.
    static func distance(_ a: ACOLatLon, _ b: ACOLatLon) -> Double {
        let lat1 = ACOPy.radians(a.lat), lon1 = ACOPy.radians(a.lon)
        let lat2 = ACOPy.radians(b.lat), lon2 = ACOPy.radians(b.lon)
        let dlat = lat2 - lat1
        let dlon = lon2 - lon1
        let h = pow(sin(dlat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dlon / 2), 2)
        return 2 * earthRadiusM * asin(sqrt(h))
    }

    /// Initial true bearing in degrees (0–360) from `a` to `b`.
    static func bearing(_ a: ACOLatLon, _ b: ACOLatLon) -> Double {
        let lat1 = ACOPy.radians(a.lat), lat2 = ACOPy.radians(b.lat)
        let dlon = ACOPy.radians(b.lon - a.lon)
        let y = sin(dlon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon)
        return ACOPy.mod(ACOPy.degrees(atan2(y, x)), 360.0)
    }

    /// Point reached by travelling `distanceM` from `origin` on a bearing.
    static func destination(_ origin: ACOLatLon, _ bearingDeg: Double, _ distanceM: Double) -> ACOLatLon {
        let lat1 = ACOPy.radians(origin.lat), lon1 = ACOPy.radians(origin.lon)
        let brg = ACOPy.radians(bearingDeg)
        let ang = distanceM / earthRadiusM

        let lat2 = asin(sin(lat1) * cos(ang) + cos(lat1) * sin(ang) * cos(brg))
        let lon2 = lon1 + atan2(sin(brg) * sin(ang) * cos(lat1), cos(ang) - sin(lat1) * sin(lat2))
        return ACOLatLon(lat: ACOPy.degrees(lat2), lon: ACOPy.mod(ACOPy.degrees(lon2) + 540, 360) - 180)
    }
}
