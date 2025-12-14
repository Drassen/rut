//
//  CoreServices.swift
//  Rut
//

import Foundation
import Combine
import SwiftUI

// MARK: - Protocols used by import/export services

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

// MARK: - Toast types

struct Toast {
    enum Level { case info, error }
    let level: Level
    let message: String

    static func info(_ message: String) -> Toast { Toast(level: .info, message: message) }
    static func error(_ message: String) -> Toast { Toast(level: .error, message: message) }
}

// MARK: - Toast manager

final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var message: String = ""
    @Published var isVisible: Bool = false
    @Published var level: Toast.Level = .info
    
    private var dismissWorkItem: DispatchWorkItem?

    init() {}

    func show(_ toast: Toast) {
        dismissWorkItem?.cancel()
        
        DispatchQueue.main.async {
            self.message = toast.message
            self.level = toast.level
            self.isVisible = true
        }
        
        ErrorLogger.shared.log("TOAST: \(toast.message)")
        
        let workItem = DispatchWorkItem { [weak self] in
            withAnimation {
                self?.isVisible = false
            }
        }
        
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    func show(_ message: String) { show(.info(message)) }

    func show(message: String, kind: Toast.Level = .info) {
        show(Toast(level: kind, message: message))
    }

    func showError(_ error: Error) {
        show(.error(error.localizedDescription))
    }
}

// MARK: - CoreServices

final class CoreServices: ObservableObject {
    static let shared = CoreServices()

    @Published var navStore: NavigationStore
    @Published var toastManager: ToastManager

    let importServices: [RouteImporting]
    let exportServices: [any RouteExporting]

    private var cancellables: Set<AnyCancellable> = []

    private init(
        navStore: NavigationStore = NavigationStore(),
        toastManager: ToastManager = .shared
    ) {
        self.navStore = navStore
        self.toastManager = toastManager

        // Register importers
        self.importServices = [
            A109ImportService(),
            FPLImportService(),
            RTEImportService(),
            RUTImportService(),
            APTImportService(),
            NAVImportService()
        ]

        // Register exporters
        self.exportServices = [
            A109P01SetExportService(),
            FPLExportService(),
            RTEExportService(),
            RUTExportService(),
            APTExportService(),
            NAVExportService()
        ]

        toastManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        navStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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

                let tmpStore = NavigationStore()
                tmpStore.document = newDoc
                tmpStore.addOrMerge(document: doc)
                newDoc = tmpStore.document
                
            } catch {
                ErrorLogger.shared.log(error)
                toastManager.showError(error)
            }
        }

        navStore.addOrMerge(document: newDoc)

        // FIX: Bytte till _ = ... för att tysta varningen om oanvänd variabel
        _ = newDoc.routes.map { $0.id }
        
        navStore.deriveUserAirportsIfNeeded()

        // --- VIKTIGT ---
        // Vi kommenterar ut renumberWaypoints eftersom det döper om importade
        // waypoints till "WPT1", "WPT2" etc, vilket förstör original-IDt.
        // navStore.renumberWaypoints(forRouteIds: importedRouteIds)

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
