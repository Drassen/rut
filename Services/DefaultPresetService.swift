import Foundation
import UniformTypeIdentifiers

// MARK: - UTType extensions

extension UTType {
    static let rut = UTType(exportedAs: "com.serveraren.rut.rut")
    static let apt = UTType(exportedAs: "com.serveraren.rut.apt")
    static let nav = UTType(exportedAs: "com.serveraren.rut.nav")
}

// MARK: - DefaultPresetService

final class DefaultPresetService {
    static let shared = DefaultPresetService()
    private let bookmarkKey = "a109DefaultPresetBookmark"
    private let nameKey     = "a109DefaultPresetName"

    var defaultFileName: String? {
        UserDefaults.standard.string(forKey: nameKey)
    }

    var hasDefault: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    func saveDefault(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
    }

    func clearDefault() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }

    /// Returnerar en resolved URL med security scope aktiverad.
    /// Anroparen ansvarar för att kalla stopAccessingSecurityScopedResource().
    func resolveDefault() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 bookmarkDataIsStale: &stale) else { return nil }
        url.startAccessingSecurityScopedResource()
        return url
    }
}
