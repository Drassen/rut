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

                let p0 = Int(data[byteOffset])
                let p1 = Int(data[byteOffset + 1])

                var r: UInt8 = 0
                var g: UInt8 = 0
                var b: UInt8 = 0
                var a: UInt8 = 255

                // p0-only interpretation with tuned thresholds
                if p0 > 200 && p1 < 100 {
                    // Border: primary color with full opacity
                    r = primaryRGBA.0; g = primaryRGBA.1; b = primaryRGBA.2; a = 255
                } else if p0 < 30 {
                    // Transparent
                    r = 0; g = 0; b = 0; a = 0
                } else if p0 > 50 {
                    // Fill: secondary color with p0 as opacity
                    r = secondaryRGBA.0
                    g = secondaryRGBA.1
                    b = secondaryRGBA.2
                    a = UInt8(min(255, p0))
                } else {
                    // Between transparent and fill threshold
                    r = 0; g = 0; b = 0; a = 0
                }

                let imageOffset = (y * bytesPerRow) + (x * bytesPerPixel)
                imageBytes[imageOffset] = r
                imageBytes[imageOffset + 1] = g
                imageBytes[imageOffset + 2] = b
                imageBytes[imageOffset + 3] = a
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
        guard data.count >= 16 else { return nil }

        var metadata: [GlyphMetadata] = []
        var offset = 0

        while offset + 16 <= data.count {
            // Check for all-zero terminator record
            let record = data.subdata(in: offset..<offset+16)
            if record.allSatisfy({ $0 == 0 }) {
                break
            }

            let symId = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            let xStart = data.subdata(in: offset+4..<offset+6).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            let yStart = data.subdata(in: offset+6..<offset+8).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            let xEnd = data.subdata(in: offset+8..<offset+10).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            let yEnd = data.subdata(in: offset+10..<offset+12).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }

            metadata.append(GlyphMetadata(symId: symId, xStart: xStart, yStart: yStart, xEnd: xEnd, yEnd: yEnd))
            offset += 16
        }

        return metadata.isEmpty ? nil : metadata
    }
}
