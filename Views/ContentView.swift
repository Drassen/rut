import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Foundation

// MARK: - Helper Structs

struct ExportContainer: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct EditorWrapper: Identifiable {
    let id = UUID()
    let mode: PointEditorView.EditMode
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case a109 = "A109 PCMCIA"
    case fpl = "ForeFlight FPL"
    case rte = "Garmin RTE"
    case rut = "Rut .RUT"
    case apt = "User Airports .APT"
    case nav = "User Navaids .NAV"
    
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var navStore: NavigationStore
    @EnvironmentObject var toastManager: ToastManager
    
    @State private var isImporting = false
    @State private var showDatabase = false
    @State private var editorSheet: EditorWrapper?
    
    @State private var exportFormat: ExportFormat = .a109
    @State private var exportContainer: ExportContainer?
    
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
                            //.frame(maxWidth: .infinity)
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
                    Text("Import files (FPL, RTE, P01, APT, NAV)")
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
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        let uNvCount = navStore.document.userNavaids.count
                        if uNvCount > 0 {
                            Label("\(uNvCount) Nav", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        let uWpCount = navStore.document.userWaypoints.count
                        if uWpCount > 0 {
                            Label("\(uWpCount) Wpt", systemImage: "mappin.and.ellipse")
                                .font(.headline)
                                .foregroundColor(.secondary)
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
                        // ÄNDRAT: Callback har nu bara 'point' (inga route/index)
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
                    
                    // Export
                    HStack {
                        Picker("Format", selection: $exportFormat) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(.menu)
                       
                        Button {
                            prepareExport()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
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

        .sheet(item: $exportContainer) { container in
            MultiFileExportController(fileURLs: container.urls) { success in
                if !success { }
            }
        }
        
        .onOpenURL { url in
            importURLs([url])
        }
    }
    
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
        alert.addTextField { tf in
            tf.text = currentName
        }
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
    
    private func prepareExport() {
        let hasDataToExport: Bool
        switch exportFormat {
        case .apt: hasDataToExport = !navStore.document.userAirports.isEmpty
        case .nav: hasDataToExport = !navStore.document.userNavaids.isEmpty
        case .fpl, .rte: hasDataToExport = !navStore.routes.isEmpty
        case .rut, .a109:
            hasDataToExport = !navStore.routes.isEmpty ||
                              !navStore.document.userAirports.isEmpty ||
                              !navStore.document.userNavaids.isEmpty ||
                              !navStore.document.userWaypoints.isEmpty
        }
        
        guard hasDataToExport else {
            toastManager.show(message: "No data available to export for \(exportFormat.rawValue).", kind: .info)
            return
        }
        
        let registry = ImportExportRegistry.shared
        guard let exporter = {
            switch exportFormat {
            case .fpl: return registry.exporter(forFormatName: "ForeFlight FPL")
            case .rte: return registry.exporter(forFormatName: "Garmin RTE")
            case .rut: return registry.exporter(forFormatName: "Rut .RUT")
            case .a109: return registry.exporter(forFormatName: "A109 PCMCIA")
            case .apt: return registry.exporter(forFormatName: "Rut User Airports (.APT)")
            case .nav: return registry.exporter(forFormatName: "Rut User Navaids (.NAV)")
            }
        }() else {
            toastManager.show(message: "Exporter not available.")
            return
        }
        
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
                urls.append(fileURL.standardizedFileURL)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.exportContainer = ExportContainer(urls: urls)
            }
        } catch {
            ErrorLogger.shared.logError(error)
            toastManager.show(message: error.localizedDescription)
        }
    }
}
