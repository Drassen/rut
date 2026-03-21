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
        case .waypoints: return "mappin.and.ellipse"
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
}

struct DatabaseListView: View {
    @EnvironmentObject var navStore: NavigationStore
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab: DatabaseTab = .routes
    @State private var itemToAdd: PointEditorView.EditMode?
    @State private var showNewRouteAlert = false
    @State private var newRouteName = ""

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
                .background(RutTheme.bg)
            }
            .navigationTitle("User Database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(RutTheme.textDim)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { startAddItem() } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                            .foregroundColor(RutTheme.amber)
                    }
                }
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
        }
        .tint(RutTheme.amber)
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
        List {
            ForEach(navStore.document.userWaypoints.sorted { $0.id < $1.id }) { wp in
                NavigationLink(destination: PointEditorView(mode: .waypoint(wp), isNew: false)) {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 13))
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
        List {
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
        List {
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
