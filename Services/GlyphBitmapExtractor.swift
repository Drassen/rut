import UIKit

struct GlyphBitmapExtractor {
    struct GlyphMetadata {
        let symId: UInt16
        let xStart: UInt16
        let yStart: UInt16
        let xEnd: UInt16
        let yEnd: UInt16

        var width: Int { Int(xEnd - xStart + 1) }
        var height: Int { Int(yEnd - yStart + 1) }
    }

    static func extractGlyph(
        from data: Data,
        metadata: GlyphMetadata,
        primaryColor: UIColor = UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0),
        secondaryColor: UIColor = UIColor.black
    ) -> UIImage? {
        let width = metadata.width
        let height = metadata.height

        guard width > 0, height > 0 else { return nil }

        // Create image context
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var imageBytes = [UInt8](repeating: 0, count: height * bytesPerRow)

        let bitmapOffset = 0x1B1
        let bitmapWidth = 256
        let shiftX = 40
        let shiftY = 3

        // Convert colors to RGBA
        var primaryRGBA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)
        var secondaryRGBA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)

        var pR: CGFloat = 0, pG: CGFloat = 0, pB: CGFloat = 0, pA: CGFloat = 0
        primaryColor.getRed(&pR, green: &pG, blue: &pB, alpha: &pA)
        primaryRGBA = (UInt8(pR * 255), UInt8(pG * 255), UInt8(pB * 255), UInt8(pA * 255))

        var sR: CGFloat = 0, sG: CGFloat = 0, sB: CGFloat = 0, sA: CGFloat = 0
        secondaryColor.getRed(&sR, green: &sG, blue: &sB, alpha: &sA)
        secondaryRGBA = (UInt8(sR * 255), UInt8(sG * 255), UInt8(sB * 255), UInt8(sA * 255))

        // Extract and color bitmap pixels
        for y in 0..<height {
            for x in 0..<width {
                let sourceX = (Int(metadata.xStart) + x + shiftX) % bitmapWidth
                let sourceY = (Int(metadata.yStart) + y + shiftY) % 256

                let pixelIndex = sourceY * bitmapWidth + sourceX
                let byteOffset = bitmapOffset + (pixelIndex * 2)

                guard byteOffset + 1 < data.count else { continue }

                let primaryValue = Int(data[byteOffset])
                let secondaryValue = Int(data[byteOffset + 1])

                // Skip white background (255,255,255)
                if primaryValue == 255 && secondaryValue == 255 {
                    // Transparent pixel
                    let imageOffset = (y * bytesPerRow) + (x * bytesPerPixel)
                    imageBytes[imageOffset] = 0
                    imageBytes[imageOffset + 1] = 0
                    imageBytes[imageOffset + 2] = 0
                    imageBytes[imageOffset + 3] = 0
                    continue
                }

                // Interpolate between primary and secondary colors based on grayscale value
                let maxValue = max(primaryValue, secondaryValue)
                let t = max(0.0, Double(maxValue - 200) / 55.0)

                let r = Int(Double(primaryRGBA.0) + (Double(secondaryRGBA.0) - Double(primaryRGBA.0)) * t)
                let g = Int(Double(primaryRGBA.1) + (Double(secondaryRGBA.1) - Double(primaryRGBA.1)) * t)
                let b = Int(Double(primaryRGBA.2) + (Double(secondaryRGBA.2) - Double(primaryRGBA.2)) * t)
                let a = 255

                let imageOffset = (y * bytesPerRow) + (x * bytesPerPixel)
                imageBytes[imageOffset] = UInt8(r)
                imageBytes[imageOffset + 1] = UInt8(g)
                imageBytes[imageOffset + 2] = UInt8(b)
                imageBytes[imageOffset + 3] = UInt8(a)
            }
        }

        // Create CGImage from raw bytes
        guard let provider = CGDataProvider(data: NSData(bytes: imageBytes, length: imageBytes.count)) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    static func loadMetadata(from data: Data) -> [GlyphMetadata]? {
        guard data.count >= 0x1B0 else { return nil }

        var metadata: [GlyphMetadata] = []

        for i in 0..<28 {
            let offset = i * 16
            guard offset + 16 <= data.count else { break }

            let symId = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            let xStart = data.subdata(in: offset+4..<offset+6).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            let yStart = data.subdata(in: offset+6..<offset+8).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            let xEnd = data.subdata(in: offset+8..<offset+10).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            let yEnd = data.subdata(in: offset+10..<offset+12).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }

            metadata.append(GlyphMetadata(symId: symId, xStart: xStart, yStart: yStart, xEnd: xEnd, yEnd: yEnd))
        }

        return metadata.isEmpty ? nil : metadata
    }
}
