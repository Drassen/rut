//
//  CoreServices.swift
//  Rut
//

import Foundation
import Combine
import SwiftUI

// MARK: - Protocols used by import/export services

struct ExportedFile: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
}

protocol RouteImporting {
    var supportedExtensions: [String] { get }
    func importDocument(from url: URL) throws -> NavigationDocument
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
            RTEImportService(),
            RUTImportService(),
            APTImportService(),
            NAVImportService(),
            ACOImportService()
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
            KMLVectorExportService()
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

    @MainActor
    func importDocuments(from urls: [URL]) async {
        var newDoc = NavigationDocument()
        var importedVectorLayers: [VectorLayer] = []

        var importedRoutePoints = 0
        var importedAirports = 0
        var importedNavaids = 0
        var importedWaypoints = 0
        var importedRoutesCount = 0

        for url in urls {
            let originalName = url.lastPathComponent
            toastManager.show(message: "Import started: \(originalName)", kind: .info)
            ErrorLogger.shared.log("Import started: \(originalName)")

            if url.pathExtension.lowercased() == "zip" {
                let err = RutError.zipNotSupported
                ErrorLogger.shared.log(err)
                toastManager.showError(err)
                continue
            }

            guard let baseImporter = importer(for: url) else {
                let err = RutError.invalidFormat("Unsupported file: \(originalName)")
                ErrorLogger.shared.log(err)
                toastManager.showError(err)
                continue
            }

            do {
                // Vi kopierar alltid till temp först för att undvika problem med låsta filer
                let tempDir = FileManager.default.temporaryDirectory
                let localURL = tempDir.appendingPathComponent(originalName)
                try? FileManager.default.removeItem(at: localURL)
                
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                
                try FileManager.default.copyItem(at: url, to: localURL)
                defer { try? FileManager.default.removeItem(at: localURL) }

                // Inject context for A109
                let finalImporter: RouteImporting
                if baseImporter is A109ImportService {
                    finalImporter = A109ImportService(
                        existingAirports: navStore.document.userAirports,
                        existingNavaids: navStore.document.userNavaids,
                        existingWaypoints: navStore.document.userWaypoints
                    )
                } else {
                    finalImporter = baseImporter
                }
                
                let doc = try finalImporter.importDocument(from: localURL)

                importedRoutePoints += doc.routes.reduce(0) { $0 + $1.pointRefs.count }
                importedRoutesCount += doc.routes.count
                importedAirports += doc.userAirports.count
                importedNavaids += doc.userNavaids.count
                importedWaypoints += doc.userWaypoints.count

                // Vi bygger upp en temporär store för att merga filen korrekt
                // Collect vector layers from each imported file (avoid duplicating by name)
                for layer in doc.vectorLayers where !layer.isSystem {
                    if !importedVectorLayers.contains(where: { $0.name == layer.name }) {
                        importedVectorLayers.append(layer)
                    }
                }

                let tmpStore = NavigationStore()
                tmpStore.document = newDoc
                tmpStore.addOrMerge(document: doc)
                newDoc = tmpStore.document
                
            } catch {
                ErrorLogger.shared.log(error)
                toastManager.showError(error)
            }
        }

        // Merge navigation data into main store
        navStore.addOrMerge(document: newDoc)

        // Sync vector layers collected from imported files (e.g. .rut files)
        if !importedVectorLayers.isEmpty {
            var docWithVectors = newDoc
            docWithVectors.vectorLayers = importedVectorLayers
            vectorStore.syncFromDocument(docWithVectors)
        }
        
        // Tysta varningen om oanvänd variabel med _
        _ = newDoc.routes.map { $0.id }
        
        navStore.deriveUserAirportsIfNeeded()

        let totalItems = importedRoutePoints + importedAirports + importedNavaids + importedWaypoints + importedRoutesCount
        
        if totalItems > 0 {
            var parts: [String] = []
            if importedRoutesCount > 0 { parts.append("\(importedRoutesCount) routes") }
            if importedAirports > 0 { parts.append("\(importedAirports) airports") }
            if importedNavaids > 0 { parts.append("\(importedNavaids) navaids") }
            if importedWaypoints > 0 { parts.append("\(importedWaypoints) waypoints") }
            
            let message = "Imported: " + parts.joined(separator: ", ")
            toastManager.show(message: message, kind: .info)
        } else {
            toastManager.show(message: "Import finished but no data found.", kind: .info)
        }
    }
}
