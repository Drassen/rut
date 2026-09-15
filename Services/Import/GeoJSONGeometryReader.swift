import Foundation

// Shared GeoJSON geometry reading for the GeoJSON and SAPI importers. Every part of a
// geometry that cannot be represented as a VectorGeometry is reported, not dropped silently.

enum GeoJSONGeometryReader {

    /// GeoJSON position [lon, lat, (alt)] → [lat, lon]. Altitude is ignored.
    private static func latLon(_ position: [Double]) -> [Double]? {
        guard position.count >= 2 else { return nil }
        return [position[1], position[0]]
    }

    private static func positions(_ raw: [[Double]], label: String, warnings: inout [String]) -> [[Double]] {
        let converted = raw.compactMap(latLon)
        if converted.count < raw.count {
            warnings.append("\(label): \(raw.count - converted.count) position(s) without longitude/latitude ignored")
        }
        return converted
    }

    private static func polygonRing(_ rings: [[[Double]]], label: String, warnings: inout [String]) -> VectorGeometry? {
        guard let outer = rings.first else {
            warnings.append("\(label): polygon without rings; skipped")
            return nil
        }
        if rings.count > 1 {
            warnings.append("\(label): \(rings.count - 1) hole(s) in the polygon not imported")
        }
        let ring = positions(outer, label: label, warnings: &warnings)
        guard ring.count >= 3 else {
            warnings.append("\(label): polygon needs at least 3 positions, has \(ring.count); skipped")
            return nil
        }
        return .polygon(coordinates: ring)
    }

    /// Reads a GeoJSON geometry object. `pointRadiusM` turns a Point into a circle (SAPI).
    static func read(_ geometry: Any?, label: String, pointRadiusM: Double? = nil,
                     warnings: inout [String]) -> VectorGeometry? {
        guard let dict = geometry as? [String: Any], let type = dict["type"] as? String else {
            warnings.append("\(label): no geometry; skipped")
            return nil
        }
        let coordinates = dict["coordinates"]

        switch type {
        case "Point":
            guard let raw = coordinates as? [Double], let p = latLon(raw) else {
                warnings.append("\(label): Point coordinates could not be read; skipped")
                return nil
            }
            if let radius = pointRadiusM { return .circle(lat: p[0], lon: p[1], radiusMeters: radius) }
            return .point(lat: p[0], lon: p[1])

        case "LineString":
            guard let raw = coordinates as? [[Double]] else {
                warnings.append("\(label): LineString coordinates could not be read; skipped")
                return nil
            }
            let line = positions(raw, label: label, warnings: &warnings)
            guard line.count >= 2 else {
                warnings.append("\(label): LineString needs at least 2 positions, has \(line.count); skipped")
                return nil
            }
            return .polyline(coordinates: line)

        case "Polygon":
            guard let rings = coordinates as? [[[Double]]] else {
                warnings.append("\(label): Polygon coordinates could not be read; skipped")
                return nil
            }
            return polygonRing(rings, label: label, warnings: &warnings)

        case "MultiLineString":
            guard let lines = coordinates as? [[[Double]]], let first = lines.first else {
                warnings.append("\(label): MultiLineString coordinates could not be read; skipped")
                return nil
            }
            if lines.count > 1 {
                warnings.append("\(label): MultiLineString with \(lines.count) lines; only the first is imported")
            }
            let line = positions(first, label: label, warnings: &warnings)
            guard line.count >= 2 else {
                warnings.append("\(label): first line needs at least 2 positions, has \(line.count); skipped")
                return nil
            }
            return .polyline(coordinates: line)

        case "MultiPolygon":
            guard let polygons = coordinates as? [[[[Double]]]], let first = polygons.first else {
                warnings.append("\(label): MultiPolygon coordinates could not be read; skipped")
                return nil
            }
            if polygons.count > 1 {
                warnings.append("\(label): MultiPolygon with \(polygons.count) polygons; only the first is imported")
            }
            return polygonRing(first, label: label, warnings: &warnings)

        default:
            warnings.append("\(label): geometry type '\(type)' is not supported; skipped")
            return nil
        }
    }
}
