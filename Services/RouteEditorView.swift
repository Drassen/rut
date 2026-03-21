import SwiftUI

// MARK: - Route Editor

struct RouteEditorView: View {
    @EnvironmentObject var navStore: NavigationStore
    let routeId: UUID

    @State private var showAddPoints = false

    private var route: Route? {
        navStore.document.routes.first { $0.id == routeId }
    }

    var body: some View {
        Group {
            if let route {
                routeContent(route)
            } else {
                VStack {
                    Spacer()
                    Text("Route not found")
                        .foregroundColor(RutTheme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(RutTheme.bg)
            }
        }
        .navigationTitle(route?.name ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
                    .foregroundColor(RutTheme.textDim)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddPoints = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                        .foregroundColor(RutTheme.amber)
                }
            }
        }
        .sheet(isPresented: $showAddPoints) {
            AddRoutePointSheet(routeId: routeId)
        }
    }

    // MARK: List content

    @ViewBuilder
    private func routeContent(_ route: Route) -> some View {
        let distances = navStore.legDistancesNM(for: route)
        let total = distances.reduce(0.0, +)

        List {
            if route.pointRefs.isEmpty {
                Text("No points — tap + to add")
                    .font(.subheadline)
                    .foregroundColor(RutTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(Array(route.pointRefs.enumerated()), id: \.element.id) { idx, ref in
                    pointRow(
                        ref: ref,
                        index: idx + 1,
                        legDist: idx < distances.count ? distances[idx] : nil
                    )
                }
                .onMove { from, to in
                    navStore.moveRoutePoints(routeId: routeId, from: from, to: to)
                }
                .onDelete { offsets in
                    navStore.removeRoutePoints(routeId: routeId, at: offsets)
                }

                // Footer: total distance + point count
                HStack {
                    Spacer()
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 11))
                        .foregroundColor(RutTheme.textMuted)
                    Text(String(format: "%.1f nm", total))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(RutTheme.textDim)
                    Text("· \(route.pointRefs.count) pts")
                        .font(.system(size: 12))
                        .foregroundColor(RutTheme.textMuted)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(RutTheme.bg)
    }

    // MARK: Row

    private func pointRow(ref: RoutePointRef, index: Int, legDist: Double?) -> some View {
        let info = resolvedInfo(for: ref)
        return HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(RutTheme.textMuted)
                .frame(width: 22, alignment: .trailing)

            Image(systemName: info.icon)
                .font(.system(size: 13))
                .foregroundColor(info.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(ref.refId)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(RutTheme.text)
                if let sub = info.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundColor(RutTheme.textDim)
                }
            }

            Spacer()

            if let d = legDist {
                Text(String(format: "%.1f nm", d))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(RutTheme.textMuted)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(RutTheme.surface)
    }

    // MARK: Helpers

    private struct PointDisplayInfo {
        let icon: String
        let color: Color
        let subtitle: String?
    }

    private func resolvedInfo(for ref: RoutePointRef) -> PointDisplayInfo {
        switch ref.kind {
        case .userAirport:
            let ap = navStore.document.userAirports.first { $0.id == ref.refId }
            let sub = ap.flatMap { $0.name != $0.id && !$0.name.isEmpty ? $0.name : nil }
            return PointDisplayInfo(icon: "airplane", color: RutTheme.amber, subtitle: sub)
        case .systemAirport:
            return PointDisplayInfo(icon: "airplane", color: RutTheme.amber.opacity(0.55), subtitle: "system")
        case .userNavaid:
            let nv = navStore.document.userNavaids.first { $0.id == ref.refId }
            let sub = nv.flatMap { !$0.name.isEmpty ? $0.name : nil }
            return PointDisplayInfo(icon: "antenna.radiowaves.left.and.right", color: RutTheme.green, subtitle: sub)
        case .systemNavaid:
            return PointDisplayInfo(icon: "antenna.radiowaves.left.and.right", color: RutTheme.green.opacity(0.55), subtitle: "system")
        case .userWaypoint:
            let wp = navStore.document.userWaypoints.first { $0.id == ref.refId }
            let sub = wp.flatMap { $0.type != .custom ? $0.type.rawValue : nil }
            return PointDisplayInfo(icon: "mappin.and.ellipse", color: RutTheme.textDim, subtitle: sub)
        }
    }
}

// MARK: - Add Route Point Sheet

struct AddRoutePointSheet: View {
    @EnvironmentObject var navStore: NavigationStore
    @Environment(\.dismiss) var dismiss
    let routeId: UUID

    enum PickerTab: String, CaseIterable, Identifiable {
        case waypoints = "Waypoints"
        case airports  = "Airports"
        case navaids   = "Navaids"
        var id: String { rawValue }
    }

    @State private var tab: PickerTab = .waypoints
    @State private var query = ""

    private var currentRefs: Set<String> {
        let route = navStore.document.routes.first { $0.id == routeId }
        return Set(route?.pointRefs.map { $0.refId } ?? [])
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                searchBar
                listContent
                    .background(RutTheme.bg)
            }
            .navigationTitle("Add Points")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(RutTheme.amber)
                }
            }
        }
        .tint(RutTheme.amber)
    }

    // MARK: Sub-views

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PickerTab.allCases) { t in
                let icon: String = {
                    switch t {
                    case .waypoints: return "mappin.and.ellipse"
                    case .airports:  return "airplane"
                    case .navaids:   return "antenna.radiowaves.left.and.right"
                    }
                }()
                let color: Color = {
                    switch t {
                    case .waypoints: return RutTheme.textDim
                    case .airports:  return RutTheme.amber
                    case .navaids:   return RutTheme.green
                    }
                }()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { tab = t }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 15))
                        Text(t.rawValue).font(.caption2.weight(.medium))
                    }
                    .foregroundColor(tab == t ? color : RutTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        if tab == t { Rectangle().fill(color).frame(height: 2) }
                    }
                }
            }
        }
        .background(RutTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RutTheme.border).frame(height: 1)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(RutTheme.textMuted)
                .font(.system(size: 14))
            TextField("Search", text: $query)
                .font(.subheadline)
                .foregroundColor(RutTheme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(RutTheme.textMuted)
                        .font(.system(size: 14))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RutTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RutTheme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        switch tab {
        case .waypoints: waypointList
        case .airports:  airportList
        case .navaids:   navaidList
        }
    }

    // MARK: Lists

    private var waypointList: some View {
        let items = navStore.document.userWaypoints
            .sorted { $0.id < $1.id }
            .filter { matches($0.id) || matches($0.name) }
        return List {
            ForEach(items) { wp in
                addRow(
                    icon: "mappin.and.ellipse", iconColor: RutTheme.textDim,
                    id: wp.id,
                    name: wp.name != wp.id && !wp.name.isEmpty ? wp.name : nil,
                    badge: wp.type != .custom ? wp.type.rawValue : nil,
                    inRoute: currentRefs.contains(wp.id)
                ) {
                    navStore.addRoutePoint(
                        routeId: routeId,
                        ref: RoutePointRef(kind: .userWaypoint, refId: wp.id)
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var airportList: some View {
        let userApts = navStore.document.userAirports
            .sorted { $0.id < $1.id }
            .filter { matches($0.id) || matches($0.name) }
        let sysApts = navStore.document.systemAirports
            .sorted { $0.id < $1.id }
            .filter { matches($0.id) }
        return List {
            ForEach(userApts) { ap in
                addRow(
                    icon: "airplane", iconColor: RutTheme.amber,
                    id: ap.id,
                    name: ap.name != ap.id && !ap.name.isEmpty ? ap.name : nil,
                    badge: nil,
                    inRoute: currentRefs.contains(ap.id)
                ) {
                    navStore.addRoutePoint(
                        routeId: routeId,
                        ref: RoutePointRef(kind: .userAirport, refId: ap.id)
                    )
                }
            }
            ForEach(sysApts) { ap in
                addRow(
                    icon: "airplane", iconColor: RutTheme.amber.opacity(0.5),
                    id: ap.id, name: nil,
                    badge: "JEP",
                    inRoute: currentRefs.contains(ap.id)
                ) {
                    navStore.addRoutePoint(
                        routeId: routeId,
                        ref: RoutePointRef(kind: .systemAirport, refId: ap.id)
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var navaidList: some View {
        let userNav = navStore.document.userNavaids
            .sorted { $0.id < $1.id }
            .filter { matches($0.id) || matches($0.name) }
        let sysNav = navStore.document.systemNavaids
            .sorted { $0.id < $1.id }
            .filter { matches($0.id) }
        return List {
            ForEach(userNav) { nv in
                addRow(
                    icon: "antenna.radiowaves.left.and.right", iconColor: RutTheme.green,
                    id: nv.id,
                    name: !nv.name.isEmpty ? nv.name : nil,
                    badge: nil,
                    inRoute: currentRefs.contains(nv.id)
                ) {
                    navStore.addRoutePoint(
                        routeId: routeId,
                        ref: RoutePointRef(kind: .userNavaid, refId: nv.id)
                    )
                }
            }
            ForEach(sysNav) { nv in
                addRow(
                    icon: "antenna.radiowaves.left.and.right", iconColor: RutTheme.green.opacity(0.5),
                    id: nv.id, name: nil,
                    badge: "JEP",
                    inRoute: currentRefs.contains(nv.id)
                ) {
                    navStore.addRoutePoint(
                        routeId: routeId,
                        ref: RoutePointRef(kind: .systemNavaid, refId: nv.id)
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: Add Row

    @ViewBuilder
    private func addRow(
        icon: String,
        iconColor: Color,
        id: String,
        name: String?,
        badge: String?,
        inRoute: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(iconColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(id)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(RutTheme.text)
                    if let name {
                        Text(name)
                            .font(.caption)
                            .foregroundColor(RutTheme.textDim)
                    }
                }

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RutTheme.amber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RutTheme.amberDim)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(RutTheme.amber.opacity(0.3), lineWidth: 1)
                        )
                        .cornerRadius(4)
                }

                Image(systemName: inRoute ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 18))
                    .foregroundColor(inRoute ? RutTheme.green : RutTheme.textMuted)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .listRowBackground(RutTheme.surface)
    }

    // MARK: Helpers

    private func matches(_ s: String) -> Bool {
        query.isEmpty || s.localizedCaseInsensitiveContains(query)
    }
}
