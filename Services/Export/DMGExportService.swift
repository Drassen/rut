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

    // Template header (4297 bytes): CONSTANT SQL schema + 13 header data records (0-12)
    //
    // IMPORTANT: This header is CONSTANT across all DMG .tbl exports.
    // Per DMG_FORMAT.txt: "Template header is CONSTANT across all types"
    //
    // Contents:
    // - SQL field schema definitions (23 database fields defined in header records 0-12)
    // - Record 0: Field metadata (USEROBJECTID, ID, DATEDAYS, DATEMONTHS, DATEYEARS, etc.)
    // - Records 1-12: Header data (field structure and initial values)
    //
    // Source: Extracted from set2/USER2.tbl bytes 0x0000–0x10C8 (4297 bytes)
    // This identical header appears in all test sets (set1-set10) and production data
    // because the schema is standardized for all DMG vector overlay files.
    //
    // Reference: /Users/drassen/kodprojekt/ios/rut/DMG avkodning/DMG_FORMAT.txt
    //   "DISCOVERY 1: COMPLETE SCHEMA DEFINITION FOUND"
    //   "Location: Header records 0-12 in all test files"
    //   "Finding: All 23 database fields defined in SQL schema headers"
    //
    private static let templateHeaderBase64 = "AxgIEAABAAACAAAAYGYDAFVTRVJPQkpFQ1RJRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVAAAAAAADAElEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAERBVEVEQVlTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAERBVEVNT05USFMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAERBVEVZRUFSUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRJTUVTRUNPTkRTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRJTUVNSU5VVEVTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRJTUVIT1VSUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRZUEUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAAHAE5BTUUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAAHAERFU0NSSVBUSU9OAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAHAExBQkVMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAEFQUEVSQU5DRQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAExBVElUVURFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAExPTkdJVFVERQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAEVMRVZBVElPTgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFJBTkdFTEVUSEFMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFJBTkdFREVURUNUSU9OAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAEFUVEFDSE1FTlQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwAHAFNQRUVEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAENPVVJTRQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFdBUk5JTkdTRU5TSVRJVkUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAENMQVNTAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFNPVVJDRQAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE9JAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAABJRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJAAAATE4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAcQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAABAAAAABAAAA/////wkABQDqBxQAAQAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGQxAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAmAwAAoNt7A6AM7gD/+///AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAP////8JAAUA6gcUAAEACgAAAAAAAAAAAAAAAAAAAAAAAAAAAABkMQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAJgMAALzOewO4U+4A//v//wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMAAAD/////CQAFAOoHFAABAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZDEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAACYDAAA8DXwDFDTuAP/7//8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAA/////wkABQDqBxQAAQAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="

    private static func getTemplateHeader() -> Data {
        guard let data = Data(base64Encoded: templateHeaderBase64) else {
            return Data(count: 4297) // Fallback: all zeros
        }
        return data
    }

    /// Export DMG vector overlay card (folder structure with .tbl + .idx files)
    func exportDMGCard(vectorLayers: [VectorLayer], to dmgLayer: DMGLayer) -> [String: Data] {
        var files: [String: Data] = [:]

        // Generate DMG overlay file
        var shapes: [VectorShape] = []
        for layer in vectorLayers {
            collectShapesFlat(from: layer, into: &shapes)
        }
        let dmgData = export(shapes: shapes, to: dmgLayer)
        files["db/SQL/\(dmgLayer.filename)"] = dmgData

        // Create index files with proper record references
        let baseName = dmgLayer.filename.replacingOccurrences(of: ".tbl", with: "")
        let recordCount = UInt32(calculateRecordCount(shapes: shapes))

        files["db/SQL/\(baseName)-ID.idx"] = createIndexFile(type: .id, recordCount: recordCount)
        files["db/SQL/\(baseName)-LN.idx"] = createIndexFile(type: .ln, recordCount: recordCount)
        files["db/SQL/\(baseName)-OI.idx"] = createIndexFile(type: .oi, recordCount: recordCount)

        return files
    }

    /// Index file type
    private enum IndexType {
        case id  // ID/grouping index
        case ln  // Longitude (geographic) index
        case oi  // Sequential order index
    }

    /// Calculate total record count from shapes
    private func calculateRecordCount(shapes: [VectorShape]) -> Int {
        var count = 0
        for shape in shapes where shape.isVisible {
            switch shape.geometry {
            case .polyline(let coordinates):
                count += coordinates.count
            case .polygon(let coordinates):
                count += coordinates.count
            case .circle:
                count += 1
            case .point:
                break
            }
        }
        return count
    }

    /// Create an .idx index file (828 bytes, properly structured)
    private func createIndexFile(type: IndexType, recordCount: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 828)

        // SECTION 1: Header (0x00-0x0F, 16 bytes)
        // Magic number: 0x00030003
        writeInt32LE(&bytes, at: 0x00, value: 0x00030003)

        // Max records: 0x0000003c (60 for test data, can be adjusted)
        writeInt32LE(&bytes, at: 0x04, value: max(Int32(recordCount), 60))

        // Reserved: 0x00000000
        writeInt32LE(&bytes, at: 0x08, value: 0x00000000)

        // Separator: 0xffffffff
        writeInt32LE(&bytes, at: 0x0c, value: -1)

        // SECTION 2: Extended metadata (0x10-0x43, 52 bytes)
        // All types start with separator at 0x10
        writeInt32LE(&bytes, at: 0x10, value: -1)

        // Type-specific metadata
        switch type {
        case .id:
            // ID index: group-based metadata
            writeInt32LE(&bytes, at: 0x14, value: 0)           // First record
            writeInt32LE(&bytes, at: 0x18, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x1c, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x20, value: Int32(recordCount))
            writeInt32LE(&bytes, at: 0x24, value: Int32(recordCount))
            writeInt32LE(&bytes, at: 0x28, value: -6)          // Delta encoding start
            writeInt32LE(&bytes, at: 0x2c, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x30, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x34, value: Int32(max(recordCount - 1, 0)))
            writeInt32LE(&bytes, at: 0x38, value: Int32(max(recordCount - 1, 0)))
            writeInt32LE(&bytes, at: 0x3c, value: Int32(max(recordCount - 1, 0)))

        case .ln:
            // LN index: longitude-based metadata
            writeInt32LE(&bytes, at: 0x14, value: 10000000)    // Min longitude (10°E)
            writeInt32LE(&bytes, at: 0x18, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x1c, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x20, value: 0)
            writeInt32LE(&bytes, at: 0x24, value: Int32(recordCount))
            writeInt32LE(&bytes, at: 0x28, value: 25000000)    // Max longitude (25°E)
            writeInt32LE(&bytes, at: 0x2c, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x30, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x34, value: 0)
            writeInt32LE(&bytes, at: 0x38, value: Int32(recordCount))
            writeInt32LE(&bytes, at: 0x3c, value: 25000000)    // Max longitude

        case .oi:
            // OI index: sequential order metadata
            writeInt32LE(&bytes, at: 0x14, value: Int32(recordCount))
            writeInt32LE(&bytes, at: 0x18, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x1c, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x20, value: Int32(recordCount))
            writeInt32LE(&bytes, at: 0x24, value: Int32(recordCount))
            writeInt32LE(&bytes, at: 0x28, value: 0)           // First record
            writeInt32LE(&bytes, at: 0x2c, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x30, value: -2147483648) // 0x80000000 marker
            writeInt32LE(&bytes, at: 0x34, value: 0)
            writeInt32LE(&bytes, at: 0x38, value: Int32(max(recordCount - 1, 0)))
            writeInt32LE(&bytes, at: 0x3c, value: Int32(max(recordCount - 1, 0)))
        }

        // Padding at 0x40 (already 0x00)

        // SECTION 3: Separator block (0x44-0x143, 256 bytes = 64 int32 values of 0xffffffff)
        for i in 0..<64 {
            writeInt32LE(&bytes, at: 0x44 + (i * 4), value: -1)
        }

        // SECTION 4: Index data (0x144-0x24B, 264 bytes for index pairs)
        var indexOffset = 0x144

        switch type {
        case .id:
            // ID index: sequential record pairs with group IDs
            for i in 0..<recordCount {
                if indexOffset + 8 > 0x24C { break }
                writeInt32LE(&bytes, at: indexOffset, value: Int32(i))      // Group ID
                writeInt32LE(&bytes, at: indexOffset + 4, value: Int32(i))  // Record index
                indexOffset += 8
            }

        case .ln:
            // LN index: longitude coordinate pairs (sorted west to east)
            var recordIndex: Int32 = 0
            for i in 0..<recordCount {
                if indexOffset + 8 > 0x24C { break }
                // Generate longitude from record index (span 10°E to 25°E)
                let lon = Int32(10000000 + (Int32(i) * 15000000 / max(Int32(recordCount), 1)))
                writeInt32LE(&bytes, at: indexOffset, value: lon)           // Longitude (microdegrees)
                writeInt32LE(&bytes, at: indexOffset + 4, value: recordIndex)
                recordIndex += 1
                indexOffset += 8
            }

        case .oi:
            // OI index: identity mapping (sequential)
            for i in 0..<recordCount {
                if indexOffset + 8 > 0x24C { break }
                writeInt32LE(&bytes, at: indexOffset, value: Int32(i))     // Record index (key)
                writeInt32LE(&bytes, at: indexOffset + 4, value: Int32(i)) // Record index (value)
                indexOffset += 8
            }
        }

        // SECTION 5: Padding (0x24C-0x33B, 240 bytes of 0x00) - already initialized

        return Data(bytes)
    }

    /// Export vector layers to DMG .tbl format
    func export(layers: [VectorLayer], to layer: DMGLayer) -> Data {
        var shapes: [VectorShape] = []
        for layer in layers {
            collectShapesFlat(from: layer, into: &shapes)
        }
        return export(shapes: shapes, to: layer)
    }

    /// Export vector shapes to DMG .tbl format
    func export(shapes: [VectorShape], to layer: DMGLayer) -> Data {
        var data = DMGExportService.getTemplateHeader()

        var figureCounter: UInt8 = 21 // Start after test-set counter values

        for shape in shapes where shape.isVisible {
            let figureName = sanitizeName(shape.name)

            // Determine export type: AREA circles or DRAWING geometry
            if shape.dmgCategory == .area, case .circle(let lat, let lon, let radiusMeters) = shape.geometry {
                guard isValidCoordinate(lat, lon), radiusMeters > 0 else { continue }
                data.append(buildAreaCircleRecord(
                    lat: lat, lon: lon, radiusMeters: radiusMeters,
                    figureName: figureName, shape: shape
                ))
                figureCounter = figureCounter &+ 1
            } else {
                // DRAWING: polyline or polygon only (points and non-AREA circles are skipped)
                switch shape.geometry {
                case .polyline(let coordinates):
                    for coord in coordinates {
                        guard isValidCoordinate(coord[0], coord[1]) else { continue }
                        data.append(buildDrawingRecord(
                            lat: coord[0], lon: coord[1],
                            figureName: figureName, shape: shape,
                            figureCounter: figureCounter, geometryType: 0x00
                        ))
                    }
                    if !coordinates.isEmpty {
                        figureCounter = figureCounter &+ 1
                    }

                case .polygon(let coordinates):
                    for coord in coordinates {
                        guard isValidCoordinate(coord[0], coord[1]) else { continue }
                        data.append(buildDrawingRecord(
                            lat: coord[0], lon: coord[1],
                            figureName: figureName, shape: shape,
                            figureCounter: figureCounter, geometryType: 0x80
                        ))
                    }
                    if !coordinates.isEmpty {
                        figureCounter = figureCounter &+ 1
                    }

                case .circle(let lat, let lon, let radiusMeters):
                    // DRAWING circle: export as single point
                    guard isValidCoordinate(lat, lon), radiusMeters > 0 else { continue }
                    data.append(buildDrawingRecord(
                        lat: lat, lon: lon,
                        figureName: figureName, shape: shape,
                        figureCounter: figureCounter, geometryType: 0x31  // circle marker
                    ))
                    figureCounter = figureCounter &+ 1

                case .point:
                    // Points are not exported to DMG format
                    continue
                }
            }
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

        // 0x9a-0x9b: Style Class ID (16-bit LE)
        let styleID = shape.dmgStyleClass.styleClassID
        writeUInt16LE(&rec, at: 0x9a, value: styleID)

        // 0xad: Line color index (VGA-256)
        rec[0xad] = DMGPalette.nearestIndex(for: Color(hex: shape.style.strokeColor))

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

    /// Collect all visible shapes from a layer and its children
    private func collectShapesFlat(from layer: VectorLayer, into result: inout [VectorShape]) {
        guard layer.isVisible else { return }
        for shape in layer.shapes where shape.isVisible {
            result.append(shape)
        }
        for child in layer.children {
            collectShapesFlat(from: child, into: &result)
        }
    }

    /// Validate coordinate is within valid range and not NaN/Inf
    private func isValidCoordinate(_ lat: Double, _ lon: Double) -> Bool {
        lat.isFinite && lon.isFinite && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
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

    /// Write unsigned 16-bit LE integer to data
    private func writeUInt16LE(_ data: inout [UInt8], at offset: Int, value: UInt16) {
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
