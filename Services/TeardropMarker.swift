import SwiftUI

/// A classic teardrop map-pin marker (circle on top, point at bottom).
struct TeardropMarker: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            let w = size
            let h = size * 1.5
            let r = w / 2

            // Circle center sits at top, point at bottom
            var path = Path()
            // Circle part
            path.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: w))
            // Triangle pointing down from circle bottom
            path.move(to: CGPoint(x: r * 0.3, y: w * 0.75))
            path.addLine(to: CGPoint(x: w - r * 0.3, y: w * 0.75))
            path.addLine(to: CGPoint(x: r, y: h))
            path.closeSubpath()

            ctx.fill(path, with: .color(color))
        }
        .frame(width: size, height: size * 1.5)
    }
}
