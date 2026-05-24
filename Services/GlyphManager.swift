import Foundation

class GlyphManager {
    static let shared = GlyphManager()

    private var glyphIndex: [UInt16: (filePath: String, metadata: GlyphBitmapExtractor.GlyphMetadata)] = [:]
    private var isInitialized = false

    private init() {
        loadAllGlyphs()
    }

    func getGlyphInfo(symbolId: UInt16) -> (filePath: String, metadata: GlyphBitmapExtractor.GlyphMetadata)? {
        if !isInitialized {
            loadAllGlyphs()
        }
        return glyphIndex[symbolId]
    }

    private func loadAllGlyphs() {
        glyphIndex = [:]

        // Get the euronav5 directory
        let symPaths = findSymFiles()

        for symPath in symPaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: symPath)),
                  let metadata = GlyphBitmapExtractor.loadMetadata(from: data) else {
                continue
            }

            for glyphMeta in metadata {
                glyphIndex[glyphMeta.symId] = (filePath: symPath, metadata: glyphMeta)
            }
        }

        isInitialized = true
    }

    private func findSymFiles() -> [String] {
        var symFiles: [String] = []

        // Check app bundle
        if let bundlePath = Bundle.main.resourcePath {
            let bundlePaths = [
                bundlePath + "/Supporting Files/euronav5",
                bundlePath + "/euronav5"
            ]
            for dir in bundlePaths {
                if let files = findSymFilesInDirectory(dir) {
                    symFiles.append(contentsOf: files)
                }
            }
        }

        // Check development paths
        let devPaths = [
            NSHomeDirectory() + "/kodprojekt/ios/rut/Supporting Files/euronav5",
            "/Users/drassen/kodprojekt/ios/rut/Supporting Files/euronav5",
            NSHomeDirectory() + "/kodprojekt/ios/rut/DMG avkodning/vector map data/db/settings/system/symbols",
            "/Users/drassen/kodprojekt/ios/rut/DMG avkodning/vector map data/db/settings/system/symbols"
        ]

        for dir in devPaths {
            if let files = findSymFilesInDirectory(dir) {
                symFiles.append(contentsOf: files)
            }
        }

        return symFiles
    }

    private func findSymFilesInDirectory(_ dirPath: String) -> [String]? {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: dirPath) else { return nil }

        var symFiles: [String] = []

        // Search recursively for .sym files
        if let enumerator = fileManager.enumerator(atPath: dirPath) {
            for case let file as String in enumerator {
                if file.lowercased().hasSuffix(".sym") {
                    let fullPath = (dirPath as NSString).appendingPathComponent(file)
                    symFiles.append(fullPath)
                }
            }
        }

        return symFiles.isEmpty ? nil : symFiles
    }
}
