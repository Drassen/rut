import SwiftUI

struct Style: Identifiable {
    let id: UUID
    let styleId: UInt16
    let name: String
    let hexId: String
    let highByte: UInt8

    // Primary rendering state (first state)
    let symbolId: Int            // POI symbol/glyph ID (0 = no symbol)
    let primaryColor: Color?
    let secondaryColor: Color?
    let lineColor: Color?
    let lineDashPattern: UInt16  // 16-bit bitmask
    let lineWeight: Int          // 0-9
    let outlineColor: Color?
    let outlineDashPattern: UInt16
    let outlineWeight: Int
    let polygonFillColor: Color?
    let textColor: Color?
    let textBackgroundColor: Color?
    let textPosition: String     // ePosTop, ePosBelow, eOnTrack
    let textType: String        // eTextOnly, eTextRectangle, eTextPolygon
    let fontSize: Int
    let textBold: Bool
    let hasColoredLine: Bool
    let hasVisibleFill: Bool
    let isAllSchemes: Bool

    init(from styleItem: StyleItem) {
        self.id = styleItem.id
        self.styleId = styleItem.styleId
        self.name = styleItem.name
        self.hexId = styleItem.hexId
        self.highByte = styleItem.highByte
        self.symbolId = styleItem.symbolId
        self.primaryColor = styleItem.primaryColor
        self.secondaryColor = styleItem.secondaryColor
        self.lineColor = styleItem.lineColor
        self.lineDashPattern = styleItem.lineDashPattern
        self.lineWeight = styleItem.lineWeight
        self.outlineColor = styleItem.outlineColor
        self.outlineDashPattern = styleItem.outlineDashPattern
        self.outlineWeight = styleItem.outlineWeight
        self.polygonFillColor = styleItem.polygonFillColor
        self.textColor = styleItem.textColor
        self.textBackgroundColor = styleItem.textBackgroundColor
        self.textPosition = styleItem.textPosition
        self.textType = styleItem.textType
        self.fontSize = styleItem.fontSize
        self.textBold = styleItem.textBold
        self.hasColoredLine = styleItem.hasColoredLine
        self.hasVisibleFill = styleItem.hasVisibleFill
        self.isAllSchemes = styleItem.isAllSchemes
    }

    // Create preview view for a specific geometry type
    @ViewBuilder
    func previewView(geometry: VectorGeometry? = nil) -> some View {
        if symbolId > 0 {
            // Show glyph for styles with symbols
            GlyphDisplayView(
                symbolId: UInt16(symbolId),
                primaryColor: primaryColor,
                secondaryColor: secondaryColor
            )
            .frame(width: 32, height: 32)
            .cornerRadius(4)
        } else if case .polyline = geometry, let lineColor = lineColor {
            // Show line preview for polylines (ticks / dashes per pattern)
            Canvas { context, size in
                let centerY = size.height / 2
                let ends = [CGPoint(x: 2, y: centerY), CGPoint(x: size.width - 2, y: centerY)]
                let strokeWidth = CGFloat(max(1, lineWeight))
                let isTick = isTickDashPattern(lineDashPattern) || isTickDashPattern(outlineDashPattern)
                if isTick {
                    // Power-line symbol: solid line with perpendicular ticks.
                    let path = tickedLinePath(points: ends, closed: false)
                    context.stroke(path, with: .color(lineColor),
                                   style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                } else {
                    var path = Path()
                    path.move(to: ends[0]); path.addLine(to: ends[1])
                    let dash = euronavDashArray(lineDashPattern == 65535 ? outlineDashPattern : lineDashPattern)
                    context.stroke(path, with: .color(lineColor),
                                   style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt, dash: dash))
                }
            }
            .frame(width: 32, height: 32)
        } else {
            // Show polygon/box/circle for other shapes
            Canvas { context, size in
                let rect = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
                let path = Path(roundedRect: rect, cornerRadius: 2)

                if case .circle = geometry {
                    // Draw circle
                    let minDim = min(size.width, size.height)
                    let circleRect = CGRect(x: (size.width - minDim) / 2, y: (size.height - minDim) / 2, width: minDim, height: minDim)
                    let circlePath = Path(ellipseIn: circleRect)
                    let circleTicks = tickedLinePath(points: ellipsePerimeterPoints(in: circleRect), closed: true)
                    if let lineColor = lineColor, lineWeight > 0 {
                        let strokeWidth = CGFloat(max(1, lineWeight))
                        let isTick = isTickDashPattern(lineDashPattern)
                        context.stroke(isTick ? circleTicks : circlePath, with: .color(lineColor),
                                       style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round,
                                                          dash: isTick ? [] : dashPatternToDashArray(lineDashPattern)))
                    }
                    if let outlineColor = outlineColor, outlineWeight > 0 {
                        let outlineStrokeWidth = CGFloat(outlineWeight)
                        let isTick = isTickDashPattern(outlineDashPattern)
                        context.stroke(isTick ? circleTicks : circlePath, with: .color(outlineColor),
                                       style: StrokeStyle(lineWidth: outlineStrokeWidth, lineCap: .round, lineJoin: .round,
                                                          dash: isTick ? [] : dashPatternToDashArray(outlineDashPattern)))
                    }
                } else {
                    // Draw polygon/rectangle
                    if let fillColor = polygonFillColor {
                        context.fill(path, with: .color(fillColor))
                    }

                    let rectTicks = tickedLinePath(points: rectPerimeterPoints(rect), closed: true)
                    if let lineColor = lineColor, lineWeight > 0 {
                        let strokeWidth = CGFloat(max(1, lineWeight))
                        let isTick = isTickDashPattern(lineDashPattern)
                        context.stroke(isTick ? rectTicks : path, with: .color(lineColor),
                                       style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round,
                                                          dash: isTick ? [] : dashPatternToDashArray(lineDashPattern)))
                    }

                    if let outlineColor = outlineColor, outlineWeight > 0 {
                        let outlineStrokeWidth = CGFloat(outlineWeight)
                        let isTick = isTickDashPattern(outlineDashPattern)
                        context.stroke(isTick ? rectTicks : path, with: .color(outlineColor),
                                       style: StrokeStyle(lineWidth: outlineStrokeWidth, lineCap: .round, lineJoin: .round,
                                                          dash: isTick ? [] : dashPatternToDashArray(outlineDashPattern)))
                    }
                }
            }
            .frame(width: 32, height: 32)
            .background(Color(.systemGray6))
            .cornerRadius(4)
        }
    }

    private func dashPatternToDashArray(_ pattern: UInt16) -> [CGFloat] {
        return euronavDashArray(pattern)
    }
}

// MARK: - Line decoration helpers (shared across style previews)

/// Dash codes the helicopter renders as short perpendicular tick marks across
/// the line (the power-line / FIR cartographic symbol) — not a dashed or
/// zigzag line. Verified on hardware for KRAFTLEDNING (0xC0C0 / 0xC060).
func isTickDashPattern(_ pattern: UInt16) -> Bool {
    pattern == 49344 || pattern == 49248   // 0xC0C0, 0xC060
}

/// Path = the polyline through `points` plus short perpendicular tick marks at
/// regular intervals (the power-line symbol). Stroke it solid.
func tickedLinePath(points: [CGPoint], closed: Bool,
                    spacing: CGFloat = 7, tickLength: CGFloat = 6) -> Path {
    var path = Path()
    guard points.count >= 2 else { return path }
    path.move(to: points[0])
    for pt in points.dropFirst() { path.addLine(to: pt) }
    if closed { path.closeSubpath() }

    var verts = points
    if closed { verts.append(points[0]) }
    var carry = spacing / 2
    for i in 0..<(verts.count - 1) {
        let a = verts[i], b = verts[i + 1]
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        if len == 0 { continue }
        let ux = dx / len, uy = dy / len      // along
        let nx = -uy, ny = ux                 // perpendicular
        var d = carry
        while d <= len {
            let cx = a.x + ux * d, cy = a.y + uy * d
            path.move(to: CGPoint(x: cx - nx * tickLength / 2, y: cy - ny * tickLength / 2))
            path.addLine(to: CGPoint(x: cx + nx * tickLength / 2, y: cy + ny * tickLength / 2))
            d += spacing
        }
        carry = d - len
    }
    return path
}

/// Points sampled around an ellipse perimeter (for ticked circle borders).
func ellipsePerimeterPoints(in rect: CGRect, count: Int = 40) -> [CGPoint] {
    guard count > 2 else { return [] }
    let cx = rect.midX, cy = rect.midY
    let rx = rect.width / 2, ry = rect.height / 2
    return (0..<count).map { i in
        let a = 2 * CGFloat.pi * CGFloat(i) / CGFloat(count)
        return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
    }
}

/// The four corners of a rectangle (for ticked polygon borders).
func rectPerimeterPoints(_ rect: CGRect) -> [CGPoint] {
    [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
     CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
}

/// EuroNav 16-bit line-stipple bitmask → CoreGraphics dash array.
///
/// The pattern is a repeating 16-pixel stipple, bit = 1 → ink, 0 → gap
/// (read LSB-first along the line). Returns alternating run lengths
/// [dash, gap, dash, gap, …] starting with a dash; [] for a solid line.
/// Records BOTH ink and gap run lengths (so e.g. 0xFF00 = dash 8 / gap 8,
/// and uneven patterns keep their real gaps).
func euronavDashArray(_ pattern: UInt16) -> [CGFloat] {
    if pattern == 0 || pattern == 0xFFFF { return [] }   // solid
    var bits = (0..<16).map { (pattern >> $0) & 1 == 1 }
    // Rotate so the array begins with an ink run (CG dash arrays start "on").
    if let firstInk = bits.firstIndex(of: true) {
        bits = Array(bits[firstInk...] + bits[..<firstInk])
    }
    var runs: [CGFloat] = []
    var current = bits[0]
    var count = 0
    for b in bits {
        if b == current { count += 1 }
        else { runs.append(CGFloat(count)); current = b; count = 1 }
    }
    runs.append(CGFloat(count))
    // If it ends on an ink run, that run wraps into the leading ink run.
    if runs.count % 2 == 1 { runs[0] += runs.removeLast() }
    return runs
}
