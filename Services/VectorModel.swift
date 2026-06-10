import Foundation
import SwiftUI

// MARK: - VectorGeometry

/// Discriminated union for all supported geometry types.
/// Serialised with a flat "type" key alongside geometry-specific keys.
enum VectorGeometry: Codable {
    case point(lat: Double, lon: Double)
    case polyline(coordinates: [[Double]])   // [[lat, lon], ...]
    case polygon(coordinates: [[Double]])    // [[lat, lon], ...] closed ring
    case circle(lat: Double, lon: Double, radiusMeters: Double)

    private enum CodingKeys: String, CodingKey {
        case type, lat, lon, radiusMeters, coordinates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "point":
            self = .point(lat: try c.decode(Double.self, forKey: .lat),
                          lon: try c.decode(Double.self, forKey: .lon))
        case "polyline":
            self = .polyline(coordinates: try c.decode([[Double]].self, forKey: .coordinates))
        case "polygon":
            self = .polygon(coordinates: try c.decode([[Double]].self, forKey: .coordinates))
        case "circle":
            self = .circle(lat: try c.decode(Double.self, forKey: .lat),
                           lon: try c.decode(Double.self, forKey: .lon),
                           radiusMeters: try c.decode(Double.self, forKey: .radiusMeters))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown VectorGeometry type: \(type)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .point(let lat, let lon):
            try c.encode("point", forKey: .type)
            try c.encode(lat, forKey: .lat)
            try c.encode(lon, forKey: .lon)
        case .polyline(let coords):
            try c.encode("polyline", forKey: .type)
            try c.encode(coords, forKey: .coordinates)
        case .polygon(let coords):
            try c.encode("polygon", forKey: .type)
            try c.encode(coords, forKey: .coordinates)
        case .circle(let lat, let lon, let r):
            try c.encode("circle", forKey: .type)
            try c.encode(lat, forKey: .lat)
            try c.encode(lon, forKey: .lon)
            try c.encode(r, forKey: .radiusMeters)
        }
    }

    var geometryTypeName: String {
        switch self {
        case .point:    return "Point"
        case .polyline: return "Polyline"
        case .polygon:  return "Polygon"
        case .circle:   return "Circle"
        }
    }

    var vertexCount: Int {
        switch self {
        case .point:                return 1
        case .polyline(let c):      return c.count
        case .polygon(let c):       return c.count
        case .circle:               return 1
        }
    }
}

// MARK: - VectorPointIcon

enum VectorPointIcon: String, Codable, CaseIterable {
    case square   = "http://maps.google.com/mapfiles/kml/shapes/square.png"
    case triangle = "http://maps.google.com/mapfiles/kml/shapes/triangle.png"
    case donut    = "http://maps.google.com/mapfiles/kml/shapes/donut.png"
    case caution  = "http://maps.google.com/mapfiles/kml/shapes/caution.png"
    case circle   = "http://maps.google.com/mapfiles/kml/paddle/wht-circle.png"

    var assetName: String {
        switch self {
        case .square:   return "kml-icon-square"
        case .triangle: return "kml-icon-triangle"
        case .donut:    return "kml-icon-donut"
        case .caution:  return "kml-icon-caution"
        case .circle:   return "kml-icon-circle"
        }
    }

    var displayName: String {
        switch self {
        case .square:   return "Square"
        case .triangle: return "Triangle"
        case .donut:    return "Donut"
        case .caution:  return "Caution"
        case .circle:   return "Circle"
        }
    }
}

// MARK: - VectorPointIconView

struct VectorPointIconView: View {
    let icon: VectorPointIcon
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(icon.assetName)
            .resizable()
            .scaledToFit()
            .colorMultiply(color)
            .frame(width: size, height: size)
    }
}

// MARK: - Euronav5 Export Types

enum Euronav5ShapeCategory: String, Codable {
    case drawing
    case area

    var displayName: String {
        switch self {
        case .drawing: return "Drawing"
        case .area: return "Area"
        }
    }
}

enum Euronav5AreaType: String, Codable, CaseIterable {
    case restrictedZone   = "RESTRICTEDZONE"
    case navigationalZone = "NAVIGATIONALZONE"
    case prohibitedZone   = "PROHIBITEDZONE"
    case dangerZone       = "DANGERZONE"
    case obstacle         = "OBSTACLE"

    var displayName: String {
        switch self {
        case .restrictedZone: return "Restricted Zone"
        case .navigationalZone: return "Navigational Zone"
        case .prohibitedZone: return "Prohibited Zone"
        case .dangerZone: return "Danger Zone"
        case .obstacle: return "Obstacle"
        }
    }
}

enum Euronav5StyleClass: Codable, Equatable, Hashable {
    case known(KnownStyleClass)
    case custom(UInt16)

    var styleClassID: UInt16 {
        switch self {
        case .known(let known): return known.rawValue
        case .custom(let id): return id
        }
    }

    var displayName: String {
        switch self {
        case .known(let known): return known.displayName
        case .custom(let id): return String(format: "Custom (0x%04X / %d)", id, id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(styleClassID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(UInt16.self)
        if let known = KnownStyleClass(rawValue: id) {
            self = .known(known)
        } else {
            self = .custom(id)
        }
    }
}

enum KnownStyleClass: UInt16, CaseIterable {
    case `default` = 0x0000
    case lineTemplate = 0x0202
    case reserved1 = 0x0402
    case reserved2 = 0x4200

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .lineTemplate: return "Line Template"
        case .reserved1: return "Reserved 1 (0x0402)"
        case .reserved2: return "Reserved 2 (0x4200)"
        }
    }
}

// MARK: - VectorStyle

struct VectorStyle: Codable, Equatable {
    /// Stroke color as hex #RRGGBB
    var strokeColor: String  = "#8B5CF6"
    /// Fill color as hex #RRGGBBAA
    var fillColor: String    = "#8B5CF640"
    var strokeWidth: Double  = 2.0
    var opacity: Double      = 1.0
    /// Point-only: which KML icon shape to use
    var pointIcon: VectorPointIcon = .circle
    /// Point-only: icon render scale multiplier (0.5 – 3.0)
    var iconScale: Double    = 1.0
    /// Point-only: Euronav glyph symbol ID (0 = use pointIcon instead)
    var euronaveSymbolId: Int = 0
}

// MARK: - VectorShape

struct VectorShape: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var notes: String = ""
    var geometry: VectorGeometry
    var style: VectorStyle = VectorStyle()
    var isVisible: Bool = true

    // A109 Euronav5 export properties
    var dmgCategory: Euronav5ShapeCategory = .drawing
    var dmgAreaType: Euronav5AreaType = .restrictedZone
    var dmgStyleClass: Euronav5StyleClass = .known(.default)
}

// MARK: - VectorLayer

struct VectorLayer: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var isVisible: Bool  = true
    /// System layers (e.g. LFV airspace) cannot be deleted and are excluded from .rut export.
    var isSystem: Bool   = false
    var isExpanded: Bool = true
    var shapes: [VectorShape]   = []
    var children: [VectorLayer] = []
}

// MARK: - Color + Hex

extension Color {
    /// Creates a Color from a hex string: #RRGGBB or #RRGGBBAA.
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: raw)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let r, g, b, a: Double
        switch raw.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8)  & 0xFF) / 255
            b = Double(value         & 0xFF) / 255
            a = 1.0
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8)  & 0xFF) / 255
            a = Double(value         & 0xFF) / 255
        default:
            r = 0.816; g = 0.647; b = 0.157; a = 1.0 // amber fallback
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}
