import SwiftUI

struct Euronav5Palette {
    /// IBM PC VGA 256-color palette (standard from 1987)
    /// - Indices 0-15: CGA backward-compatible colors
    /// - Indices 16-231: 6×6×6 RGB color cube (216 colors, each step = 51 units)
    /// - Indices 232-235: Grayscale ramp
    /// - Indices 236-255: Reserved/unused
    static let colors: [(UInt8, UInt8, UInt8)] = buildVGAPalette()

    /// Generates the full VGA 256-color palette
    private static func buildVGAPalette() -> [(UInt8, UInt8, UInt8)] {
        var palette: [(UInt8, UInt8, UInt8)] = []

        // 0-15: CGA backward-compatible colors
        palette.append(contentsOf: [
            (0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170),
            (170, 0, 0), (170, 0, 170), (170, 85, 0), (170, 170, 170),
            (85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255),
            (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255)
        ])

        // 16-231: 6×6×6 RGB color cube (each step = 51 units)
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    palette.append((UInt8(r * 51), UInt8(g * 51), UInt8(b * 51)))
                }
            }
        }

        // 232-235: Grayscale ramp
        palette.append(contentsOf: [
            (0, 0, 0), (85, 85, 85), (170, 170, 170), (255, 255, 255)
        ])

        // 236-255: Reserved (filled with black)
        palette.append(contentsOf: Array(repeating: (UInt8(0), UInt8(0), UInt8(0)), count: 20))

        return palette
    }

    /// Find nearest VGA palette index for a given RGB color using Euclidean distance
    static func nearestIndex(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        var minDistance: Int = Int.max
        var nearestIdx: UInt8 = 0

        for (idx, (pr, pg, pb)) in colors.enumerated() {
            let dr = Int(r) - Int(pr)
            let dg = Int(g) - Int(pg)
            let db = Int(b) - Int(pb)
            let distance = dr * dr + dg * dg + db * db

            if distance < minDistance {
                minDistance = distance
                nearestIdx = UInt8(idx)
            }
        }

        return nearestIdx
    }

    /// Find nearest VGA palette index for a SwiftUI Color
    static func nearestIndex(for color: Color) -> UInt8 {
        let resolved = color.resolve(in: EnvironmentValues())
        let r = UInt8(resolved.red * 255)
        let g = UInt8(resolved.green * 255)
        let b = UInt8(resolved.blue * 255)
        return nearestIndex(r: r, g: g, b: b)
    }

    /// Create a SwiftUI Color from a VGA palette index
    static func color(at index: UInt8) -> Color {
        let (r, g, b) = colors[Int(index)]
        return Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }
}
