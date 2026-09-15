//
//  CoreServices.swift
//  Rut
//

import Foundation
import Combine
import SwiftUI
import MapKit

// MARK: - Protocols used by import/export services

struct ExportedFile: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
}

protocol RouteImporting {
    var supportedExtensions: [String] { get }
    func importDocument(from url: URL) throws -> NavigationDocument
    /// Like `importDocument`, plus one line per record that could not be parsed or was
    /// skipped, with the reason. Shown in the import report after every import.
    /// (A protocol requirement, not only an extension, so importers' own versions are used.)
    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String])
}

extension RouteImporting {
    func importDocumentWithWarnings(from url: URL) throws -> (NavigationDocument, [String]) {
        (try importDocument(from: url), [])
    }
}

protocol RouteExporting {
    var id: String { get }
    var displayName: String { get }
    var supportedExtensions: [String] { get }
    func export(document: NavigationDocument,
                selectedRoutes: [Route]) throws -> [ExportedFile]
}

extension RouteExporting {
    func export(document: NavigationDocument,
                routes: [Route]) throws -> [ExportedFile] {
        try export(document: document, selectedRoutes: routes)
    }
}

// MARK: - CoreServices

enum AppMode { case navigation, vector }

final class CoreServices: ObservableObject {
    static let shared = CoreServices()

    @Published var navStore: NavigationStore
    @Published var toastManager: ToastManager
    @Published var vectorStore: VectorStore
    @Published var appMode: AppMode = .navigation
    @Published var mapCamera: MapCameraPosition = .automatic

    let importServices: [RouteImporting]
    let exportServices: [any RouteExporting]

    private var cancellables: Set<AnyCancellable> = []

    private init(
        navStore: NavigationStore = NavigationStore(),
        toastManager: ToastManager = .shared
    ) {
        self.navStore = navStore
        self.toastManager = toastManager
        self.vectorStore = VectorStore()

        // Register importers
        self.importServices = [
            A109ImportService(),
            FPLImportService(),
            GPXImportService(),
            KMLImportService(),
            KMZImportService(),
            RTEImportService(),
            RUTImportService(),
            APTImportService(),
            NAVImportService(),
            ACOImportService(),
            GeoJSONVectorImportService(),
            RutVectorImportService(),
            SAPIImportService()
        ]

        // Register exporters
        self.exportServices = [
            A109PCMCIAExportService(),
            FPLExportService(),
            GPXExportService(),
            KMLAirportsExportService(),
            KMLNavaidsExportService(),
            KMLWaypointsExportService(),
            KMLRouteExportService(),
            RTEExportService(),
            RUTExportService(),
            APTExportService(),
            NAVExportService(),
            KMLVectorExportService(),
            GeoJSONVectorExportService(),
            RutVectorExportService()
        ]

        toastManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        navStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        vectorStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Deselect vector selection when leaving vector mode
        $appMode
            .dropFirst()
            .sink { [weak self] mode in
                if mode != .vector { self?.vectorStore.deselectShape() }
            }
            .store(in: &cancellables)
    }

    /// Returns a NavigationDocument with current vectorLayers from VectorStore (non-system).
    func currentDocument() -> NavigationDocument {
        var doc = navStore.document
        doc.vectorLayers = vectorStore.documentLayers()
        return doc
    }

    // MARK: - Importer lookup

    func importer(for url: URL) -> RouteImporting? {
        let ext = url.pathExtension.lowercased()
        return importServices.first { $0.supportedExtensions.contains(ext) }
    }

    func importer(forExtension ext: String) -> RouteImporting? {
        let lower = ext.lowercased()
        return importServices.first { $0.supportedExtensions.contains(lower) }
    }

    // MARK: - Exporter lookup

    func exporter(withId id: String) -> (any RouteExporting)? {
        let needle = id.lowercased()
        return exportServices.first { $0.id.lowercased() == needle }
    }

    func exporter(forFileExtension ext: String) -> (any RouteExporting)? {
        let needle = ext.lowercased()
        return exportServices.first { $0.supportedExtensions.map { $0.lowercased() }.contains(needle) }
    }

    func exporter(forDisplayName name: String) -> (any RouteExporting)? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return exportServices.first { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
    }

    // MARK: - Import

    /// One unit of an import: a single file, or all P01 files of one A109 card.
    private enum ImportUnit {
        case file(URL)
        case a109Card(name: String, files: [URL])
    }

    /// Expands chosen folders into their files and groups the P01 files of each A109 card (files
    /// from the same folder), so the card's routes are read against its own point files. Card
    /// files that are not navigation data (header, checksums, logs) are left out.
    private func importUnits(for urls: [URL]) -> [ImportUnit] {
        var files: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                files += contents
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                files.append(url)
            }
        }

        var units: [ImportUnit] = []
        var cards: [(folder: URL, files: [URL])] = []
        for file in files {
            let name = file.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if A109ImportService.cardSupportFiles.contains(name) { continue }
            guard file.pathExtension.lowercased() == "p01" else {
                units.append(.file(file))
                continue
            }
            let folder = file.deletingLastPathComponent().standardizedFileURL
            if let index = cards.firstIndex(where: { $0.folder == folder }) {
                cards[index].files.append(file)
            } else {
                cards.append((folder, [file]))
            }
        }
        units += cards.map { card in
            .a109Card(name: card.files.count == 1 ? card.files[0].lastPathComponent : card.folder.lastPathComponent,
                      files: card.files)
        }
        return units
    }

    /// Copies files into a fresh temporary folder, keeping their names, so locked or
    /// security-scoped originals are never parsed directly.
    private func copyToTemporaryFolder(_ files: [URL]) throws -> (folder: URL, files: [URL]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copies = try files.map { file -> URL in
            let target = folder.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: target)
            return target
        }
        return (folder, copies)
    }

    /// Parses one import unit with the importer for its format.
    private func importUnit(_ unit: ImportUnit, kmlAsVector: Bool,
                            standalonePointKind: KMLImportService.StandalonePointKind) throws -> (NavigationDocument, [String]) {
        switch unit {
        case .a109Card(_, let files):
            let copy = try copyToTemporaryFolder(files)
            defer { try? FileManager.default.removeItem(at: copy.folder) }
            return try A109ImportService().importCardWithWarnings(files: copy.files)

        case .file(let url):
            if url.pathExtension.lowercased() == "zip" { throw RutError.zipNotSupported }
            // KMZ counted as zip by some systems — use extension-based lookup
            guard let baseImporter = importer(for: url) else {
                throw RutError.invalidFormat("Unsupported file: \(url.lastPathComponent)")
            }
            let copy = try copyToTemporaryFolder([url])
            defer { try? FileManager.default.removeItem(at: copy.folder) }

            // Remap KML/KMZ to vector or navigation importers as chosen
            let finalImporter: RouteImporting
            switch (url.pathExtension.lowercased(), kmlAsVector) {
            case ("kml", true):  finalImporter = KMLVectorImportService()
            case ("kmz", true):  finalImporter = KMZImportService()
            case ("kmz", false): finalImporter = KMZNavigationImportService(standalonePointKind: standalonePointKind)
            case ("kml", false): finalImporter = KMLImportService(standalonePointKind: standalonePointKind)
            default:             finalImporter = baseImporter
            }
            return try finalImporter.importDocumentWithWarnings(from: copy.files[0])
        }
    }

    @MainActor
    func importDocuments(from urls: [URL], kmlAsVector: Bool = false,
                         standalonePointKind: KMLImportService.StandalonePointKind = .waypoint) async {
        var newDoc = NavigationDocument()
        var importedVectorLayers: [VectorLayer] = []

        // Items found in the files, before skipping data that already exists in the app
        var foundItems = 0

        // Per-file errors are collected and reported in the final summary toast.
        // ToastManager shows one message at a time, so a toast shown here would
        // be overwritten immediately by the summary.
        var failures: [(file: String, message: String)] = []

        // Skipped items (identical data, ID conflicts) and parse warnings, each with its
        // reason. Shown together with the failures in a report dialog after the import.
        var reportLines: [String] = []

        // Access to the chosen files and folders lasts for the whole import
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        for unit in importUnits(for: urls) {
            let label: String
            switch unit {
            case .file(let url): label = url.lastPathComponent
            case .a109Card(let name, _): label = name
            }
            toastManager.show(message: "Import started: \(label)", kind: .info)
            ErrorLogger.shared.log("Import started: \(label)")

            do {
                // Every importer reports what it could not parse or skipped, with the reason
                let (doc, importWarnings) = try importUnit(unit, kmlAsVector: kmlAsVector,
                                                           standalonePointKind: standalonePointKind)
                reportLines += importWarnings.map { "\(label): \($0)" }

                foundItems += doc.routes.count + doc.userAirports.count
                            + doc.userNavaids.count + doc.userWaypoints.count

                // Collect vector layers; same-named layers from several files are merged
                for layer in doc.vectorLayers where !layer.isSystem {
                    foundItems += VectorStore.mergeLayer(layer, into: &importedVectorLayers, skipped: &reportLines)
                }

                // Vi bygger upp en temporär store för att merga filerna i samma import korrekt
                let tmpStore = NavigationStore()
                tmpStore.document = newDoc
                reportLines += tmpStore.addOrMerge(document: doc).skipped
                newDoc = tmpStore.document

            } catch {
                ErrorLogger.shared.log(error)
                failures.append((label, error.localizedDescription))
            }
        }

        // Merge into the main stores. Data identical to existing data is skipped;
        // the returned counts are what was actually added.
        let added = navStore.addOrMerge(document: newDoc)
        reportLines += added.skipped

        var addedShapes = 0
        if !importedVectorLayers.isEmpty {
            var docWithVectors = newDoc
            docWithVectors.vectorLayers = importedVectorLayers
            addedShapes = vectorStore.syncFromDocument(docWithVectors, skipped: &reportLines)
        }

        navStore.deriveUserAirportsIfNeeded()

        var summary: String
        if added.total + addedShapes > 0 {
            var parts: [String] = []
            if added.routes > 0 { parts.append("\(added.routes) routes") }
            if added.airports > 0 { parts.append("\(added.airports) airports") }
            if added.navaids > 0 { parts.append("\(added.navaids) navaids") }
            if added.waypoints > 0 { parts.append("\(added.waypoints) waypoints") }
            if addedShapes > 0 { parts.append("\(addedShapes) shapes") }

            summary = "Imported: " + parts.joined(separator: ", ")
        } else if foundItems > 0 {
            summary = "Nothing new to import – all data already exists."
        } else if failures.isEmpty {
            summary = "Import finished but no data found."
        } else {
            summary = ""
        }

        if failures.isEmpty {
            toastManager.show(message: summary, kind: .info)
        } else {
            let failureText: String
            if failures.count == 1, let f = failures.first {
                failureText = "\(f.file): \(f.message)"
            } else {
                failureText = "\(failures.count) files failed. \(failures[0].file): \(failures[0].message)"
            }
            summary = summary.isEmpty ? "Import failed – \(failureText)" : "\(summary). Failed – \(failureText)"
            toastManager.show(message: summary, kind: .error)
        }

        // Every failure and skipped item, with its reason, in a dialog after the import
        let failureLines = failures.map { "\($0.file): import failed – \($0.message)" }
        if !failureLines.isEmpty || !reportLines.isEmpty {
            var titleParts: [String] = []
            if !failureLines.isEmpty { titleParts.append("\(failureLines.count) failed") }
            if !reportLines.isEmpty { titleParts.append("\(reportLines.count) problem(s)") }
            toastManager.importWarningTitle = "Import report: " + titleParts.joined(separator: ", ")
            toastManager.importWarnings = failureLines + Self.sortedReportLines(reportLines)
        }
    }

    /// Orders report lines by kind (routes, airports, navaids, waypoints, shapes, other)
    /// and then naturally by name, so "Airport 101" comes before "Airport 304".
    private static func sortedReportLines(_ lines: [String]) -> [String] {
        let kindOrder = ["Route ", "Airport ", "Navaid ", "Waypoint ", "Shape "]
        func rank(_ line: String) -> Int {
            kindOrder.firstIndex { line.hasPrefix($0) } ?? kindOrder.count
        }
        return lines.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}
