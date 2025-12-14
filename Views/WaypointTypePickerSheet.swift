import SwiftUI

struct WaypointTypePickerSheet: View {
    @EnvironmentObject var navStore: NavigationStore
    @EnvironmentObject var toastManager: ToastManager
    @Environment(\.dismiss) private var dismiss
    
    let route: Route
    let pointIndex: Int
    
    // Lokala state-variabler för redigering
    @State private var editedId: String = ""
    @State private var editedName: String = ""
    @State private var editedLat: String = ""
    @State private var editedLon: String = ""
    @State private var editedElev: String = ""
    
    var body: some View {
        NavigationStack { // Använd NavigationStack istället för NavigationView (modernare)
            Form {
                // SEKTION 1: Redigering av ID och Namn
                if currentWaypoint != nil {
                    Section(header: Text("Identification")) {
                        // ID Field
                        TextField("ID (Max 5 chars)", text: $editedId)
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                            // iOS 17 onChange syntax
                            .onChange(of: editedId) { _, newValue in
                                let filtered = newValue.uppercased().filter { $0.isLetter || $0.isNumber }
                                if filtered != newValue {
                                    editedId = filtered
                                }
                                if editedId.count > 5 {
                                    editedId = String(editedId.prefix(5))
                                }
                            }
                        
                        // Name Field
                        TextField("Name", text: $editedName)
                            .textInputAutocapitalization(.sentences)
                            .disableAutocorrection(true)
                            .onChange(of: editedName) { _, newValue in
                                if newValue.count > 15 {
                                    editedName = String(newValue.prefix(15))
                                }
                            }
                    }
                    
                    // SEKTION 2: Redigering av Position
                    Section(header: Text("Position")) {
                        TextField("Latitude", text: $editedLat)
                            .keyboardType(.decimalPad)
                        
                        TextField("Longitude", text: $editedLon)
                            .keyboardType(.decimalPad)
                        
                        TextField("Elevation (m)", text: $editedElev)
                            .keyboardType(.decimalPad)
                    }
                }
                
                // SEKTION 3: Logik
                // Om användaren har ändrat något -> Spara som Custom
                // Annars -> Visa snabbval
                
                if isModified {
                    Section {
                        Button {
                            saveAsCustomPoint()
                        } label: {
                            HStack {
                                Image(systemName: "square.and.pencil")
                                Text("Save changes (set to CUSTOM)")
                                Spacer()
                            }
                        }
                        .disabled(editedId.isEmpty)
                    } footer: {
                        Text("Saving custom changes will automatically set the waypoint type to CUSTOM.")
                    }
                    
                } else {
                    Section(header: Text("Quick set type")) {
                        // CUSTOM
                        Button {
                            apply(type: .custom)
                        } label: {
                            HStack {
                                Image(systemName: "mappin")
                                Text("CUSTOM (Keep current ID)")
                                Spacer()
                            }
                        }
                        
                        Button { apply(type: .wpt) } label: {
                            HStack {
                                Image(systemName: "circle.fill")
                                Text("WPT (Waypoint)")
                                Spacer()
                            }
                        }
                        
                        Button { apply(type: .ip) } label: {
                            HStack {
                                Image(systemName: "square.fill")
                                Text("IP (Initial Point)")
                                Spacer()
                            }
                        }
                        
                        Button { apply(type: .tgt) } label: {
                            HStack {
                                Image(systemName: "triangle.fill")
                                Text("TGT (Target)")
                                Spacer()
                            }
                        }
                        
                        Button { apply(type: .hld) } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("HLD (Hold)")
                                Spacer()
                            }
                        }
                        
                        Button { apply(type: .cli) } label: {
                            HStack {
                                Image(systemName: "arrow.up")
                                Text("CLI (Climb)")
                                Spacer()
                            }
                        }
                        
                        Button { apply(type: .des) } label: {
                            HStack {
                                Image(systemName: "arrow.down")
                                Text("DES (Descent)")
                                Spacer()
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle("Waypoint settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                loadInitialValues()
            }
        }
    }
    
    // MARK: - Helpers
    
    private var currentWaypoint: UserWaypoint? {
        guard pointIndex >= 0,
              pointIndex < route.pointRefs.count else { return nil }
        let ref = route.pointRefs[pointIndex]
        guard ref.kind == .userWaypoint else { return nil }
        return navStore.document.userWaypoints.first(where: { $0.id == ref.refId })
    }
    
    private func parseDouble(_ str: String) -> Double? {
        let clean = str.replacingOccurrences(of: ",", with: ".")
        return Double(clean)
    }
    
    private var isModified: Bool {
        guard let wp = currentWaypoint else { return false }
        
        let lat = parseDouble(editedLat) ?? wp.latitude
        let lon = parseDouble(editedLon) ?? wp.longitude
        let elev = parseDouble(editedElev) ?? wp.elevation
        
        let coordsChanged = abs(wp.latitude - lat) > 0.000001 ||
                            abs(wp.longitude - lon) > 0.000001 ||
                            abs(wp.elevation - elev) > 0.1
        
        return wp.id != editedId || wp.name != editedName || coordsChanged
    }
    
    private func loadInitialValues() {
        if let wp = currentWaypoint {
            editedId = wp.id
            editedName = wp.name
            editedLat = String(wp.latitude)
            editedLon = String(wp.longitude)
            editedElev = String(format: "%.0f", wp.elevation)
        }
    }
    
    // MARK: - Actions
    
    private func saveAsCustomPoint() {
        guard let wp = currentWaypoint else { return }
        
        let lat = parseDouble(editedLat) ?? wp.latitude
        let lon = parseDouble(editedLon) ?? wp.longitude
        let elev = parseDouble(editedElev) ?? wp.elevation
        
        let finalLat = min(max(lat, -90.0), 90.0)
        let finalLon = min(max(lon, -180.0), 180.0)
        
        // Uppdatera waypoint OCH sätt typ till CUSTOM
        navStore.updateWaypoint(
            originalId: wp.id,
            newName: editedName,
            newId: editedId,
            type: .custom, // VIKTIGT: Sätt typen till Custom här
            latitude: finalLat,
            longitude: finalLon,
            elevation: elev
        )
        
        dismiss()
    }
    
    private func apply(type: WaypointType) {
        guard pointIndex >= 0,
              pointIndex < route.pointRefs.count else { return }
        
        // Här används updateWaypointType som hanterar omnumrering av rutter
        navStore.updateWaypointType(
            in: route,
            at: pointIndex,
            to: type
        )
        
        dismiss()
    }
}
