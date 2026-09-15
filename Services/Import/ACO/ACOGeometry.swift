import Foundation

// Port of acoparse/geometry.py — airspace shapes and their conversion to drawable rings.
// `resolution` is the number of segments in a full circle when approximating curves.

struct ACOGeometry {
    enum Shape {
        case point
        case polyline
        case polygon
        case circle(radiusM: Double)
        /// A centreline with a total width: mitred corners, square ends.
        case corridor(widthM: Double)
        /// A racetrack between two points: like a corridor but with semicircular ends.
        case orbit(widthM: Double)
        /// A sector or annulus, swept clockwise from begin to end bearing.
        case radArc(innerRadiusM: Double, outerRadiusM: Double, beginBearing: Double, endBearing: Double)
    }

    static let defaultResolution = 72
    /// How far a mitred corner may reach, in half-widths, before it is clamped.
    static let miterLimit = 6.5

    /// The defining positions, exactly as they appeared in the source.
    var points: [ACOCoordinate]
    var kind: String
    var shape: Shape

    static func point(_ points: [ACOCoordinate]) -> ACOGeometry {
        ACOGeometry(points: points, kind: "POINT", shape: .point)
    }
    static func polyline(_ points: [ACOCoordinate], kind: String = "LINE") -> ACOGeometry {
        ACOGeometry(points: points, kind: kind, shape: .polyline)
    }
    static func polygon(_ points: [ACOCoordinate]) -> ACOGeometry {
        ACOGeometry(points: points, kind: "POLYGON", shape: .polygon)
    }
    static func circle(_ points: [ACOCoordinate], radiusM: Double) -> ACOGeometry {
        ACOGeometry(points: points, kind: "CIRCLE", shape: .circle(radiusM: radiusM))
    }
    static func corridor(_ points: [ACOCoordinate], widthM: Double) -> ACOGeometry {
        ACOGeometry(points: points, kind: "CORRIDOR", shape: .corridor(widthM: widthM))
    }
    static func orbit(_ points: [ACOCoordinate], widthM: Double) -> ACOGeometry {
        ACOGeometry(points: points, kind: "ORBIT", shape: .orbit(widthM: widthM))
    }
    static func radArc(_ points: [ACOCoordinate], innerRadiusM: Double, outerRadiusM: Double,
                       beginBearing: Double, endBearing: Double) -> ACOGeometry {
        ACOGeometry(points: points, kind: "RADARC",
                    shape: .radArc(innerRadiusM: innerRadiusM, outerRadiusM: outerRadiusM,
                                   beginBearing: beginBearing, endBearing: endBearing))
    }

    /// Closed rings, exterior first. Empty for non-area geometries.
    func rings(resolution: Int = ACOGeometry.defaultResolution) -> [[ACOLatLon]] {
        let valid = points.filter { $0.isValid() }.map(\.latLon)
        switch shape {
        case .point, .polyline:
            return []

        case .polygon:
            return valid.count < 3 ? [] : [Self.close(valid)]

        case .circle(let radiusM):
            guard let center = points.first, radiusM > 0 else { return [] }
            return [Self.close(Self.arc(center.latLon, radiusM, 0.0, 360.0, resolution, clockwise: true))]

        case .corridor(let widthM):
            guard valid.count >= 2, widthM > 0 else { return [] }
            return Self.bufferPolyline(valid, widthM / 2.0, resolution)

        case .orbit(let widthM):
            guard valid.count >= 2, widthM > 0 else { return [] }
            return Self.bufferPolyline(valid, widthM / 2.0, resolution, roundCap: true)

        case .radArc(let inner, let outer, let begin, let end):
            guard let center = points.first, outer > 0 else { return [] }
            let origin = center.latLon
            if abs(ACOPy.mod(end - begin, 360.0)) < 1e-9 {
                let outerRing = Self.close(Self.arc(origin, outer, 0.0, 360.0, resolution, clockwise: true))
                if inner > 0 {
                    let innerRing = Self.close(Self.arc(origin, inner, 0.0, 360.0, resolution, clockwise: false))
                    return [outerRing, innerRing]
                }
                return [outerRing]
            }
            let outerArc = Self.arc(origin, outer, begin, end, resolution, clockwise: true)
            if inner > 0 {
                let innerArc = Self.arc(origin, inner, end, begin, resolution, clockwise: false)
                return [Self.close(outerArc + innerArc)]
            }
            return [Self.close([origin] + outerArc)]
        }
    }

    // MARK: - Curve and buffer helpers

    /// Repeat the first vertex at the end, as GeoJSON and KML both require.
    static func close(_ ring: [ACOLatLon]) -> [ACOLatLon] {
        guard let first = ring.first, let last = ring.last else { return ring }
        return first == last ? ring : ring + [first]
    }

    /// Signed angular travel from `start` to `end`, in degrees.
    static func sweep(_ start: Double, _ end: Double, clockwise: Bool) -> Double {
        var delta = ACOPy.mod(end - start, 360.0)
        if !clockwise { delta -= 360.0 }
        if delta == 0.0 { delta = clockwise ? 360.0 : -360.0 }
        return delta
    }

    /// Points along a circular arc, inclusive of both ends.
    static func arc(_ origin: ACOLatLon, _ radiusM: Double, _ startBearing: Double, _ endBearing: Double,
                    _ resolution: Int, clockwise: Bool) -> [ACOLatLon] {
        let delta = sweep(startBearing, endBearing, clockwise: clockwise)
        let steps = max(2, ACOPy.round(Double(resolution) * abs(delta) / 360.0))
        return (0...steps).map { i in
            ACOGeo.destination(origin, startBearing + delta * Double(i) / Double(steps), radiusM)
        }
    }

    /// Bearing halfway between two bearings, averaged as unit vectors.
    private static func meanBearing(_ b1: Double, _ b2: Double) -> Double {
        let x = cos(ACOPy.radians(b1)) + cos(ACOPy.radians(b2))
        let y = sin(ACOPy.radians(b1)) + sin(ACOPy.radians(b2))
        return ACOPy.mod(ACOPy.degrees(atan2(y, x)), 360.0)
    }

    /// One offset edge of a centreline, one point per vertex; interior vertices are mitred.
    private static func offsetSide(_ points: [ACOLatLon], _ halfWidthM: Double, _ side: Int,
                                   _ miterLimit: Double) -> [ACOLatLon] {
        let n = points.count
        return points.enumerated().map { i, p in
            if i == 0 {
                let brg = ACOGeo.bearing(points[0], points[1])
                return ACOGeo.destination(p, brg + Double(90 * side), halfWidthM)
            }
            if i == n - 1 {
                let brg = ACOGeo.bearing(points[n - 2], points[n - 1])
                return ACOGeo.destination(p, brg + Double(90 * side), halfWidthM)
            }
            let bIn = ACOGeo.bearing(points[i - 1], p)
            let bOut = ACOGeo.bearing(p, points[i + 1])
            let turn = ACOPy.mod(bOut - bIn + 180.0, 360.0) - 180.0
            let cosHalf = cos(ACOPy.radians(abs(turn) / 2.0))
            var reach = cosHalf > 1e-6 ? halfWidthM / cosHalf : Double.infinity
            reach = min(reach, halfWidthM * miterLimit)
            return ACOGeo.destination(p, meanBearing(bIn, bOut) + Double(90 * side), reach)
        }
    }

    /// Widen a centreline into a closed ring. Flat caps by default, round for an orbit.
    static func bufferPolyline(_ points: [ACOLatLon], _ halfWidthM: Double, _ resolution: Int,
                               roundCap: Bool = false, miterLimit: Double = ACOGeometry.miterLimit) -> [[ACOLatLon]] {
        let pts = dedupe(points)
        guard pts.count >= 2, halfWidthM > 0 else { return [] }

        let lefts = offsetSide(pts, halfWidthM, -1, miterLimit)
        let rights = offsetSide(pts, halfWidthM, +1, miterLimit)

        var startCap: [ACOLatLon] = []
        var endCap: [ACOLatLon] = []
        if roundCap {
            let first = ACOGeo.bearing(pts[0], pts[1])
            let last = ACOGeo.bearing(pts[pts.count - 2], pts[pts.count - 1])
            endCap = Array(arc(pts[pts.count - 1], halfWidthM, last - 90, last + 90, resolution, clockwise: true)
                .dropFirst().dropLast())
            startCap = Array(arc(pts[0], halfWidthM, first + 90, first - 90, resolution, clockwise: true)
                .dropFirst().dropLast())
        }

        let ring = lefts + endCap + Array(rights.reversed()) + startCap
        return [close(ensureCCW(ring))]
    }

    /// Drop consecutive duplicates, which would make bearings undefined.
    private static func dedupe(_ points: [ACOLatLon]) -> [ACOLatLon] {
        var out: [ACOLatLon] = []
        for p in points where out.isEmpty || ACOGeo.distance(out[out.count - 1], p) > 0.5 {
            out.append(p)
        }
        return out
    }

    /// Orient an exterior ring counter-clockwise, per RFC 7946.
    private static func ensureCCW(_ ring: [ACOLatLon]) -> [ACOLatLon] {
        var total = 0.0
        for i in ring.indices {
            let p1 = ring[i], p2 = ring[(i + 1) % ring.count]
            total += (p2.lon - p1.lon) * (p2.lat + p1.lat)
        }
        return total > 0 ? Array(ring.reversed()) : ring
    }
}
