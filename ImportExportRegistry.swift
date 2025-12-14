//
//  ImportExportRegistry.swift
//  Rut
//

import Foundation

/// Compatibility shim for older code that referenced `ImportExportRegistry`
/// for importer/exporter lookup.
///
/// Everything forwards to CoreServices.shared, but with better matching logic.
struct ImportExportRegistry {
    static let shared = ImportExportRegistry()

    fileprivate let core = CoreServices.shared

    // MARK: - Import

    func importer(for url: URL) -> RouteImporting? {
        core.importer(for: url)
    }

    func importer(forExtension ext: String) -> RouteImporting? {
        core.importer(forExtension: ext)
    }

    // MARK: - Export – match helper

    private func normalize(_ s: String) -> String {
        // normalize for loose matching: keep letters+digits only
        let lower = s.lowercased()
        return lower.filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Export – instance methods

    /// Key can be:
    /// - exporter id ("gpx", "fpl", ...)
    /// - file extension ("gpx", "fpl", ...)
    /// - display name ("Garmin GPX", "ForeFlight FPL", ...)
    func exporter(for key: Any) -> (any RouteExporting)? {
        let raw = String(describing: key)

        // 1) Exact displayName match
        if let byName = core.exporter(forDisplayName: raw) {
            return byName
        }

        // 2) Try id match
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let byId = core.exporter(withId: s) {
            return byId
        }

        // 3) Try as extension
        if let byExt = core.exporter(forFileExtension: s) {
            return byExt
        }

        // 4) Loose match by normalized displayName
        let needle = normalize(raw)
        if let loose = core.exportServices.first(where: { normalize($0.displayName) == needle }) {
            return loose
        }

        // 5) A few friendly aliases (optional but nice)
        switch needle {
        case "foreflightfpl":
            return core.exporter(withId: "fpl") ?? core.exporter(forFileExtension: "fpl")
        case "garmingpx":
            return core.exporter(withId: "gpx") ?? core.exporter(forFileExtension: "gpx")
        case "garmirte":
            return core.exporter(withId: "rte") ?? core.exporter(forFileExtension: "rte")
        case "rutrut":
            return core.exporter(withId: "rut") ?? core.exporter(forFileExtension: "rut")
        default:
            return nil
        }
    }

    func exporter(_ key: Any) -> (any RouteExporting)? {
        exporter(for: key)
    }

    func exporter(for idOrExt: String) -> (any RouteExporting)? {
        exporter(for: idOrExt as Any)
    }

    // MARK: - Export – static helpers

    static func exporter(for key: Any) -> (any RouteExporting)? {
        shared.exporter(for: key)
    }

    static func exporter(_ key: Any) -> (any RouteExporting)? {
        shared.exporter(for: key)
    }

    static func exporter(for idOrExt: String) -> (any RouteExporting)? {
        shared.exporter(for: idOrExt)
    }

    static func exporter(withId id: String) -> (any RouteExporting)? {
        shared.core.exporter(withId: id)
    }

    static func exporter(forFileExtension ext: String) -> (any RouteExporting)? {
        shared.core.exporter(forFileExtension: ext)
    }

    // MARK: - Legacy convenience: forFormatName

    func exporter(forFormatName name: String) -> (any RouteExporting)? {
        exporter(for: name as Any)
    }

    static func exporter(forFormatName name: String) -> (any RouteExporting)? {
        shared.exporter(forFormatName: name)
    }
    
    func debugExporters() -> [String] {
        // Anpassa beroende på var listan sitter i din kodbas:
        // Om du har CoreServices -> return core.exportServices.map { "\($0.id) | \($0.displayName) | ext=\($0.supportedExtensions)" }
        // Om registry själv håller listan -> använd den.
        CoreServices.shared.exportServices.map { "\($0.id) | \($0.displayName) | ext=\($0.supportedExtensions)" }
    }
}


