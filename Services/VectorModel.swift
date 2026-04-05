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

// MARK: - VectorStyle

struct VectorStyle: Codable, Equatable {
    /// Stroke color as hex #RRGGBB
    var strokeColor: String  = "#8B5CF6"
    /// Fill color as hex #RRGGBBAA
    var fillColor: String    = "#8B5CF640"
    var strokeWidth: Double  = 2.0
    var opacity: Double      = 1.0
}

// MARK: - VectorShape

struct VectorShape: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var notes: String = ""
    var geometry: VectorGeometry
    var style: VectorStyle = VectorStyle()
    var isVisible: Bool = true
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
