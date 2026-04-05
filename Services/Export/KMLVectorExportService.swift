import Foundation

struct KMLVectorExportService: RouteExporting {
    let id = "kml-vector"
    let displayName = "KML Vektorlager (.kml)"
    let supportedExtensions = ["kml"]

    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile] {
        let exportLayers = document.vectorLayers.filter { !$0.isSystem }
        guard !exportLayers.isEmpty else {
            throw RutError.invalidFormat("No vector layers to export")
        }

        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<kml xmlns="http://www.opengis.net/kml/2.2">"#)
        lines.append("<Document>")
        lines.append("  <name>Vector Layers</name>")

        for layer in exportLayers {
            appendLayer(layer, indent: "  ", to: &lines)
        }

        lines.append("</Document>")
        lines.append("</kml>")

        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw RutError.invalidFormat("KML encoding failed")
        }
        return [ExportedFile(filename: "VectorLayers.kml", data: data)]
    }

    // MARK: - KML building

    private func appendLayer(_ layer: VectorLayer, indent: String, to lines: inout [String]) {
        lines.append("\(indent)<Folder>")
        lines.append("\(indent)  <name>\(esc(layer.name))</name>")
        if !layer.isVisible { lines.append("\(indent)  <visibility>0</visibility>") }
        for shape in layer.shapes   { appendShape(shape, indent: indent + "  ", to: &lines) }
        for child in layer.children { appendLayer(child, indent: indent + "  ", to: &lines) }
        lines.append("\(indent)</Folder>")
    }

    private func appendShape(_ shape: VectorShape, indent: String, to lines: inout [String]) {
        lines.append("\(indent)<Placemark>")
        lines.append("\(indent)  <name>\(esc(shape.name))</name>")
        if !shape.isVisible { lines.append("\(indent)  <visibility>0</visibility>") }
        let isPoint: Bool
        if case .point = shape.geometry { isPoint = true } else { isPoint = false }
        appendStyle(shape.style, isPoint: isPoint, indent: indent + "  ", to: &lines)
        appendGeometry(shape.geometry, indent: indent + "  ", to: &lines)
        lines.append("\(indent)</Placemark>")
    }

    private func appendStyle(_ style: VectorStyle, isPoint: Bool, indent: String, to lines: inout [String]) {
        lines.append("\(indent)<Style>")
        if isPoint {
            lines.append("\(indent)  <IconStyle>")
            lines.append("\(indent)    <color>\(kmlColor(style.strokeColor, alpha: style.opacity))</color>")
            lines.append("\(indent)    <scale>\(String(format: "%.2f", style.iconScale))</scale>")
            lines.append("\(indent)    <Icon><href>\(style.pointIcon.rawValue)</href></Icon>")
            lines.append("\(indent)    <hotSpot x=\"0.5\" y=\"0.5\" xunits=\"fraction\" yunits=\"fraction\"/>")
            lines.append("\(indent)  </IconStyle>")
        } else {
            lines.append("\(indent)  <LineStyle>")
            lines.append("\(indent)    <color>\(kmlColor(style.strokeColor, alpha: style.opacity))</color>")
            lines.append("\(indent)    <width>\(Int(style.strokeWidth.rounded()))</width>")
            lines.append("\(indent)  </LineStyle>")
            lines.append("\(indent)  <PolyStyle>")
            lines.append("\(indent)    <color>\(kmlColor(style.fillColor, alpha: style.opacity * 0.4))</color>")
            lines.append("\(indent)  </PolyStyle>")
        }
        lines.append("\(indent)</Style>")
    }

    private func appendGeometry(_ geo: VectorGeometry, indent: String, to lines: inout [String]) {
        switch geo {
        case .point(let lat, let lon):
            lines.append("\(indent)<Point>")
            lines.append("\(indent)  <coordinates>\(lon),\(lat),0</coordinates>")
            lines.append("\(indent)</Point>")

        case .polyline(let coords):
            let s = coords.map { "\($0[1]),\($0[0]),0" }.joined(separator: " ")
            lines.append("\(indent)<LineString>")
            lines.append("\(indent)  <tessellate>1</tessellate>")
            lines.append("\(indent)  <coordinates>\(s)</coordinates>")
            lines.append("\(indent)</LineString>")

        case .polygon(let coords):
            let s = coords.map { "\($0[1]),\($0[0]),0" }.joined(separator: " ")
            lines.append("\(indent)<Polygon>")
            lines.append("\(indent)  <outerBoundaryIs><LinearRing>")
            lines.append("\(indent)    <coordinates>\(s)</coordinates>")
            lines.append("\(indent)  </LinearRing></outerBoundaryIs>")
            lines.append("\(indent)</Polygon>")

        case .circle(let lat, let lon, let r):
            // KML has no native circle; approximate as 36-point polygon
            let ring = circlePolygon(lat: lat, lon: lon, radiusMeters: r, points: 36)
            appendGeometry(.polygon(coordinates: ring), indent: indent, to: &lines)
        }
    }

    // MARK: - Helpers

    /// KML color format: AABBGGRR (alpha-blue-green-red, uppercase hex)
    private func kmlColor(_ hex: String, alpha: Double) -> String {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var r = "FF", g = "FF", b = "FF"
        if raw.count >= 6 {
            r = String(raw.prefix(2))
            g = String(raw.dropFirst(2).prefix(2))
            b = String(raw.dropFirst(4).prefix(2))
        }
        let a = String(format: "%02X", Int(min(255, max(0, alpha * 255))))
        return "\(a)\(b.uppercased())\(g.uppercased())\(r.uppercased())"
    }

    private func circlePolygon(lat: Double, lon: Double, radiusMeters: Double, points: Int) -> [[Double]] {
        let earthRadius = 6_371_000.0
        let latRad = lat * .pi / 180
        return (0..<points).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(points)
            let dLat  = (radiusMeters / earthRadius) * cos(angle) * (180 / .pi)
            let dLon  = (radiusMeters / (earthRadius * cos(latRad))) * sin(angle) * (180 / .pi)
            return [lat + dLat, lon + dLon]
        }
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
