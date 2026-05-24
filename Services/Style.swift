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
            // Show line preview for polylines (zigzag if pattern indicates)
            Canvas { context, size in
                var path = Path()
                let centerY = size.height / 2
                let isZigzag = lineDashPattern == 49344 || outlineDashPattern == 49344

                if isZigzag {
                    path.move(to: CGPoint(x: 2, y: centerY))
                    let segments = 3
                    let segmentWidth = (size.width - 4) / CGFloat(segments)
                    let zigzagAmplitude = size.height / 3
                    for i in 1...segments {
                        let x = 2 + segmentWidth * CGFloat(i)
                        let offset = (i % 2 == 0) ? zigzagAmplitude : -zigzagAmplitude
                        path.addLine(to: CGPoint(x: x, y: centerY + offset))
                    }
                } else {
                    path.move(to: CGPoint(x: 2, y: centerY))
                    path.addLine(to: CGPoint(x: size.width - 2, y: centerY))
                }
                let strokeWidth = CGFloat(max(1, lineWeight))
                context.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: strokeWidth))
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
                    if let lineColor = lineColor, lineWeight > 0 {
                        let strokeWidth = CGFloat(max(1, lineWeight))
                        let isZigzag = lineDashPattern == 49344
                        let pathToStroke = isZigzag ? createZigzagPath(for: circlePath, size: size) : circlePath
                        let dashStyle = StrokeStyle(
                            lineWidth: strokeWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: isZigzag ? [] : dashPatternToDashArray(lineDashPattern)
                        )
                        context.stroke(pathToStroke, with: .color(lineColor), style: dashStyle)
                    }
                    if let outlineColor = outlineColor, outlineWeight > 0 {
                        let outlineStrokeWidth = CGFloat(outlineWeight)
                        let isZigzag = outlineDashPattern == 49344
                        let pathToStroke = isZigzag ? createZigzagPath(for: circlePath, size: size) : circlePath
                        let dashStyle = StrokeStyle(
                            lineWidth: outlineStrokeWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: isZigzag ? [] : dashPatternToDashArray(outlineDashPattern)
                        )
                        context.stroke(pathToStroke, with: .color(outlineColor), style: dashStyle)
                    }
                } else {
                    // Draw polygon/rectangle
                    if let fillColor = polygonFillColor {
                        context.fill(path, with: .color(fillColor))
                    }

                    if let lineColor = lineColor, lineWeight > 0 {
                        let strokeWidth = CGFloat(max(1, lineWeight))
                        let isZigzag = lineDashPattern == 49344
                        let pathToStroke = isZigzag ? createZigzagPath(for: path, size: size) : path
                        let dashStyle = StrokeStyle(
                            lineWidth: strokeWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: isZigzag ? [] : dashPatternToDashArray(lineDashPattern)
                        )
                        context.stroke(pathToStroke, with: .color(lineColor), style: dashStyle)
                    }

                    if let outlineColor = outlineColor, outlineWeight > 0 {
                        let outlineStrokeWidth = CGFloat(outlineWeight)
                        let isZigzag = outlineDashPattern == 49344
                        let pathToStroke = isZigzag ? createZigzagPath(for: path, size: size) : path
                        let dashStyle = StrokeStyle(
                            lineWidth: outlineStrokeWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: isZigzag ? [] : dashPatternToDashArray(outlineDashPattern)
                        )
                        context.stroke(pathToStroke, with: .color(outlineColor), style: dashStyle)
                    }
                }
            }
            .frame(width: 32, height: 32)
            .background(Color(.systemGray6))
            .cornerRadius(4)
        }
    }

    private func createZigzagPath(for basePath: Path, size: CGSize, amplitude: CGFloat = 3) -> Path {
        // Create zigzag around rectangle perimeter
        let inset: CGFloat = 2
        let topLeft = CGPoint(x: inset, y: inset)
        let topRight = CGPoint(x: size.width - inset, y: inset)
        let bottomRight = CGPoint(x: size.width - inset, y: size.height - inset)
        let bottomLeft = CGPoint(x: inset, y: size.height - inset)

        var points: [CGPoint] = []
        let stepSize: CGFloat = 5
        var isInset = false

        // Top edge (left to right)
        var x = topLeft.x
        while x <= topRight.x {
            let y = topLeft.y + (isInset ? -amplitude : amplitude)
            points.append(CGPoint(x: x, y: min(y, topLeft.y + amplitude)))
            x += stepSize
            isInset.toggle()
        }

        // Right edge (top to bottom)
        var y = topRight.y + stepSize
        while y <= bottomRight.y {
            let xOffset = isInset ? amplitude : -amplitude
            points.append(CGPoint(x: topRight.x + xOffset, y: y))
            y += stepSize
            isInset.toggle()
        }

        // Bottom edge (right to left)
        x = bottomRight.x - stepSize
        while x >= bottomLeft.x {
            let yOffset = isInset ? amplitude : -amplitude
            points.append(CGPoint(x: x, y: bottomRight.y + yOffset))
            x -= stepSize
            isInset.toggle()
        }

        // Left edge (bottom to top)
        y = bottomLeft.y - stepSize
        while y >= topLeft.y {
            let xOffset = isInset ? -amplitude : amplitude
            points.append(CGPoint(x: bottomLeft.x + xOffset, y: y))
            y -= stepSize
            isInset.toggle()
        }

        var zigzagPath = Path()
        if !points.isEmpty {
            zigzagPath.move(to: points[0])
            for point in points.dropFirst() {
                zigzagPath.addLine(to: point)
            }
            zigzagPath.closeSubpath()
        }

        return zigzagPath
    }

    private func dashPatternToDashArray(_ pattern: UInt16) -> [CGFloat] {
        if pattern == 65535 {
            return []  // Solid line
        }
        if pattern == 0 {
            return []  // Solid line
        }

        var dashes: [CGFloat] = []
        var bitPattern = pattern
        var dashLength = 0
        var isGap = false

        for _ in 0..<16 {
            let bit = bitPattern & 0x0001
            if bit == 0x0001 {
                dashLength += 1
            } else {
                if dashLength > 0 {
                    dashes.append(CGFloat(dashLength))
                    dashLength = 0
                    isGap = true
                } else if isGap {
                    isGap = false
                }
            }
            bitPattern >>= 1
        }

        if dashLength > 0 {
            dashes.append(CGFloat(dashLength))
        }

        return dashes.isEmpty ? [] : dashes
    }
}
