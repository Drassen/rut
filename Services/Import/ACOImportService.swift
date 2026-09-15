import Foundation

// MARK: - ACOImportService
// Imports USMTF Airspace Coordination Orders (and OpenAir) with the acoparse port in
// Services/Import/ACO. The result is one vector layer with a sub-layer per category,
// styled like acoparse's KML export, plus every parse warning for the import report.

struct ACOImportService: RouteImporting {

    let supportedExtensions = ["aco", "txt"]

    func importDocument(from url: URL) throws -> NavigationDocument {
        try importDocumentWithWarnings(from: url).0
    }

    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String]) {
        let (layer, warnings) = try importLayerWithWarnings(from: url)
        var doc = NavigationDocument()
        if Self.shapeCount(layer) > 0 { doc.vectorLayers = [layer] }
        return (doc, warnings)
    }

    /// Import and return both the layer and the parse warnings, formatted for the import report.
    func importLayerWithWarnings(from url: URL) throws -> (VectorLayer, [String]) {
        let doc = try ACOReader.parseFile(url)
        let name = [doc.exercise, doc.operation].compactMap { $0 }.first { !$0.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent

        // One sub-layer per category, as the reference KML export groups its folders
        var shapesByCategory: [String: [VectorShape]] = [:]
        for airspace in doc.airspaces {
            guard let shape = Self.vectorShape(for: airspace) else { continue }
            shapesByCategory[airspace.category, default: []].append(shape)
        }
        var layer = VectorLayer(name: name)
        layer.children = shapesByCategory.keys.sorted().map { VectorLayer(name: $0, shapes: shapesByCategory[$0]!) }

        let warnings = doc.warnings.map { $0.raw.isEmpty ? $0.description : "\($0.description)\n\($0.raw)" }
        return (layer, warnings)
    }

    func importLayer(from url: URL) throws -> VectorLayer {
        try importLayerWithWarnings(from: url).0
    }

    static func shapeCount(_ layer: VectorLayer) -> Int {
        layer.shapes.count + layer.children.reduce(0) { $0 + shapeCount($1) }
    }

    // MARK: - Airspace → VectorShape

    /// Category colours from acoparse's KML export (KML aabbggrr converted to #RRGGBB).
    private static let categoryColors: [String: String] = [
        "CORRIDOR": "#0080E0",
        "ROZ": "#FF0000",
        "ZONE": "#FFA500",
        "FIRES": "#C02020",
        "SUPPORT": "#20C020",
        "POINT": "#FFFF00",
        "OTHER": "#C0C0C0",
    ]
    /// Fill alpha of the KML export (0x66 = 40 %).
    private static let fillAlpha = "66"

    static func vectorShape(for airspace: ACOAirspace) -> VectorShape? {
        guard let geom = airspace.geometry else { return nil }

        let geometry: VectorGeometry
        switch geom.shape {
        case .point, .polyline:
            // Drawn from the valid points, as the reference KML does for non-area shapes
            let points = geom.points.filter { $0.isValid() }
            guard let first = points.first else { return nil }
            geometry = points.count == 1
                ? .point(lat: first.lat, lon: first.lon)
                : .polyline(coordinates: points.map { [$0.lat, $0.lon] })
        case .circle(let radiusM):
            guard let center = geom.points.first, center.isValid(), radiusM > 0 else { return nil }
            geometry = .circle(lat: center.lat, lon: center.lon, radiusMeters: radiusM)
        case .polygon, .corridor, .orbit, .radArc:
            // Area shapes become their exterior ring; an annulus's hole is noted, not drawn
            guard let ring = geom.rings().first, ring.count >= 4 else { return nil }
            geometry = .polygon(coordinates: ring.map { [$0.lat, $0.lon] })
        }

        let color = categoryColors[airspace.category] ?? categoryColors["OTHER"]!
        var style = VectorStyle()
        style.strokeColor = color
        style.fillColor = color + fillAlpha
        style.strokeWidth = 2
        style.opacity = 1.0

        var shape = VectorShape(name: airspace.name.isEmpty ? airspace.description : airspace.name,
                                notes: notes(for: airspace), geometry: geometry, style: style)
        shape.dmgElevationFeet = airspace.upperFt
        return shape
    }

    private static func notes(for airspace: ACOAirspace) -> String {
        var lines: [String] = []
        if let acmType = airspace.acmType, !acmType.isEmpty {
            lines.append("Type: \(acmType) – \(airspace.description)")
        }
        if let usage = airspace.usage { lines.append("Use: \(usage)") }
        lines.append("Category: \(airspace.category)")
        if let kind = airspace.shapeKind { lines.append("Shape: \(kind)") }
        if case .radArc(let inner, _, _, _)? = airspace.geometry?.shape, inner > 0 {
            lines.append("Inner radius: \(Int(inner.rounded())) m (not drawn)")
        }
        if let vertical = airspace.vertical { lines.append("Altitude: \(altitudeText(vertical))") }
        let periods = airspace.periods.map(\.raw).filter { !$0.isEmpty }
        if !periods.isEmpty { lines.append("Period: \(periods.joined(separator: "; "))") }
        if let authority = airspace.controllingAuthority { lines.append("Controlling authority: \(authority)") }
        if !airspace.remarks.isEmpty { lines.append("Remarks: \(airspace.remarks.joined(separator: " "))") }
        return lines.joined(separator: "\n")
    }

    private static func altitudeText(_ vertical: ACOVerticalExtent) -> String {
        func end(_ altitude: ACOAltitude?) -> String {
            guard let altitude else { return "?" }
            guard let feet = altitude.feet else { return altitude.raw }
            return "\(altitude.raw) (\(Int(feet.rounded())) ft\(altitude.datum.map { " \($0)" } ?? ""))"
        }
        return "\(end(vertical.lower)) – \(end(vertical.upper))"
    }
}
