import Foundation

/// Exports the app's vector layers as a Euronav5 USER-database card layer
/// (USERN.tbl + USERN-{ID,LN,OI}.idx under db/SQL/).
///
/// All binary encoding lives in `Euronav5Encoder` (byte-exact port of the
/// verified reference implementation — see `Docs/Euronav5/`). This service
/// only maps the app's `VectorShape` model onto encoder figures.
struct Euronav5ExportService {

    enum Euronav5Layer: Int, CaseIterable {
        case zero = 0
        case one = 1
        case two = 2
        case three = 3
        case four = 4

        var filename: String {
            "USER\(rawValue + 1).tbl"
        }

        var displayName: String {
            "Layer \(rawValue)"
        }
    }

    /// Export all visible shapes of the given layers into a complete
    /// EuroNav5 "UpdateMedia" card: the USER layer file (+ its three index
    /// files), the generic ENMedia.ini / User4.create.sql, the empty support
    /// folders, and a FileTran.tgz snapshot of db/. Empty card if there is
    /// nothing to export. See `Euronav5CardWriter` for the layout.
    func exportEuronav5Card(vectorLayers: [VectorLayer],
                            to layer: Euronav5Layer,
                            date: Date = Date()) -> Euronav5CardWriter.Card {
        var shapes: [VectorShape] = []
        for vectorLayer in vectorLayers {
            collectShapesFlat(from: vectorLayer, into: &shapes)
        }

        // Shape order is the creation-order proxy for the session counter.
        let figures = shapes.compactMap(figure(from:))
        let objectIds = Euronav5Encoder.assignObjectIds(figures)
        guard let files = Euronav5Encoder.exportLayer(
            figures: figures, objectIds: objectIds,
            ts: Euronav5Encoder.Timestamp(date: date)) else {
            return Euronav5CardWriter.Card(files: [:], directories: [])
        }

        let base = "db/SQL/USER\(layer.rawValue + 1)"
        let userFiles: [String: Data] = [
            "\(base).tbl": files.tbl,
            "\(base)-ID.idx": files.idIdx,
            "\(base)-LN.idx": files.lnIdx,
            "\(base)-OI.idx": files.oiIdx,
        ]
        return Euronav5CardWriter.buildCard(userFiles: userFiles, date: date)
    }

    // MARK: - VectorShape -> Figure mapping

    private func figure(from shape: VectorShape) -> Euronav5Encoder.Figure? {
        guard shape.isVisible else { return nil }
        // Zone type is only meaningful for area shapes; plain drawings
        // carry an empty TYPE.
        let type = shape.dmgCategory == .area ? shape.dmgAreaType.rawValue : ""

        switch shape.geometry {
        case .point(let lat, let lon):
            guard let center = microdegrees(lat: lat, lon: lon) else { return nil }
            // A point is a placed object and the planner always assigns it an
            // object template; an empty TYPE point never renders. Fixed to the
            // "POI" template for now (matches APPERANCE 408 default).
            return Euronav5Encoder.Figure(
                kind: .point, name: shape.name, type: "POI", points: [center],
                rangeLethalMeters: meters(shape.dmgRangeLethalMeters),
                rangeDetectionMeters: meters(shape.dmgRangeDetectionMeters),
                elevationMeters: elevationMeters(shape),
                appearanceOverride: appearance(for: shape, kind: .point))

        case .circle(let lat, let lon, let radiusMeters):
            guard microdegrees(lat: lat, lon: lon) != nil,
                  radiusMeters >= 0.5 else { return nil }
            // A single-record circle (RANGEDETECTION radius) does not draw a
            // ring on the helicopter, so tessellate the circle into a polygon
            // ring and use the proven polygon rendering instead.
            let ring = circleRing(lat: lat, lon: lon, radiusMeters: radiusMeters,
                                  segments: 48)
            guard ring.count >= 3 else { return nil }
            return Euronav5Encoder.Figure(
                kind: .polygon, name: shape.name, type: type, points: ring,
                elevationMeters: elevationMeters(shape),
                appearanceOverride: appearance(for: shape, kind: .polygon))

        case .polyline(let coordinates):
            guard let points = microdegrees(coordinates: coordinates) else { return nil }
            // The planner classifies by geometric closure, not by tool:
            // a polyline ending on its first vertex is a closed polygon
            // (negative object id) — observed as "draw4" in set1.
            if points.count > 3, points.first! == points.last! {
                return Euronav5Encoder.Figure(
                    kind: .polygon, name: shape.name, type: type,
                    points: Array(points.dropLast()),
                    appearanceOverride: appearance(for: shape, kind: .polygon))
            }
            guard points.count >= 2 else { return nil }
            return Euronav5Encoder.Figure(
                kind: .line, name: shape.name, type: type, points: points,
                appearanceOverride: appearance(for: shape, kind: .line))

        case .polygon(let coordinates):
            guard var points = microdegrees(coordinates: coordinates) else { return nil }
            if points.count > 1, points.first! == points.last! {
                points.removeLast()  // encoder appends the closing repeat
            }
            guard points.count >= 3 else { return nil }
            return Euronav5Encoder.Figure(
                kind: .polygon, name: shape.name, type: type, points: points,
                elevationMeters: elevationMeters(shape),
                appearanceOverride: appearance(for: shape, kind: .polygon))
        }
    }

    /// APPERANCE (appMatrix style id) for a shape.
    ///
    /// The style the user picked in the style selector wins. Otherwise pick
    /// a default that is actually visible on the EuroNav display — the raw
    /// TYPE-derived planner mapping renders points without any symbol
    /// (FDRAWING has none) and RESTRICTEDZONE as the all-white, disabled
    /// FOPERATION style.
    private func appearance(for shape: VectorShape,
                            kind: Euronav5Encoder.FigureKind) -> Int32? {
        // 0x0000 is the model's "no style chosen" default. (Other legacy
        // KnownStyleClass values are exported verbatim like any pick.)
        let picked = shape.dmgStyleClass.styleClassID
        if picked != 0 {
            return Int32(picked)
        }
        switch kind {
        case .point:
            return 408   // POI — yellow glyph; only symbol styles render points
        case .circle:
            return nil   // circles always carry a zone TYPE; the encoder's
                         // TYPE mapping yields the planner's 802 default
        case .line, .polygon:
            if shape.dmgCategory == .area,
               shape.dmgAreaType == .restrictedZone {
                return 805  // FWARNING (blue) instead of the white FOPERATION
            }
            return nil      // planner-faithful TYPE mapping in the encoder
        }
    }

    /// ELEVATION in metres from the shape's foot-entered altitude.
    private func elevationMeters(_ shape: VectorShape) -> Int32? {
        guard let feet = shape.dmgElevationFeet, feet.isFinite else { return nil }
        return Int32((feet * 0.3048).rounded())
    }

    private func meters(_ value: Double?) -> Int32 {
        guard let value, value.isFinite, value >= 1 else { return 0 }
        return Int32(value.rounded())
    }

    /// Tessellate a geographic circle into a polygon ring of `segments`
    /// vertices (without the closing repeat — the encoder adds it).
    private func circleRing(lat: Double, lon: Double, radiusMeters: Double,
                            segments: Int) -> [(Int32, Int32)] {
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(lat * .pi / 180)
        guard mPerDegLon > 1 else { return [] }   // avoid the poles
        var ring: [(Int32, Int32)] = []
        ring.reserveCapacity(segments)
        for i in 0..<segments {
            let a = 2 * Double.pi * Double(i) / Double(segments)
            let dLat = (radiusMeters * cos(a)) / mPerDegLat
            let dLon = (radiusMeters * sin(a)) / mPerDegLon
            ring.append((Euronav5Encoder.microdegrees(lat + dLat),
                         Euronav5Encoder.microdegrees(lon + dLon)))
        }
        return ring
    }

    private func microdegrees(lat: Double, lon: Double) -> (Int32, Int32)? {
        guard lat.isFinite, lon.isFinite,
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (Euronav5Encoder.microdegrees(lat), Euronav5Encoder.microdegrees(lon))
    }

    private func microdegrees(coordinates: [[Double]]) -> [(Int32, Int32)]? {
        let pts = coordinates.compactMap { pair -> (Int32, Int32)? in
            guard pair.count >= 2 else { return nil }
            return microdegrees(lat: pair[0], lon: pair[1])
        }
        return pts.count == coordinates.count ? pts : nil
    }

    private func collectShapesFlat(from layer: VectorLayer,
                                   into shapes: inout [VectorShape]) {
        shapes.append(contentsOf: layer.shapes)
        for child in layer.children {
            collectShapesFlat(from: child, into: &shapes)
        }
    }
}
