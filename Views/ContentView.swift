import SwiftUI
import UIKit
import MapKit
import UniformTypeIdentifiers
import Foundation

// MARK: - Helper Structs

struct EditorWrapper: Identifiable {
    let id = UUID()
    let mode: PointEditorView.EditMode
    var isNew: Bool = false
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case a109  = "A109 PCMCIA"
    case uh60m = "UH60M (Not implemented)"
    case h145  = "H145 (Not implemented)"
    case nh90  = "NH90 (Not implemented)"
    case rte   = "Garmin route (.RTE)"
    case gpx   = "GPX Route (.gpx)"
    case kml   = "KML"
    case fpl   = "User Routes (.FPL)"
    case apt   = "User Airports (.APT)"
    case nav   = "User Navaids (.NAV)"
    case rut   = "RUT complete set (.RUT)"

    var id: String { rawValue }

    var isPCMCIA: Bool { self == .a109 || self == .uh60m || self == .h145 || self == .nh90 }
}

struct ExportContainer: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - Stat Badge

private struct StatBadge: View {
    let icon: String
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(RutTheme.amber)
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(RutTheme.text)
            + Text(" \(label)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(RutTheme.textDim)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RutTheme.surface2)
        .overlay(Capsule().stroke(RutTheme.border, lineWidth: 1))
        .clipShape(Capsule())
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var navStore: NavigationStore
    @EnvironmentObject var toastManager: ToastManager
    @EnvironmentObject var core: CoreServices

    @Environment(\.horizontalSizeClass) private var sizeClass

    // Single file-importer driven by an enum to avoid SwiftUI's "last one wins" bug
    private enum FileImporterKind { case importing, exportFolder, defaultFile }
    @State private var activeImporter: FileImporterKind? = nil
    @State private var showSettingsSheet = false
    @State private var showA109ExportCompleteAlert = false
    @State private var exportContainer: ExportContainer?
    @State private var showA109MissingDataAlert = false
    @State private var showDatabase = false
    @State private var editorSheet: EditorWrapper?
    @State private var exportFormat: ExportFormat = .a109
    @State private var showKMLSubDialog = false
    @State private var longPressLat: Double = 0
    @State private var longPressLon: Double = 0
    @State private var showAddPointTypeMenu = false
    @State private var pendingKMLURLs: [URL] = []
    @State private var showKMLImportModeDialog = false
    @State private var showLayerPanel = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Group {
            mainView
        }
        .tint(RutTheme.amber)
        // ── Sheets & dialogs ──
        .sheet(item: $editorSheet) { wrapper in
            NavigationStack {
                PointEditorView(mode: wrapper.mode, isNew: wrapper.isNew)
            }
            .tint(RutTheme.amber)
        }
        .sheet(isPresented: $showDatabase) {
            DatabaseListView()
                .environmentObject(navStore)
                .tint(RutTheme.amber)
        }
        .sheet(item: $exportContainer) { container in
            MultiFileExportController(fileURLs: container.urls) { _ in }
        }
        .onOpenURL { url in importURLs([url]) }
        .confirmationDialog("Add Point", isPresented: $showAddPointTypeMenu, titleVisibility: .visible) {
            Button("Airport") {
                let ap = UserAirport(id: "", name: "", latitude: longPressLat, longitude: longPressLon, elevation: 0)
                editorSheet = EditorWrapper(mode: .airport(ap), isNew: true)
            }
            Button("Navaid") {
                let nv = UserNavaid(id: "", name: "", latitude: longPressLat, longitude: longPressLon, elevation: 0, magneticVariation: 0, frequency: 0)
                editorSheet = EditorWrapper(mode: .navaid(nv), isNew: true)
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("KML Export", isPresented: $showKMLSubDialog, titleVisibility: .visible) {
            if navStore.activeRouteId != nil              { Button("Active Route (.KML)")   { executeKMLExport(id: "kml-route")      } }
            if !navStore.document.userAirports.isEmpty   { Button("User Airports (.KML)")  { executeKMLExport(id: "kml-airports")   } }
            if !navStore.document.userNavaids.isEmpty    { Button("User Navaids (.KML)")   { executeKMLExport(id: "kml-navaids")    } }
            if !navStore.document.userWaypoints.isEmpty  { Button("User Waypoints (.KML)") { executeKMLExport(id: "kml-waypoints")  } }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Export Complete", isPresented: $showA109ExportCompleteAlert) {
            Button("OK") { }
        } message: {
            Text("Remove the PCMCIA card.")
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
        }
        .sheet(isPresented: Binding(
            get: { !toastManager.importWarnings.isEmpty },
            set: { if !$0 { toastManager.importWarnings = []; toastManager.importWarningTitle = "" } }
        )) {
            NavigationStack {
                List {
                    Section {
                        Text("These records could not be parsed and were skipped:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(toastManager.importWarnings.enumerated()), id: \.offset) { idx, warning in
                        Section("Record \(idx + 1)") {
                            Text(warning)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle(toastManager.importWarningTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            toastManager.importWarnings = []
                            toastManager.importWarningTitle = ""
                        }
                    }
                }
            }
            .tint(RutTheme.amber)
        }
        .fileImporter(
            isPresented: Binding(
                get: { activeImporter != nil },
                set: { if !$0 { activeImporter = nil } }
            ),
            allowedContentTypes: [.item],
            allowsMultipleSelection: activeImporter == .importing
        ) { result in
            switch activeImporter {
            case .importing:       handleImport(result: result)
            case .exportFolder:    handleA109ExportFolderSelection(result: result)
            case .defaultFile:     handleDefaultFileSelection(result: result)
            case .none:            break
            }
            activeImporter = nil
        }
        .confirmationDialog("Import KML/KMZ as…", isPresented: $showKMLImportModeDialog, titleVisibility: .visible) {
            Button("Vector Layers") {
                Task { await CoreServices.shared.importDocuments(from: pendingKMLURLs, kmlAsVector: true) }
                pendingKMLURLs = []
            }
            Button("Navigation Data") {
                Task { await CoreServices.shared.importDocuments(from: pendingKMLURLs, kmlAsVector: false) }
                pendingKMLURLs = []
            }
            Button("Cancel", role: .cancel) { pendingKMLURLs = [] }
        }
        .alert("Incomplete Data", isPresented: $showA109MissingDataAlert) {
            Button("Cancel", role: .cancel) { }
            if DefaultPresetService.shared.hasDefault {
                Button("Use default APT/NAVAID") { loadDefaultAndExport() }
            } else {
                Button("Set default APT/NAVAID file…") { activeImporter = .defaultFile }
            }
            Button("Continue without APT/NAVAID") { activeImporter = .exportFolder }
        } message: {
            if let name = DefaultPresetService.shared.defaultFileName {
                Text("Missing airports or navaids. Default: \(name)")
            } else {
                Text("Do you want to continue the export without user airports or user navaids?")
            }
        }
    }

    // MARK: - Main View (persistent single map)

    private var mainView: some View {
        ZStack {
            RutTheme.bg.ignoresSafeArea()
            persistentMapWithBars
            ToastOverlay().environmentObject(toastManager)
        }
    }

    private var persistentMapWithBars: some View {
        RutMapView(
            onPointTap: { point in
                guard core.appMode == .navigation else { return }
                handlePointTap(point)
            },
            onMapLongPress: { coord in
                guard core.appMode == .navigation else { return }
                longPressLat = coord.latitude
                longPressLon = coord.longitude
                showAddPointTypeMenu = true
            }
        )
        .environmentObject(navStore)
        .environmentObject(core.vectorStore)
        .environmentObject(core.vectorStore.drawing)
        .environmentObject(core)
        .safeAreaInset(edge: .top, spacing: 0) { topBarForCurrentMode }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBarForCurrentMode }
        .safeAreaInset(edge: .trailing, spacing: 0) { trailingSidePanelIfNeeded }
        .overlay(alignment: .bottomTrailing) { phoneLayerButtonIfNeeded }
        .sheet(isPresented: $showLayerPanel) { layerPanelSheet }
    }

    @ViewBuilder private var topBarForCurrentMode: some View {
        if core.appMode == .vector { vectorTopBar } else { navTopBar }
    }

    @ViewBuilder private var bottomBarForCurrentMode: some View {
        if core.appMode == .vector { vectorBottomBar } else { navBottomBar }
    }

    @ViewBuilder private var trailingSidePanelIfNeeded: some View {
        if core.appMode == .vector && sizeClass != .compact {
            HStack(spacing: 0) {
                Rectangle().fill(RutTheme.border).frame(width: 1)
                VStack(spacing: 0) {
                    VectorLayerPanel()
                        .environmentObject(core.vectorStore)
                }
                .frame(width: 196)
                .background(RutTheme.surface)
            }
        }
    }

    @ViewBuilder private var phoneLayerButtonIfNeeded: some View {
        if core.appMode == .vector && sizeClass == .compact {
            Button { showLayerPanel = true } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(RutTheme.text)
                    .frame(width: 44, height: 44)
                    .background(RutTheme.surface)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(RutTheme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .padding([.trailing, .bottom], 80)
        }
    }

    private var layerPanelSheet: some View {
        NavigationStack {
            VectorLayerPanel()
                .environmentObject(core.vectorStore)
                .navigationTitle("Layers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showLayerPanel = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .tint(RutTheme.amber)
    }

    // MARK: - Nav top bar

    private var navTopBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                let uAp = navStore.document.userAirports.count
                let uNv = navStore.document.userNavaids.count
                let uWp = navStore.document.userWaypoints.count
                let uSh = core.vectorStore.layers.filter { !$0.isSystem }.reduce(0) { $0 + $1.shapes.count }

                if uAp > 0 { StatBadge(icon: "airplane", count: uAp, label: "Apt") }
                if uNv > 0 { StatBadge(icon: "antenna.radiowaves.left.and.right", count: uNv, label: "Nav") }
                if uWp > 0 { StatBadge(icon: "mappin.and.ellipse", count: uWp, label: "Wpt") }
                if uSh > 0 { StatBadge(icon: "triangle", count: uSh, label: "Shapes") }

                Spacer()

                Button { activeImporter = .importing } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(RutSecondaryButtonStyle())

                Button { showDatabase = true } label: {
                    Label("Database", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(RutSecondaryButtonStyle())

                Button { core.appMode = .vector } label: {
                    Label("Vector Mode", systemImage: "triangle")
                }
                .buttonStyle(RutSecondaryButtonStyle())

                Button { showSettingsSheet = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(RutSecondaryButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .background(RutTheme.surface)

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
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .background(RutTheme.surface)
            }

            divider
        }
    }

    // MARK: - Nav bottom bar

    private var navBottomBar: some View {
        VStack(spacing: 0) {
            divider
            HStack(spacing: 10) {
                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .foregroundColor(RutTheme.textDim)

                Button { handleExportButtonTap() } label: {
                    if exportFormat.isPCMCIA {
                        Label("Save to Drive", systemImage: "externaldrive.badge.plus")
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(RutPrimaryButtonStyle())

                Text("v\(appVersion)")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundColor(RutTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RutTheme.surface)
        }
    }

    // MARK: - Vector top bar

    private var vectorTopBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button { core.appMode = .navigation } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(RutSecondaryButtonStyle())
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RutTheme.surface)
            Rectangle().fill(RutTheme.border).frame(height: 1)
        }
    }

    // MARK: - Vector bottom bar

    private var vectorBottomBar: some View {
        VectorToolbar()
            .environmentObject(core.vectorStore)
            .environmentObject(toastManager)
    }

    private var divider: some View {
        Rectangle()
            .fill(RutTheme.border)
            .frame(height: 1)
    }

    // MARK: - Point tap handler

    private func handlePointTap(_ point: RouteMapPoint) {
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
        let kmlExtensions: Set<String> = ["kml", "kmz"]
        let kmlURLs   = urls.filter { kmlExtensions.contains($0.pathExtension.lowercased()) }
        let otherURLs = urls.filter { !kmlExtensions.contains($0.pathExtension.lowercased()) }

        // Non-KML/KMZ files import immediately
        if !otherURLs.isEmpty {
            Task { await CoreServices.shared.importDocuments(from: otherURLs) }
        }

        guard !kmlURLs.isEmpty else { return }

        // Check if any file contains non-nav data (polygons etc.)
        let hasNonNav = kmlURLs.contains { url in
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            return KMZImportService.containsNonNavData(url: url)
        }

        if hasNonNav {
            // Force vector, no dialog
            toastManager.show(message: "File contains non-navigation data (polygons etc.) — importing as vector layers.", kind: .info)
            Task { await CoreServices.shared.importDocuments(from: kmlURLs, kmlAsVector: true) }
        } else {
            // Only points/lines — let the user choose
            pendingKMLURLs = kmlURLs
            showKMLImportModeDialog = true
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
        let alert = UIAlertController(title: "Rename route", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.text = route.name }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            if let newName = alert.textFields?.first?.text {
                navStore.updateRouteName(route, newName: newName)
            }
        })
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(alert, animated: true)
        }
    }

    private func showExportValidationAlert(_ error: ExportValidationError) {
        let message = error.issues
            .map { "• \($0)" }
            .joined(separator: "\n\n")
        let alert = UIAlertController(
            title: error.title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(alert, animated: true)
        }
    }

    // MARK: - Export Logic

    private func canExport() -> Bool {
        let hasData: Bool
        switch exportFormat {
        case .apt: hasData = !navStore.document.userAirports.isEmpty
        case .nav: hasData = !navStore.document.userNavaids.isEmpty
        case .fpl, .rte, .gpx: hasData = !navStore.routes.isEmpty
        case .rut, .a109, .uh60m, .h145, .nh90, .kml:
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
        if exportFormat == .uh60m {
            toastManager.show(message: "UH-60M export is not implemented yet.", kind: .info); return
        }
        if exportFormat == .h145 {
            toastManager.show(message: "H145 export is not implemented yet.", kind: .info); return
        }
        if exportFormat == .nh90 {
            toastManager.show(message: "NH90 export is not implemented yet.", kind: .info); return
        }
        guard canExport() else { return }

        if exportFormat == .kml { showKMLSubDialog = true; return }

        if exportFormat == .a109 {
            let missing = navStore.document.userAirports.isEmpty || navStore.document.userNavaids.isEmpty
            if missing { showA109MissingDataAlert = true } else { activeImporter = .exportFolder }
        } else {
            prepareStandardExport()
        }
    }

    private func prepareStandardExport() {
        let exporterId: String
        switch exportFormat {
        case .fpl: exporterId = "fpl"
        case .rte: exporterId = "rte"
        case .rut: exporterId = "rut"
        case .gpx: exporterId = "gpx"
        case .apt: exporterId = "apt"
        case .nav: exporterId = "nav"
        default: return
        }
        guard let exporter = CoreServices.shared.exporter(withId: exporterId) else {
            toastManager.show(message: "Exporter for '\(exporterId)' not found."); return
        }
        do {
            let files = try exporter.export(document: navStore.document, routes: navStore.routes)
            guard !files.isEmpty else { toastManager.show(message: "Nothing to export.", kind: .info); return }
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            var urls: [URL] = []
            for file in files {
                let url = tempDir.appendingPathComponent(file.filename)
                try file.data.write(to: url, options: .atomic)
                urls.append(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.exportContainer = ExportContainer(urls: urls) }
        } catch let ve as ExportValidationError {
            showExportValidationAlert(ve)
        } catch {
            ErrorLogger.shared.logError(error)
            toastManager.show(message: error.localizedDescription)
        }
    }

    private func handleA109ExportFolderSelection(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error): toastManager.showError(error)
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            performA109DirectExport(to: folderURL)
        }
    }

    private func performA109DirectExport(to folderURL: URL) {
        guard let exporter = CoreServices.shared.exporter(withId: "a109") else {
            toastManager.show(message: "A109 Exporter not available."); return
        }
        do {
            let files = try exporter.export(document: navStore.document, routes: navStore.routes)
            guard !files.isEmpty else { toastManager.show(message: "Nothing to export.", kind: .info); return }
            let secured = folderURL.startAccessingSecurityScopedResource()
            defer { if secured { folderURL.stopAccessingSecurityScopedResource() } }
            for file in files {
                let dest = folderURL.appendingPathComponent(file.filename)
                try file.data.write(to: dest, options: .atomic)
                dest.cleanAppleAttributes()
                let fd = Darwin.open(dest.path, O_RDONLY)
                if fd >= 0 { Darwin.fsync(fd); Darwin.close(fd) }
            }
            try cleanupDotFiles(in: folderURL)
            showA109ExportCompleteAlert = true
        } catch let ve as ExportValidationError {
            showExportValidationAlert(ve)
        } catch {
            ErrorLogger.shared.logError(error)
            toastManager.show(message: "Export failed: \(error.localizedDescription)")
        }
    }

    private func executeKMLExport(id: String) {
        guard let exporter = CoreServices.shared.exporter(withId: id) else {
            toastManager.show(message: "KML exporter '\(id)' not found."); return
        }
        do {
            let routesForExport: [Route]
            if id == "kml-route", let activeId = navStore.activeRouteId,
               let active = navStore.document.routes.first(where: { $0.id == activeId }) {
                routesForExport = [active]
            } else {
                routesForExport = navStore.routes
            }
            let files = try exporter.export(document: navStore.document, routes: routesForExport)
            guard !files.isEmpty else { toastManager.show(message: "Nothing to export.", kind: .info); return }
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            var urls: [URL] = []
            for file in files {
                let url = tempDir.appendingPathComponent(file.filename)
                try file.data.write(to: url, options: .atomic)
                urls.append(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.exportContainer = ExportContainer(urls: urls) }
        } catch {
            ErrorLogger.shared.logError(error)
            toastManager.show(message: error.localizedDescription)
        }
    }

    private func handleDefaultFileSelection(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        DefaultPresetService.shared.saveDefault(url: url)
        loadDefaultAndExport()
    }

    private func loadDefaultAndExport() {
        guard let url = DefaultPresetService.shared.resolveDefault() else {
            activeImporter = .exportFolder
            return
        }
        Task {
            await CoreServices.shared.importDocuments(from: [url])
            url.stopAccessingSecurityScopedResource()
            await MainActor.run { activeImporter = .exportFolder }
        }
    }

    private func cleanupDotFiles(in folderURL: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        for fileURL in contents where fileURL.lastPathComponent.hasPrefix(".") {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

// MARK: - Settings View

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isSelectingDefaultFile = false
    @State private var currentName: String? = DefaultPresetService.shared.defaultFileName

    var body: some View {
        NavigationStack {
            Form {
                Section("Default airports & navaids") {
                    if let name = currentName {
                        LabeledContent("File", value: name)
                    } else {
                        Text("No default set").foregroundStyle(.secondary)
                    }
                    Button("Set default file…") {
                        activeImporter = .defaultFile
                    }
                    if currentName != nil {
                        Button("Clear default", role: .destructive) {
                            DefaultPresetService.shared.clearDefault()
                            currentName = nil
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isSelectingDefaultFile,
                allowedContentTypes: [.rut, .apt, .nav],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    DefaultPresetService.shared.saveDefault(url: url)
                    currentName = DefaultPresetService.shared.defaultFileName
                }
            }
        }
    }
}

// MARK: - URL Extension

extension URL {
    func cleanAppleAttributes() {
        self.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            for attr in ["com.apple.quarantine", "com.apple.FinderInfo",
                         "com.apple.ResourceFork", "com.apple.metadata:_kMDItemUserTags",
                         "com.apple.lastuseddate#PS"] {
                removexattr(path, attr, 0)
            }
        }
    }
}
