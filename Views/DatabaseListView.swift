import SwiftUI

enum DatabaseTab: String, CaseIterable, Identifiable {
    case routes    = "Routes"
    case waypoints = "Waypoints"
    case airports  = "Airports"
    case navaids   = "Navaids"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .routes:    return "map"
        case .waypoints: return "mappin.circle"
        case .airports:  return "airplane"
        case .navaids:   return "antenna.radiowaves.left.and.right"
        }
    }

    var color: Color {
        switch self {
        case .routes:    return RutTheme.amber
        case .waypoints: return RutTheme.textDim
        case .airports:  return RutTheme.amber
        case .navaids:   return RutTheme.green
        }
    }

    /// The user point kind listed in this tab (nil for routes).
    var pointKind: NavigationStore.UserPointKind? {
        switch self {
        case .routes:    return nil
        case .waypoints: return .waypoint
        case .airports:  return .airport
        case .navaids:   return .navaid
        }
    }

    init(pointKind: NavigationStore.UserPointKind) {
        switch pointKind {
        case .waypoint: self = .waypoints
        case .airport:  self = .airports
        case .navaid:   self = .navaids
        }
    }
}

struct DatabaseListView: View {
    @EnvironmentObject var navStore: NavigationStore
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab: DatabaseTab = .routes
    @State private var itemToAdd: PointEditorView.EditMode?
    @State private var showNewRouteAlert = false
    @State private var newRouteName = ""

    // Massändring av punkttyp
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var pendingConversion: PendingConversion?
    @State private var conversionReport: ConversionReport?
    @State private var pendingDelete: PendingDelete?

    struct PendingDelete {
        let kind: NavigationStore.UserPointKind
        let ids: Set<String>
        let message: String
    }

    struct PendingConversion {
        let from: NavigationStore.UserPointKind
        let to: NavigationStore.UserPointKind
        let conversions: [NavigationStore.PointConversion]
        let notes: [String]
    }

    struct ConversionReport: Identifiable {
        let id = UUID()
        let lines: [String]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Custom tab bar ──
                HStack(spacing: 0) {
                    ForEach(DatabaseTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
                .background(RutTheme.surface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(RutTheme.border).frame(height: 1)
                }

                // ── Content ──
                Group {
                    switch selectedTab {
                    case .routes:    routeList
                    case .waypoints: waypointList
                    case .airports:  airportList
                    case .navaids:   navaidList
                    }
                }
                .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
                .background(RutTheme.bg)

                if isSelecting, let kind = selectedTab.pointKind {
                    selectionBar(kind: kind)
                }
            }
            .navigationTitle("User Database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(RutTheme.textDim)
                }
                // Separate items (not a ToolbarItemGroup): on iOS 26+ a group is drawn as
                // one shared glass capsule, which made Select and + look like one control.
                if selectedTab.pointKind != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isSelecting.toggle()
                            selection = []
                        } label: {
                            Label(isSelecting ? "Done" : "Select",
                                  systemImage: isSelecting ? "checkmark" : "checklist")
                                .labelStyle(.titleAndIcon)
                                .foregroundColor(RutTheme.amber)
                        }
                    }
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                if !isSelecting {
                    ToolbarItem(placement: .primaryAction) {
                        Button { startAddItem() } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                                .foregroundColor(RutTheme.amber)
                        }
                    }
                }
            }
            .onChange(of: selectedTab) { _, _ in
                isSelecting = false
                selection = []
            }
            .sheet(item: Binding(
                get: { itemToAdd.map { Wrapper(mode: $0) } },
                set: { itemToAdd = $0?.mode }
            )) { wrapper in
                NavigationStack {
                    PointEditorView(mode: wrapper.mode, isNew: true)
                }
                .tint(RutTheme.amber)
            }
            .alert(
                pendingConversion.map { "Convert \($0.conversions.count) \($0.from.label.lowercased())(s) to \($0.to.label.lowercased())s?" } ?? "",
                isPresented: Binding(
                    get: { pendingConversion != nil },
                    set: { if !$0 { pendingConversion = nil } }
                ),
                presenting: pendingConversion
            ) { pending in
                Button("Convert") { applyConversion(pending) }
                Button("Cancel", role: .cancel) { }
            } message: { pending in
                Text(pending.notes.isEmpty
                     ? "IDs, names and positions are kept."
                     : pending.notes.joined(separator: "\n"))
            }
        }
        .tint(RutTheme.amber)
        .sheet(item: $conversionReport) { report in
            NavigationStack {
                List {
                    Section {
                        ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("Nothing was converted")
                    }
                }
                .navigationTitle("Cannot convert")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { conversionReport = nil }
                    }
                }
            }
            .tint(RutTheme.amber)
        }
        .alert("New Route", isPresented: $showNewRouteAlert) {
            TextField("Route name", text: $newRouteName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            Button("Create") {
                let trimmed = newRouteName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    navStore.createEmptyRoute(named: trimmed)
                }
                newRouteName = ""
            }
            Button("Cancel", role: .cancel) { newRouteName = "" }
        } message: {
            Text("Enter a name for the new route.")
        }
    }

    // MARK: - Tab Button

    private func tabButton(_ tab: DatabaseTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15))
                Text(tab.rawValue)
                    .font(.caption2.weight(.medium))
            }
            .foregroundColor(selectedTab == tab ? tab.color : RutTheme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                if selectedTab == tab {
                    Rectangle()
                        .fill(tab.color)
                        .frame(height: 2)
                }
            }
        }
    }

    // MARK: - Selection bar (mass conversion)

    private func selectionBar(kind: NavigationStore.UserPointKind) -> some View {
        let allIds = pointIds(kind)
        let allSelected = !allIds.isEmpty && selection.count == allIds.count
        return HStack(spacing: 16) {
            Button(allSelected ? "Deselect All" : "Select All") {
                selection = allSelected ? [] : Set(allIds)
            }
            .disabled(allIds.isEmpty)

            Spacer()

            Text("\(selection.count) selected")
                .font(.footnote)
                .foregroundColor(RutTheme.textDim)

            Spacer()

            Menu {
                ForEach(NavigationStore.UserPointKind.allCases.filter { $0 != kind }) { target in
                    Button("Convert to \(target.label)s") { prepareConversion(from: kind, to: target) }
                }
            } label: {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                prepareDelete(kind: kind)
            } label: {
                Label("Delete", systemImage: "trash")
                    .foregroundColor(selection.isEmpty ? RutTheme.textMuted : RutTheme.danger)
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RutTheme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(RutTheme.border).frame(height: 1)
        }
        // Attached here, not next to the conversion alert: two alerts on one view can clash
        .alert(
            pendingDelete.map { "Delete \($0.ids.count) \($0.kind.label.lowercased())(s)?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { pending in
            Button("Delete", role: .destructive) {
                navStore.deletePoints(kind: pending.kind, ids: pending.ids)
                isSelecting = false
                selection = []
            }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(pending.message)
        }
    }

    private func prepareDelete(kind: NavigationStore.UserPointKind) {
        let ids = selection
        let routeNames = Set(ids.flatMap { navStore.routesUsing(kind: kind, id: $0) }.map { $0.route.name }).sorted()
        var message = "This cannot be undone."
        if !routeNames.isEmpty {
            let shown = routeNames.prefix(5).joined(separator: ", ") + (routeNames.count > 5 ? ", …" : "")
            message = "They are removed from \(routeNames.count) route(s) (\(shown)). " + message
        }
        pendingDelete = PendingDelete(kind: kind, ids: ids, message: message)
    }

    private func pointIds(_ kind: NavigationStore.UserPointKind) -> [String] {
        switch kind {
        case .waypoint: return navStore.document.userWaypoints.map { $0.id }
        case .navaid:   return navStore.document.userNavaids.map { $0.id }
        case .airport:  return navStore.document.userAirports.map { $0.id }
        }
    }

    /// Validates the whole batch first; if anything fails the reasons are listed and nothing
    /// changes. Otherwise asks for confirmation with a summary of what the conversion changes.
    private func prepareConversion(from: NavigationStore.UserPointKind, to: NavigationStore.UserPointKind) {
        let ids = selection.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let conversions = navStore.conversions(of: ids, from: from, to: to)
        let problems = navStore.validateConversions(conversions)
        guard problems.isEmpty else {
            conversionReport = ConversionReport(lines: problems)
            return
        }
        pendingConversion = PendingConversion(from: from, to: to, conversions: conversions,
                                              notes: navStore.conversionNotes(conversions))
    }

    private func applyConversion(_ pending: PendingConversion) {
        // convertPoints validates again and changes nothing if anything fails
        let problems = navStore.convertPoints(pending.conversions)
        guard problems.isEmpty else {
            conversionReport = ConversionReport(lines: problems)
            return
        }
        isSelecting = false
        selection = []
        selectedTab = DatabaseTab(pointKind: pending.to)
    }

    // MARK: - Lists

    private var routeList: some View {
        List {
            ForEach(navStore.document.routes) { route in
                NavigationLink(destination: RouteEditorView(routeId: route.id)) {
                    HStack(spacing: 12) {
                        Image(systemName: "map")
                            .font(.system(size: 13))
                            .foregroundColor(RutTheme.amber)
                            .frame(width: 22)

                        Text(route.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(RutTheme.text)

                        Spacer()

                        Text("\(route.pointRefs.count)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(route.pointRefs.count > 40 ? RutTheme.danger : RutTheme.textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RutTheme.surface2)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 3)
                }
                .listRowBackground(RutTheme.surface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var waypointList: some View {
        List(selection: $selection) {
            ForEach(navStore.document.userWaypoints.sorted { $0.id < $1.id }) { wp in
                NavigationLink(destination: PointEditorView(mode: .waypoint(wp), isNew: false)) {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle")
                            .font(.system(size: 15))
                            .foregroundColor(RutTheme.textDim)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(wp.id)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(RutTheme.text)
                            if !wp.name.isEmpty && wp.name != wp.id {
                                Text(wp.name)
                                    .font(.caption)
                                    .foregroundColor(RutTheme.textDim)
                            }
                        }

                        Spacer()

                        if wp.type != .custom {
                            Text(wp.type.rawValue)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(RutTheme.amber)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(RutTheme.amberDim)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(RutTheme.amber.opacity(0.3), lineWidth: 1))
                                .cornerRadius(4)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listRowBackground(RutTheme.surface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var airportList: some View {
        List(selection: $selection) {
            ForEach(navStore.document.userAirports.sorted { $0.id < $1.id }) { ap in
                NavigationLink(destination: PointEditorView(mode: .airport(ap), isNew: false)) {
                    HStack(spacing: 12) {
                        Image(systemName: "airplane")
                            .font(.system(size: 13))
                            .foregroundColor(RutTheme.amber)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(ap.id)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(RutTheme.text)
                            if !ap.name.isEmpty && ap.name != ap.id {
                                Text(ap.name)
                                    .font(.caption)
                                    .foregroundColor(RutTheme.textDim)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listRowBackground(RutTheme.surface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var navaidList: some View {
        List(selection: $selection) {
            ForEach(navStore.document.userNavaids.sorted { $0.id < $1.id }) { nv in
                NavigationLink(destination: PointEditorView(mode: .navaid(nv), isNew: false)) {
                    HStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 13))
                            .foregroundColor(RutTheme.green)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(nv.id)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(RutTheme.text)
                            if !nv.name.isEmpty {
                                Text(nv.name)
                                    .font(.caption)
                                    .foregroundColor(RutTheme.textDim)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listRowBackground(RutTheme.surface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Add Item

    struct Wrapper: Identifiable {
        let id = UUID()
        let mode: PointEditorView.EditMode
    }

    private func startAddItem() {
        switch selectedTab {
        case .routes:
            newRouteName = ""
            showNewRouteAlert = true
        case .waypoints:
            itemToAdd = .waypoint(UserWaypoint(id: "", name: "", type: .custom, latitude: 0, longitude: 0, elevation: 0))
        case .airports:
            itemToAdd = .airport(UserAirport(id: "", name: "", latitude: 0, longitude: 0, elevation: 0))
        case .navaids:
            itemToAdd = .navaid(UserNavaid(id: "", name: "", latitude: 0, longitude: 0, elevation: 0, magneticVariation: 0, frequency: 0))
        }
    }
}
