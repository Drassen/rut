import SwiftUI
import MapKit

// MARK: - Map style

enum RutMapStyle: String, CaseIterable, Identifiable {
    case hybrid
    case standard
    case satellite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hybrid:   return "Hybrid"
        case .standard: return "Standard"
        case .satellite:return "Satellite"
        }
    }

    var mapKitStyle: MapStyle {
        switch self {
        case .hybrid:   return .hybrid
        case .standard: return .standard
        case .satellite:return .imagery
        }
    }
}

// MARK: - Custom shapes

struct TriangleMarkerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - SUBVIEWS

struct DatabaseMarkerView: View {
    let bgColor: Color
    let iconName: String
    let iconColor: Color
    let label: String
    var showLabel: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .fill(bgColor)

            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundColor(iconColor)
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .top) {
            if showLabel {
                Text(label)
                    .font(.caption2)
                    .padding(2)
                    .background(Color.white.opacity(0.8))
                    .foregroundColor(Color.black.opacity(0.8))
                    .cornerRadius(4)
                    .fixedSize()
                    .offset(y: 30)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Circle())
    }
}

struct RouteMarkerShapeView: View {
    let point: RouteMapPoint
    let color: Color
    let contentColor: Color
    let waypointType: WaypointType?
    var showLabel: Bool = true

    var body: some View {
        ZStack {
            markerShape()
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .top) {
            if showLabel {
                Text(point.name)
                    .font(.caption2)
                    .padding(2)
                    .background(Color.white.opacity(0.8))
                    .foregroundColor(.black)
                    .cornerRadius(4)
                    .fixedSize()
                    .offset(y: 30)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Circle())
    }

    @ViewBuilder
    private func markerShape() -> some View {
        switch point.kind {

        // --- AIRPORTS ---
        case .userAirport, .systemAirport:
            ZStack {
                Circle().fill(color)
                Image(systemName: "airplane")
                    .font(.system(size: 14))
                    .foregroundColor(contentColor)
            }

        // --- NAVAIDS ---
        case .userNavaid, .systemNavaid:
            ZStack {
                Circle().fill(color)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundColor(contentColor)
            }

        // --- WAYPOINTS ---
        case .userWaypoint:
            if let t = waypointType {
                switch t {
                case .tgt:
                    ZStack {
                        TriangleMarkerShape().fill(color)
                        TriangleMarkerShape().fill(Color.white).padding(6)
                    }
                case .ip:
                    ZStack {
                        Rectangle().fill(color)
                        Rectangle().fill(Color.white).padding(6)
                    }
                case .lp:
                    ZStack {
                        TriangleMarkerShape().fill(color)
                        TriangleMarkerShape().fill(Color.white).padding(6)
                    }
                case .cli:
                    ZStack {
                        Circle().fill(color)
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    }
                case .des:
                    ZStack {
                        Circle().fill(color)
                        Image(systemName: "arrow.down").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    }
                case .hld:
                    ZStack {
                        Circle().fill(color)
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    }
                default:
                    ZStack {
                        Circle().fill(color)
                        Circle().fill(Color.white).padding(6)
                    }
                }
            } else {
                ZStack {
                    Circle().fill(color)
                    Circle().fill(Color.white).padding(6)
                }
            }
        }
    }
}

struct GhostInsertMarkerView: View {
    let isSnapping: Bool
    let snapId: String?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isSnapping ? Color.green : Color.blue,
                        style: StrokeStyle(lineWidth: 2.5, dash: [5, 3])
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: isSnapping ? "checkmark" : "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(isSnapping ? .green : .blue)
            }
            if let id = snapId {
                Text(id)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .fixedSize()
            }
        }
        .allowsHitTesting(false)
    }
}
