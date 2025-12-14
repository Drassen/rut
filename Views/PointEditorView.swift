import SwiftUI
import CoreLocation

struct PointEditorView: View {
    @EnvironmentObject var navStore: NavigationStore
    @Environment(\.dismiss) var dismiss
    
    enum EditMode {
        case airport(UserAirport)
        case navaid(UserNavaid)
        case waypoint(UserWaypoint)
        
        case systemAirport(JepAirport)
        case systemNavaid(JepNavaid)
    }
    
    let mode: EditMode
    var isNew: Bool = false
    
    // State för redigering
    @State private var id: String = ""
    @State private var name: String = ""
    @State private var lat: Double = 0.0
    @State private var lon: Double = 0.0
    @State private var elev: Double = 0.0
    @State private var magVar: Double = 0.0
    @State private var freq: Double = 0.0
    @State private var wpType: WaypointType = .custom
    
    @State private var isAutoUpdating = false
    @State private var originalID: String = ""
    @State private var showDeleteConfirmation = false
    
    // MARK: - Computed Properties
    
    private var isReadOnly: Bool {
        switch mode {
        case .systemAirport, .systemNavaid: return true
        default: return false
        }
    }
    
    private var isWaypoint: Bool {
        if case .waypoint = mode { return true }
        return false
    }
    
    private var isSystemNavaidOrAirport: Bool {
        switch mode {
        case .systemAirport, .systemNavaid: return true
        default: return false
        }
    }
    
    // Om vi ska hantera ID/Namn automatiskt (dvs. inte Custom)
    private var isManagedType: Bool {
        isWaypoint && wpType != .custom
    }
    
    // Text att visa som placeholder eller låst text
    private var idPlaceholder: String {
        isManagedType ? "\(wpType.rawValue)**" : "ID (Max 5 chars)"
    }
    
    private var namePlaceholder: String {
        isManagedType ? "\(wpType.rawValue)**" : "Name"
    }
    
    // MARK: - Body
    
    var body: some View {
        Form {
            if isReadOnly {
                Section {
                    Text("This point is part of the system database and cannot be edited.")
                        .font(.caption).foregroundColor(.secondary)
                        .listRowBackground(Color.yellow.opacity(0.1))
                }
            }
            
            // --- SEKTION 1: TYP (Endast för Waypoints) ---
            if isWaypoint {
                Section("Waypoint Type") {
                    Picker("Type", selection: $wpType) {
                        ForEach(WaypointType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isReadOnly)
                    .onChange(of: wpType) { _, newType in
                        // Om vi byter typ -> Rensa fälten så placeholdern syns (om managed), annars behåll/återställ
                        if newType != .custom {
                            id = ""
                            name = ""
                        } else if !originalID.isEmpty && originalID != id {
                            // Om man byter tillbaka till Custom, kanske återställ originalet?
                            // Eller låt det vara tomt för manuell inmatning. Vi låter det vara tomt.
                        }
                    }
                }
            }
            
            // --- SEKTION 2: IDENTIFIKATION ---
            Section("Identification") {
                TextField(idPlaceholder, text: $id)
                    .textInputAutocapitalization(.characters)
                    // Inaktivera om System eller Managed (WPT**, TGT** etc)
                    .disabled(isReadOnly || isManagedType)
                    .foregroundColor((isReadOnly || isManagedType) ? .secondary : .primary)
                    .onChange(of: id) { _, newValue in
                        if !isReadOnly && !isManagedType {
                            let formatted = String(newValue.prefix(5)).uppercased()
                            if id != formatted { id = formatted }
                        }
                    }
                
                TextField(namePlaceholder, text: $name)
                    .disabled(isReadOnly || isManagedType)
                    .foregroundColor((isReadOnly || isManagedType) ? .secondary : .primary)
            }
            
            // --- SEKTION 3: POSITION ---
            Section("Position") {
                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow {
                        Text("Lat:")
                        TextField("Latitude", value: $lat, format: .number.precision(.fractionLength(4...6)))
                            .keyboardType(.numbersAndPunctuation)
                            .disabled(isReadOnly)
                    }
                    GridRow {
                        Text("Lon:")
                        TextField("Longitude", value: $lon, format: .number.precision(.fractionLength(4...6)))
                            .keyboardType(.numbersAndPunctuation)
                            .disabled(isReadOnly)
                    }
                    if !isSystemNavaidOrAirport {
                        GridRow {
                            Text("Elev (ft):")
                            TextField("Elevation", value: $elev, format: .number)
                                .keyboardType(.numbersAndPunctuation)
                                .disabled(isReadOnly)
                        }
                    }
                }
            }
            
            // --- SEKTION 4: DETALJER ---
            detailsSection
            
            // --- DELETE ---
            if !isNew && !isReadOnly {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Point", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle(titleString)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isNew ? "Cancel" : "Close") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if !isReadOnly {
                    Button("Save") {
                        
                        saveChanges()
                        dismiss()
                    }.buttonStyle(.borderedProminent)
                    // Inaktivera spara BARA om det är Custom och tomt.
                    // För Managed types (WPT**) genereras ID vid sparning, så det är ok att det är tomt nu.
                    .disabled(isManagedType ? false : id.isEmpty)
                }
            }
        }
        .onAppear { loadData() }
        .confirmationDialog("Are you sure?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deletePoint()
                dismiss()
            }
        }
    }
    
    @ViewBuilder
    private var detailsSection: some View {
        switch mode {
        case .airport: Section("Airport Details") { HStack { Text("Mag Var:"); TextField("Val", value: $magVar, format: .number).keyboardType(.numbersAndPunctuation) } }
        case .navaid: Section("Navaid Details") {
            HStack { Text("Freq:"); TextField("MHz", value: $freq, format: .number).keyboardType(.decimalPad) }
            HStack { Text("Mag Var:"); TextField("Val", value: $magVar, format: .number).keyboardType(.numbersAndPunctuation) }
        }
        case .systemNavaid(let nv): Section("System Details") { Text("Type: \(nv.type)") }
        default: EmptyView()
        }
    }
    
    private func loadData() {
        isAutoUpdating = true
        
        switch mode {
        case .airport(let ap):
            originalID = ap.id; id = ap.id; name = ap.name
            lat = ap.latitude; lon = ap.longitude; elev = ap.elevation; magVar = ap.magneticVariation
        case .navaid(let nv):
            originalID = nv.id; id = nv.id; name = nv.name
            lat = nv.latitude; lon = nv.longitude; elev = nv.elevation; magVar = nv.magneticVariation; freq = nv.frequency
        case .waypoint(let wp):
            originalID = wp.id; wpType = wp.type
            lat = wp.latitude; lon = wp.longitude; elev = wp.elevation
            
            // Om Custom: Ladda in texten
            if wp.type == .custom {
                id = wp.id
                name = wp.name
            } else {
                // Om Managed: Lämna tomt så placeholdern (WPT**) syns
                id = ""
                name = ""
            }
            
        case .systemAirport(let ap):
            originalID = ap.id; id = ap.id; name = "System Airport"; lat = ap.latitude; lon = ap.longitude
        case .systemNavaid(let nv):
            originalID = nv.id; id = nv.id; name = "System Navaid"; lat = nv.latitude; lon = nv.longitude
        }
        
        DispatchQueue.main.async { isAutoUpdating = false }
    }
    
    private func saveChanges() {
        guard !isReadOnly else { return }
        
        switch mode {
        case .airport:
            if isNew { navStore.createUserAirport(UserAirport(id: id, name: name, latitude: lat, longitude: lon, elevation: elev, magneticVariation: magVar)) }
            else { navStore.updateAirport(originalId: originalID, newId: id, newName: name, latitude: lat, longitude: lon, elevation: elev, magVar: magVar) }
        case .navaid:
            if isNew { navStore.createUserNavaid(UserNavaid(id: id, name: name, latitude: lat, longitude: lon, elevation: elev, magneticVariation: magVar, frequency: freq)) }
            else { navStore.updateNavaid(originalId: originalID, newId: id, newName: name, latitude: lat, longitude: lon, elevation: elev, magVar: magVar, frequency: freq) }
        case .waypoint:
            
            // --- ID GENERERING FÖR WAYPOINTS ---
            var finalId = id
            var finalName = name
            
            if isManagedType {
                // Om vi inte redigerar en befintlig med SAMMA typ (för att behålla numret), generera nytt
                let prefix = wpType.rawValue
                
                // Om vi redigerar en befintlig punkt som redan matchar typen (t.ex. WPT03), behåll den!
                if !isNew && originalID.hasPrefix(prefix) {
                     finalId = originalID
                } else {
                    // Annars (Ny punkt, eller bytt typ): Hämta nästa lediga (t.ex. WPT05)
                    finalId = navStore.nextAvailableId(for: wpType)
                }
                finalName = finalId
            }
            
            if isNew {
                let newWp = UserWaypoint(id: finalId, name: finalName, type: wpType, latitude: lat, longitude: lon, elevation: elev)
                navStore.createUserWaypoint(newWp)
            } else {
                navStore.updateWaypoint(
                    originalId: originalID,
                    newName: finalName,
                    newId: finalId,
                    type: wpType,
                    latitude: lat,
                    longitude: lon,
                    elevation: elev
                )
            }
        default: break
        }
    }
    
    private func deletePoint() {
        guard !isReadOnly else { return }
        switch mode {
        case .airport: navStore.deleteUserAirport(withID: originalID)
        case .navaid: navStore.deleteUserNavaid(withID: originalID)
        case .waypoint: navStore.deleteUserWaypoint(withID: originalID)
        default: break
        }
    }
    
    private var titleString: String { isNew ? "Add Point" : (isReadOnly ? "Point Details" : "Edit Point") }
}
