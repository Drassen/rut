import SwiftUI
import MapKit
import Combine

// MARK: - Model

struct AirspaceZone: Identifiable {
    let id: String
    let type: ZoneType
    let name: String
    let coordinates: [CLLocationCoordinate2D]

    enum ZoneType: String {
        case ctr  = "CTR"
        case atz  = "ATZ"
        case rsta = "RSTA"
        case dnga = "DNGA"

        var fillColor: Color {
            switch self {
            case .ctr:  return .blue.opacity(0.08)
            case .atz:  return .cyan.opacity(0.08)
            case .rsta: return .red.opacity(0.12)
            case .dnga: return .orange.opacity(0.12)
            }
        }

        var strokeColor: Color {
            switch self {
            case .ctr:  return .blue.opacity(0.5)
            case .atz:  return .cyan.opacity(0.5)
            case .rsta: return .red.opacity(0.7)
            case .dnga: return .orange.opacity(0.7)
            }
        }
    }
}

// MARK: - Service

@MainActor
final class AirspaceService: ObservableObject {
    static let shared = AirspaceService()

    @Published var zones: [AirspaceZone] = []

    private let layers = ["mais:RSTA", "mais:DNGA", "mais:ATZ", "mais:CTR"]
    private let base = "https://daim.lfv.se/geoserver/wfs"

    private init() {}

    func fetchAllZones() async {
        var result: [AirspaceZone] = []
        for layer in layers {
            if let fetched = try? await fetchLayer(layer) {
                result.append(contentsOf: fetched)
            }
        }
        zones = result
    }

    private func fetchLayer(_ typeName: String) async throws -> [AirspaceZone] {
        var comps = URLComponents(string: base)!
        comps.queryItems = [
            URLQueryItem(name: "service",      value: "WFS"),
            URLQueryItem(name: "version",      value: "1.1.0"),
            URLQueryItem(name: "request",      value: "GetFeature"),
            URLQueryItem(name: "typeName",     value: typeName),
            URLQueryItem(name: "outputFormat", value: "application/json")
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let fc = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)

        return fc.features.compactMap { f -> AirspaceZone? in
            guard
                let zoneType = AirspaceZone.ZoneType(rawValue: f.properties.typeofarea ?? ""),
                let ring = f.geometry.coordinates.first
            else { return nil }

            let coords = ring.map {
                CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])
            }
            return AirspaceZone(
                id: f.id,
                type: zoneType,
                name: f.properties.nameofarea ?? f.id,
                coordinates: coords
            )
        }
    }
}

// MARK: - Private GeoJSON Decodable helpers

private struct GeoJSONFeatureCollection: Decodable {
    let features: [GeoJSONFeature]
}

private struct GeoJSONFeature: Decodable {
    let id: String
    let geometry: GeoJSONGeometry
    let properties: GeoJSONProperties
}

private struct GeoJSONGeometry: Decodable {
    let coordinates: [[[Double]]]  // [ring][point][lon, lat]
}

private struct GeoJSONProperties: Decodable {
    let typeofarea: String?
    let nameofarea: String?

    enum CodingKeys: String, CodingKey {
        case typeofarea = "TYPEOFAREA"
        case nameofarea = "NAMEOFAREA"
    }
}
