import SwiftUI

enum DatabaseTab: String, CaseIterable, Identifiable {
    case waypoints = "Waypoints"
    case airports = "Airports"
    case navaids = "Navaids"
    
    var id: String { rawValue }
}

struct DatabaseListView: View {
    @EnvironmentObject var navStore: NavigationStore
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedTab: DatabaseTab = .waypoints
    @State private var itemToAdd: PointEditorView.EditMode?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Database", selection: $selectedTab) {
                    ForEach(DatabaseTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                Group {
                    switch selectedTab {
                    case .waypoints: waypointList
                    case .airports: airportList
                    case .navaids: navaidList
                    }
                }
            }
            .navigationTitle("User Database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { startAddItem() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: Binding(
                get: { itemToAdd.map { Wrapper(mode: $0) } },
                set: { itemToAdd = $0?.mode }
            )) { wrapper in
                NavigationStack {
                    PointEditorView(mode: wrapper.mode, isNew: true)
                }
            }
        }
    }
    
    struct Wrapper: Identifiable {
        let id = UUID()
        let mode: PointEditorView.EditMode
    }
    
    private func startAddItem() {
        switch selectedTab {
        case .waypoints:
            let template = UserWaypoint(id: "", name: "", type: .custom, latitude: 0, longitude: 0, elevation: 0)
            itemToAdd = .waypoint(template)
        case .airports:
            let template = UserAirport(id: "", name: "", latitude: 0, longitude: 0, elevation: 0)
            itemToAdd = .airport(template)
        case .navaids:
            let template = UserNavaid(id: "", name: "", latitude: 0, longitude: 0, elevation: 0, magneticVariation: 0, frequency: 0)
            itemToAdd = .navaid(template)
        }
    }
    
    // MARK: - Sorted Lists
    
    private var waypointList: some View {
        List {
            // SORTERING HÄR
            ForEach(navStore.document.userWaypoints.sorted { $0.id < $1.id }) { wp in
                NavigationLink(destination: PointEditorView(mode: .waypoint(wp), isNew: false)) {
                    HStack {
                        Image(systemName: "triangle.fill").font(.caption2).foregroundColor(.gray)
                        Text(wp.id).font(.headline)
                        if !wp.name.isEmpty && wp.name != wp.id { Text(wp.name).font(.caption).foregroundColor(.secondary) }
                        Spacer()
                        if wp.type != .custom {
                            Text(wp.type.rawValue).font(.caption2).padding(4).background(Color.gray.opacity(0.2)).cornerRadius(4)
                        }
                    }
                }
            }
            // OBS: onDelete fungerar inte direkt på en sorted array i en ForEach om vi inte hanterar index noga.
            // För enkelhetens skull tar vi bort swipe-delete här och litar på delete-knappen inne i editorn,
            // ELLER så måste vi slå upp objektet att radera.
            // Eftersom vi har sorterat, matchar inte indexet i ForEach indexet i den riktiga arrayen.
            // Lösning: Använd id-baserad radering via PointEditorView istället, eller implementera komplex swipe-logic.
            // Jag tar bort .onDelete här för att undvika buggar med sortering. Användaren kan radera inne i vyn.
        }
    }
    
    private var airportList: some View {
        List {
            ForEach(navStore.document.userAirports.sorted { $0.id < $1.id }) { ap in
                NavigationLink(destination: PointEditorView(mode: .airport(ap), isNew: false)) {
                    HStack {
                        Image(systemName: "airplane").foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(ap.id).font(.headline)
                            if !ap.name.isEmpty && ap.name != ap.id { Text(ap.name).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
            }
        }
    }
    
    private var navaidList: some View {
        List {
            ForEach(navStore.document.userNavaids.sorted { $0.id < $1.id }) { nv in
                NavigationLink(destination: PointEditorView(mode: .navaid(nv), isNew: false)) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(.orange)
                        VStack(alignment: .leading) {
                            Text(nv.id).font(.headline)
                            Text(nv.name).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}
