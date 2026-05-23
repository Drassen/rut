import SwiftUI

struct GlyphDisplayView: View {
    let symbolId: UInt16
    var primaryColor: Color? = nil
    var secondaryColor: Color? = nil

    @State private var glyphImage: UIImage? = nil
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let image = glyphImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text(loadError ?? "Symbol \(symbolId) not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(4)
            }
        }
        .onAppear {
            loadGlyph()
        }
        .onChange(of: symbolId) { oldValue, newValue in
            if oldValue != newValue {
                loadGlyph()
            }
        }
    }

    private func loadGlyph() {
        isLoading = true
        glyphImage = nil
        loadError = nil

        Task {
            let image = await loadGlyphImage(symbolId: symbolId)
            DispatchQueue.main.async {
                self.glyphImage = image
                self.isLoading = false
                if image == nil {
                    self.loadError = "Symbol \(self.symbolId) not found"
                }
            }
        }
    }

    private func loadGlyphImage(symbolId: UInt16) async -> UIImage? {
        // Try to load 3.sym file
        var sym3Path: String? = nil

        // Check app bundle first (euronav5 resources)
        if let bundlePath = Bundle.main.resourcePath {
            let bundlePaths = [
                bundlePath + "/Supporting Files/euronav5/3.sym",
                bundlePath + "/euronav5/3.sym",
                bundlePath + "/3.sym"
            ]
            for path in bundlePaths {
                if FileManager.default.fileExists(atPath: path) {
                    sym3Path = path
                    break
                }
            }
        }

        // Check development paths
        if sym3Path == nil {
            let devPaths = [
                NSHomeDirectory() + "/kodprojekt/ios/rut/Supporting Files/euronav5/3.sym",
                "/Users/drassen/kodprojekt/ios/rut/Supporting Files/euronav5/3.sym",
                NSHomeDirectory() + "/kodprojekt/ios/rut/DMG avkodning/vector map data/db/settings/system/symbols/3.sym",
                "/Users/drassen/kodprojekt/ios/rut/DMG avkodning/vector map data/db/settings/system/symbols/3.sym"
            ]
            for path in devPaths {
                if FileManager.default.fileExists(atPath: path) {
                    sym3Path = path
                    break
                }
            }
        }

        guard let sym3Path = sym3Path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: sym3Path)),
              let metadata = GlyphBitmapExtractor.loadMetadata(from: data) else {
            return nil
        }

        // Find the metadata for this symbol ID
        guard let glyphMetadata = metadata.first(where: { $0.symId == symbolId }) else {
            return nil
        }

        // Convert primary and secondary colors to UIColor
        let primaryUIColor = primaryColor.map { UIColor($0) } ?? UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
        let secondaryUIColor = secondaryColor.map { UIColor($0) } ?? UIColor.black

        // Extract glyph as image
        return GlyphBitmapExtractor.extractGlyph(
            from: data,
            metadata: glyphMetadata,
            primaryColor: primaryUIColor,
            secondaryColor: secondaryUIColor
        )
    }
}
