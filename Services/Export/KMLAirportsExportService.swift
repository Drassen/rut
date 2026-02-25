import Foundation

/// Export all user airports as a KML file with a Folder named "Airports".
/// NOTE: KML coordinates are lon,lat,alt (opposite of GPX).
struct KMLAirportsExportService: RouteExporting {
    let id = "kml-airports"
    let displayName = "KML Airports (.kml)"
    let supportedExtensions = ["kml"]

    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile] {
        guard !document.userAirports.isEmpty else { return [] }

        let points = document.userAirports.map {
            (id: $0.id, lat: $0.latitude, lon: $0.longitude, ele: $0.elevation)
        }
        let xml = buildKML(folderName: "Airports", points: points)
        let data = xml.data(using: .utf8) ?? Data()
        return [ExportedFile(filename: "Airports.kml", data: data)]
    }

    private func buildKML(
        folderName: String,
        points: [(id: String, lat: Double, lon: Double, ele: Double)]
    ) -> String {
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.minimumFractionDigits = 6
        fmt.maximumFractionDigits = 6
        func c(_ v: Double) -> String { fmt.string(from: NSNumber(value: v)) ?? String(format: "%.6f", v) }

        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n"
        s += "  <Document>\n"
        s += "    <Folder>\n"
        s += "      <name>\(escapeXML(folderName))</name>\n"
        for pt in points {
            s += "      <Placemark>\n"
            s += "        <name>\(escapeXML(pt.id))</name>\n"
            s += "        <Point><coordinates>\(c(pt.lon)),\(c(pt.lat)),\(c(pt.ele))</coordinates></Point>\n"
            s += "      </Placemark>\n"
        }
        s += "    </Folder>\n"
        s += "  </Document>\n"
        s += "</kml>\n"
        return s
    }

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
