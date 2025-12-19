import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Foundation

// MARK: - Helper Structs

struct EditorWrapper: Identifiable {
    let id = UUID()
    let mode: PointEditorView.EditMode
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case a109 = "A109 PCMCIA"
    case uh60m = "UH60M PCMCIA (Not implemented)"
    case h145 = "H145 PCMCIA (Not implemented)"
    
    case rte = "Garmin route (.RTE)"
    
    case rut = "RUT complete set (.RUT)"
    case fpl = "User Routes (.FPL)"
    case apt = "User Airports (.APT)"
    case nav = "User Navaids (.NAV)"
    
    var id: String { rawValue }
}

struct ExportContainer: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ContentView: View {
    @EnvironmentObject var navStore: NavigationStore
    @EnvironmentObject var toastManager: ToastManager
    
    // Import state
    @State private var isImporting = false
    
    // Export state
    @State private var isSelectingExportFolder = false // For A109 direct write
    @State private var exportContainer: ExportContainer? // For other formats (Share sheet)
    @State private var showA109MissingDataAlert = false // Varning för saknad data
    
    @State private var showDatabase = false
    @State private var editorSheet: EditorWrapper?
    
    @State private var exportFormat: ExportFormat = .a109
    
    // NYTT: Helper för att hämta version
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    
    private var hasAnyData: Bool {
        !navStore.routes.isEmpty ||
        !navStore.document.userAirports.isEmpty ||
        !navStore.document.userNavaids.isEmpty ||
        !navStore.document.userWaypoints.isEmpty ||
        !navStore.document.systemAirports.isEmpty ||
        !navStore.document.systemNavaids.isEmpty
    }
    
    var body: some View {
        ZStack {
            if !hasAnyData {
                Image("bgimage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            VStack(spacing: 16) {
                if !hasAnyData {
                    Spacer()
                }
                // Top Controls
                HStack(spacing: 12) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .fileImporter(
                        isPresented: $isImporting,
                        allowedContentTypes: [.data],
                        allowsMultipleSelection: true,
                        onCompletion: handleImport(result:)
                    )
                }
                .padding(.horizontal)
                
                if !hasAnyData {
                    Text(".RUT .FPL .RTE .P01 .APT .NAV")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    Spacer()
                } else {
                    // Routes
                    if !navStore.routes.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(navStore.routes) { route in
                                    RouteTileView(
                                        route: route,
                                        isActive: route.id == navStore.activeRouteId,
                                        onTap: { handleRouteTap(route) },
                                        onClose: { navStore.deleteRoute(route) }
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Counters
                    HStack(spacing: 16) {
                        let uApCount = navStore.document.userAirports.count
                        if uApCount > 0 {
                            Label("\(uApCount) Apt", systemImage: "airplane")
                                .font(.headline).foregroundColor(.secondary)
                        }
                        let uNvCount = navStore.document.userNavaids.count
                        if uNvCount > 0 {
                            Label("\(uNvCount) Nav", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.headline).foregroundColor(.secondary)
                        }
                        let uWpCount = navStore.document.userWaypoints.count
                        if uWpCount > 0 {
                            Label("\(uWpCount) Wpt", systemImage: "mappin.and.ellipse")
                                .font(.headline).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            showDatabase = true
                        } label: {
                            Label("Database", systemImage: "list.bullet.rectangle")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                    
                    // Map
                    RutMapView(onPointTap: { point in
                        switch point.kind {
                        case .userWaypoint:
                            if let wp = navStore.document.userWaypoints.first(where: { $0.id == point.name }) {
                                editorSheet = EditorWrapper(mode: .waypoint(wp))
                            }
                        case .userAirport:
                            if let ap = navStore.document.userAirports.first(where: { $0.id == point.name }) {
                                editorSheet = EditorWrapper(mode: .airport(ap))
                            }
                        case .userNavaid:
                            if let nv = navStore.document.userNavaids.first(where: { $0.id == point.name }) {
                                editorSheet = EditorWrapper(mode: .navaid(nv))
                            }
                        case .systemAirport:
                            if let ap = navStore.document.systemAirports.first(where: { $0.id == point.name }) {
                                editorSheet = EditorWrapper(mode: .systemAirport(ap))
                            }
                        case .systemNavaid:
                            if let nv = navStore.document.systemNavaids.first(where: { $0.id == point.name }) {
                                editorSheet = EditorWrapper(mode: .systemNavaid(nv))
                            }
                        }
                    })
                    .environmentObject(navStore)
                    .frame(minHeight: 250)
                    
                    // Export Controls
                    HStack {
                        Picker("Format", selection: $exportFormat) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(.menu)
                        
                        Button {
                            handleExportButtonTap()
                        } label: {
                            // Label changes based on context (PCMCIA formats vs others)
                            if exportFormat == .a109 || exportFormat == .uh60m || exportFormat == .h145 {
                                Label("Save to Drive", systemImage: "externaldrive.badge.plus")
                            } else {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        // Trigger for A109 Folder Selection
                        .fileImporter(
                            isPresented: $isSelectingExportFolder,
                            allowedContentTypes: [.folder],
                            allowsMultipleSelection: false,
                            onCompletion: { result in
                                handleA109ExportFolderSelection(result: result)
                            }
                        )
                        // ALERT: Varning om data saknas vid A109
                        .alert("Incomplete Data", isPresented: $showA109MissingDataAlert) {
                            Button("Cancel", role: .cancel) { }
                            Button("Continue") {
                                // Fortsätt till mapp-val om användaren godkänner
                                isSelectingExportFolder = true
                            }
                        } message: {
                            Text("Do you want to continue the export without user airports or user navaids?")
                        }
                    }
                    .padding()
                }
                
                // Versionsnummer längst ner
                if !hasAnyData {
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.bottom, 4)
                }
            }
            
            ToastOverlay()
                .environmentObject(toastManager)
        }
        
        .sheet(item: $editorSheet) { wrapper in
            NavigationStack {
                PointEditorView(mode: wrapper.mode, isNew: false)
            }
        }
        
        .sheet(isPresented: $showDatabase) {
            DatabaseListView()
                .environmentObject(navStore)
        }
        
        // Trigger for Standard Share Sheet (Non-A109)
        .sheet(item: $exportContainer) { container in
            MultiFileExportController(fileURLs: container.urls) { success in
                if !success { }
            }
        }
        
        .onOpenURL { url in
            importURLs([url])
        }
    }
    
    // MARK: - Logic
    
    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            ErrorLogger.shared.logError(error)
            toastManager.show(message: error.localizedDescription)
        case .success(let urls):
            importURLs(urls)
        }
    }
    
    private func importURLs(_ urls: [URL]) {
        Task {
            await CoreServices.shared.importDocuments(from: urls)
        }
    }
    
    private func handleRouteTap(_ route: Route) {
        if navStore.activeRouteId == route.id {
            showRenameDialog(for: route)
        } else {
            navStore.setActiveRoute(route)
        }
    }
    
    private func showRenameDialog(for route: Route) {
        let currentName = route.name
        let alert = UIAlertController(title: "Rename route", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.text = currentName }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in }))
        alert.addAction(UIAlertAction(title: "Save", style: .default, handler: { _ in
            if let newName = alert.textFields?.first?.text {
                navStore.updateRouteName(route, newName: newName)
            }
        }))
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(alert, animated: true, completion: nil)
        }
    }
    
    // MARK: - Export Logic
    
    private func canExport() -> Bool {
        let hasData: Bool
        switch exportFormat {
        case .apt: hasData = !navStore.document.userAirports.isEmpty
        case .nav: hasData = !navStore.document.userNavaids.isEmpty
        case .fpl, .rte: hasData = !navStore.routes.isEmpty
        case .rut, .a109, .uh60m, .h145: // Inkludera de nya formaten i datakollen
            hasData = !navStore.routes.isEmpty ||
                      !navStore.document.userAirports.isEmpty ||
                      !navStore.document.userNavaids.isEmpty ||
                      !navStore.document.userWaypoints.isEmpty
        }
        
        if !hasData {
            toastManager.show(message: "No data available to export for \(exportFormat.rawValue).", kind: .info)
            return false
        }
        return true
    }
    
    private func handleExportButtonTap() {
        // Om UH-60M eller H145 är vald, stoppa direkt med ett meddelande
        if exportFormat == .uh60m {
            toastManager.show(message: "UH-60M export is not implemented yet.", kind: .info)
            return
        }
        if exportFormat == .h145 {
            toastManager.show(message: "H145 export is not implemented yet.", kind: .info)
            return
        }
        
        guard canExport() else { return }
        
        if exportFormat == .a109 {
            // Kontrollera om data saknas
            let missingAirports = navStore.document.userAirports.isEmpty
            let missingNavaids = navStore.document.userNavaids.isEmpty
            
            if missingAirports || missingNavaids {
                // Visa varning -> Alert triggar 'isSelectingExportFolder' om man väljer Continue
                showA109MissingDataAlert = true
            } else {
                // Allt ok, öppna mapp-väljare direkt
                isSelectingExportFolder = true
            }
        } else {
            // Övriga format -> Standard Share Sheet
            prepareStandardExport()
        }
    }
    
    // MARK: - Standard Export (FPL, RTE, etc)
    
    private func prepareStandardExport() {
            // Hämta rätt exporter baserat på ID (säkrare än namn)
            let exporterId: String
            switch exportFormat {
            case .fpl: exporterId = "fpl"
            case .rte: exporterId = "rte"
            case .rut: exporterId = "rut"
            case .apt: exporterId = "apt" // Se till att APTExportService har id="apt"
            case .nav: exporterId = "nav" // Se till att NAVExportService har id="nav"
            default: return
            }
            
            // Fråga CoreServices direkt
            guard let exporter = CoreServices.shared.exporter(withId: exporterId) else {
                toastManager.show(message: "Exporter for '\(exporterId)' not found.")
                return
            }
            
            // Resten är samma som förut...
            do {
                let generatedFiles = try exporter.export(document: navStore.document, routes: navStore.routes)
                if generatedFiles.isEmpty {
                    toastManager.show(message: "Nothing to export.", kind: .info)
                    return
                }
                
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                var urls: [URL] = []
                for file in generatedFiles {
                    let fileURL = tempDir.appendingPathComponent(file.filename)
                    try file.data.write(to: fileURL, options: .atomic)
                    urls.append(fileURL)
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.exportContainer = ExportContainer(urls: urls)
                }
                
            } catch {
                ErrorLogger.shared.logError(error)
                toastManager.show(message: error.localizedDescription)
            }
        }
    
    // MARK: - A109 Direct Export (Folder Selection)
    
    private func handleA109ExportFolderSelection(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            toastManager.showError(error)
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            performA109DirectExport(to: folderURL)
        }
    }
    
    private func performA109DirectExport(to folderURL: URL) {
            // Hämta direkt via ID "a109" (kontrollera att A109PCMCIAExportService har id="a109")
            guard let exporter = CoreServices.shared.exporter(withId: "a109") else {
                toastManager.show(message: "A109 Exporter not available.")
                return
            }
            
            do {
                let generatedFiles = try exporter.export(document: navStore.document, routes: navStore.routes)
                if generatedFiles.isEmpty {
                    toastManager.show(message: "Nothing to export.", kind: .info)
                    return
                }
                
                let secured = folderURL.startAccessingSecurityScopedResource()
                defer { if secured { folderURL.stopAccessingSecurityScopedResource() } }
                
                var successCount = 0
                for file in generatedFiles {
                    let destinationURL = folderURL.appendingPathComponent(file.filename)
                    try file.data.write(to: destinationURL, options: .atomic)
                    destinationURL.cleanAppleAttributes()
                    successCount += 1
                }
                
                try cleanupDotFiles(in: folderURL)
                
                toastManager.show(message: "Saved \(successCount) files to \(folderURL.lastPathComponent)", kind: .info)
                
            } catch {
                ErrorLogger.shared.logError(error)
                toastManager.show(message: "Export failed: \(error.localizedDescription)")
            }
        }
    
    private func cleanupDotFiles(in folderURL: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [])
        
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") {
                do {
                    try fileManager.removeItem(at: fileURL)
                    print("Deleted system artifact: \(name)")
                } catch {
                    print("Failed to delete \(name): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - URL Extension (Städning)

extension URL {
    func cleanAppleAttributes() {
        self.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath = fileSystemPath else { return }
            let attributesToRemove = [
                "com.apple.quarantine", "com.apple.FinderInfo",
                "com.apple.ResourceFork", "com.apple.metadata:_kMDItemUserTags",
                "com.apple.lastuseddate#PS"
            ]
            for attr in attributesToRemove {
                removexattr(fileSystemPath, attr, 0)
            }
        }
    }
}
