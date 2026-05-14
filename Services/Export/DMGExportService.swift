import Foundation
import CoreLocation
import SwiftUI

struct DMGExportService {
    enum DMGLayer: Int, CaseIterable {
        case one = 1
        case two = 2
        case three = 3
        case four = 4

        var filename: String {
            "USER\(rawValue + 1).tbl"
        }

        var displayName: String {
            "Layer \(rawValue)"
        }
    }

    // Template header (4297 bytes): schema + 13 header data records 0-12
    // Extracted from set2/USER2.tbl bytes 0x0000–0x10C8
    private static let templateHeaderBase64 = "AxgIEAABAAACAAAAYGYDAFVTRVJPQkpFQ1RJRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVAAAAAAADAElEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAERBVEVEQVlTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAERBVEVNT05USFMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAERBVEVZRUFSUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRJTUVTRUNPTkRTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRJTUVNSU5VVEVTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRJTUVIT1VSUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRZUEUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAAHAE5BTUUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAAHAERFU0NSSVBUSU9OAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAHAExBQkVMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAEFQUEVSQU5DRQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAExBVElUVURFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAExPTkdJVFVERQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAEVMRVZBVElPTgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFJBTkdFTEVUSEFMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFJBTkdFREVURUNUSU9OAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAEFUVEFDSE1FTlQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwAHAFNQRUVEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAENPVVJTRQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFdBUk5JTkdTRU5TSVRJVkUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAENMQVNTAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFNPVVJDRQAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAmAwAAoNt7A6AM7gD/+///AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAP////8JAAUA6gcUAAEACgAAAAAAAAAAAAAAAAAAAAAAAAAAAABkMQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAJgMAALzOewO4U+4A//v//wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMAAAD/////CQAFAOoHFAABAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZDEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAACYDAAA8DXwDFDTuAP/7//8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAA/////wkABQDqBxQAAQAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="

    private static func getTemplateHeader() -> Data {
        guard let data = Data(base64Encoded: templateHeaderBase64) else {
            return Data(count: 4297) // Fallback: all zeros
        }
        return data
    }

    /// Export vector shapes to DMG .tbl format
    func export(shapes: [VectorShape], to layer: DMGLayer) -> Data {
        var data = DMGExportService.getTemplateHeader()

        var figureCounter: UInt8 = 21 // Start after test-set counter values
        var shapeIndex = 0

        for shape in shapes where shape.isVisible {
            let figureName = sanitizeName(shape.name)

            // Determine export type: AREA circles or DRAWING geometry
            if shape.dmgCategory == .area, case .circle(let lat, let lon, let radiusMeters) = shape.geometry {
                data.append(buildAreaCircleRecord(
                    lat: lat, lon: lon, radiusMeters: radiusMeters,
                    figureName: figureName, shape: shape
                ))
            } else {
                // DRAWING: polyline, polygon, or point
                switch shape.geometry {
                case .polyline(let coordinates):
                    for coord in coordinates {
                        data.append(buildDrawingRecord(
                            lat: coord[0], lon: coord[1],
                            figureName: figureName, shape: shape,
                            figureCounter: figureCounter, geometryType: 0x00
                        ))
                    }

                case .polygon(let coordinates):
                    for coord in coordinates {
                        data.append(buildDrawingRecord(
                            lat: coord[0], lon: coord[1],
                            figureName: figureName, shape: shape,
                            figureCounter: figureCounter, geometryType: 0x80
                        ))
                    }

                case .circle(let lat, let lon, _):
                    // DRAWING circle: treat as single point (unsupported in detail for now)
                    data.append(buildDrawingRecord(
                        lat: lat, lon: lon,
                        figureName: figureName, shape: shape,
                        figureCounter: figureCounter, geometryType: 0x31  // circle marker
                    ))

                case .point(let lat, let lon):
                    data.append(buildDrawingRecord(
                        lat: lat, lon: lon,
                        figureName: figureName, shape: shape,
                        figureCounter: figureCounter, geometryType: 0x00
                    ))
                }
            }

            figureCounter = figureCounter &+ 1
            shapeIndex += 1
        }

        return data
    }

    /// Build a 256-byte DRAWING record for one point
    private func buildDrawingRecord(
        lat: Double, lon: Double, figureName: String,
        shape: VectorShape, figureCounter: UInt8, geometryType: UInt8
    ) -> Data {
        var rec = [UInt8](repeating: 0, count: 256)

        // 0x00-0x07: Figure name (ASCII, null-terminated)
        let nameBytes = figureName.padding(toLength: 8, withPad: "\0", startingAt: 0).utf8
        for (i, byte) in nameBytes.prefix(8).enumerated() {
            rec[0x00 + i] = byte
        }

        // 0x9e-0xa1: Latitude (signed 32-bit LE, microdegrees)
        let latMicrodeg = Int32(lat * 1_000_000)
        writeInt32LE(&rec, at: 0x9e, value: latMicrodeg)

        // 0xa2-0xa5: Longitude (signed 32-bit LE, microdegrees)
        let lonMicrodeg = Int32(lon * 1_000_000)
        writeInt32LE(&rec, at: 0xa2, value: lonMicrodeg)

        // 0xad: Line color index (VGA-256)
        if let style = shape.dmgLineStyle {
            rec[0xad] = style.colorByte
        } else {
            rec[0xad] = DMGPalette.nearestIndex(for: Color(hex: shape.style.strokeColor))
        }

        // 0xb0: Figure counter
        rec[0xb0] = figureCounter

        // 0xdb: Geometry type (0x00 line, 0x31 circle, 0x80+ polygon)
        rec[0xdb] = geometryType

        // 0xdf: Format version (0x00 = test format)
        rec[0xdf] = 0x00

        // 0xeb: Status byte (0x00 = normal)
        rec[0xeb] = 0x00

        return Data(rec)
    }

    /// Build a 256-byte AREA circle record
    private func buildAreaCircleRecord(
        lat: Double, lon: Double, radiusMeters: Double,
        figureName: String, shape: VectorShape
    ) -> Data {
        var rec = [UInt8](repeating: 0, count: 256)

        // 0x08-0x0f: Figure name (ASCII, null-terminated)
        let nameBytes = figureName.padding(toLength: 8, withPad: "\0", startingAt: 0).utf8
        for (i, byte) in nameBytes.prefix(8).enumerated() {
            rec[0x08 + i] = byte
        }

        // 0xae-0xb1: Circle center latitude (signed 32-bit LE, microdegrees)
        let latMicrodeg = Int32(lat * 1_000_000)
        writeInt32LE(&rec, at: 0xae, value: latMicrodeg)

        // 0xb2-0xb5: Circle center longitude (signed 32-bit LE, microdegrees)
        let lonMicrodeg = Int32(lon * 1_000_000)
        writeInt32LE(&rec, at: 0xb2, value: lonMicrodeg)

        // 0xbe-0xc1: Radius (unsigned 32-bit LE, microdegrees)
        // 1° ≈ 111,000 m → radiusMeters / 111,000 = degrees → * 1_000_000 = microdegrees
        let radiusMicrodeg = UInt32(radiusMeters / 0.111)
        writeUInt32LE(&rec, at: 0xbe, value: radiusMicrodeg)

        // 0xb4-0xc4: Zone type string (null-terminated ASCII)
        let zoneTypeString = shape.dmgAreaType.rawValue
        let zoneBytes = zoneTypeString.utf8
        for (i, byte) in zoneBytes.enumerated() {
            guard i < 17 else { break } // 0xb4-0xc4 = 17 bytes
            rec[0xb4 + i] = byte
        }

        // 0xc2: Circle geometry marker (0x10)
        rec[0xc2] = 0x10

        // 0xdf: Format version (0x00 = test format)
        rec[0xdf] = 0x00

        // 0xeb: Status byte (0x03 = zone)
        rec[0xeb] = 0x03

        return Data(rec)
    }

    /// Sanitize shape name to 8-character ASCII-safe string
    private func sanitizeName(_ name: String) -> String {
        let safe = name
            .replacingOccurrences(of: " ", with: "_")
            .prefix(8)
            .uppercased()
        return String(safe)
    }

    /// Write signed 32-bit LE integer to data
    private func writeInt32LE(_ data: inout [UInt8], at offset: Int, value: Int32) {
        let bytes = withUnsafeBytes(of: value.littleEndian) { Array($0) }
        for (i, byte) in bytes.enumerated() {
            data[offset + i] = byte
        }
    }

    /// Write unsigned 32-bit LE integer to data
    private func writeUInt32LE(_ data: inout [UInt8], at offset: Int, value: UInt32) {
        let bytes = withUnsafeBytes(of: value.littleEndian) { Array($0) }
        for (i, byte) in bytes.enumerated() {
            data[offset + i] = byte
        }
    }
}
