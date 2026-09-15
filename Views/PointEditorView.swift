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

    // Punkttyp (WPT/NAV/APT). Skiljer den sig från originalKind konverteras punkten vid sparning.
    @State private var pointKind: NavigationStore.UserPointKind = .waypoint
    @State private var originalKind: NavigationStore.UserPointKind? = nil   // nil för systempunkter
    @State private var originalName: String = ""
    @State private var hadA109AirportData = false

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
        !isReadOnly && pointKind == .waypoint
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

    // Befintlig punkt som byter typ
    private var isConverting: Bool {
        !isNew && !isReadOnly && originalKind != nil && pointKind != originalKind
    }

    // Text att visa som placeholder eller låst text
    private var idPlaceholder: String {
        isManagedType ? "\(wpType.rawValue)** (automatic numbering)" : "ID (Max 5 chars)"
    }

    private var namePlaceholder: String {
        isManagedType ? "\(wpType.rawValue)** (automatic numbering)" : "Name"
    }

    /// Segmented-style picker for waypoint naming. A system segmented control splits the
    /// 8 segments equally and truncates CUSTOM to "CUST…", so CUSTOM keeps its full width
    /// here and the short types share the rest.
    private var waypointNamingPicker: some View {
        HStack(spacing: 2) {
            ForEach(WaypointType.allCases, id: \.self) { type in
                let selected = wpType == type
                let isCustom = type == .custom
                Button { wpType = type } label: {
                    Text(type.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: isCustom, vertical: false)
                        .padding(.horizontal, isCustom ? 8 : 0)
                        .frame(maxWidth: isCustom ? nil : .infinity)
                        .padding(.vertical, 7)
                        .foregroundColor(selected ? .black : .primary)
                        .background(selected ? RutTheme.amber : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                // Plain style: each segment is its own tap target inside the Form row
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// Reasons the conversion can't be done. Save is disabled while this is non-empty,
    /// so nothing is changed until the conversion is valid.
    private var conversionProblems: [String] {
        guard isConverting, let from = originalKind else { return [] }
        return navStore.validateConversions([
            .init(fromKind: from, fromId: originalID, target: targetPoint())
        ])
    }

    /// What the conversion changes: data that is dropped and routes that use the point.
    private var conversionNotes: [String] {
        guard isConverting, let from = originalKind else { return [] }
        var notes: [String] = []
        if from == .navaid && freq != 0 {
            notes.append("Frequency will be removed.")
        }
        if from != .waypoint && pointKind == .waypoint && magVar != 0 {
            notes.append("Magnetic variation will be removed.")
        }
        if from == .airport && hadA109AirportData {
            notes.append("A109 airport data read from a card (usage, runway) will be removed.")
        }
        if from == .waypoint && wpType != .custom {
            notes.append("Waypoint naming \(wpType.rawValue) is not kept.")
        }
        for use in navStore.routesUsing(kind: from, id: originalID) {
            if use.isEndpoint && pointKind == .airport {
                notes.append("Route \(use.route.name): uses the point; as start/destination it becomes a logistic airport on A109 export.")
            } else if use.isEndpoint && from == .airport {
                notes.append("Route \(use.route.name): uses the point; start/destination will no longer be a logistic airport on A109 export.")
            } else {
                notes.append("Route \(use.route.name): uses the point and will keep it after conversion.")
            }
        }
        return notes
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

            // --- SEKTION 0: PUNKTTYP (WPT / NAV / APT) ---
            if !isReadOnly {
                Section("Point Type") {
                    Picker("Point type", selection: $pointKind) {
                        ForEach(NavigationStore.UserPointKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: pointKind) { _, newKind in
                        guard !isAutoUpdating else { return }
                        if newKind == .waypoint {
                            // Navaid/airport → waypoint: behåll ID och namn
                            if originalKind != .waypoint { wpType = .custom }
                        } else if id.isEmpty {
                            // Från managed waypoint (WPT**-placeholder): utgå från nuvarande ID
                            id = String(originalID.prefix(5))
                            if name.isEmpty { name = originalName }
                        }
                    }
                }
            }

            // --- SEKTION 1: TYP (Endast för Waypoints) ---
            if isWaypoint {
                Section("Waypoint Naming") {
                    waypointNamingPicker
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
            CoordinateInputSection(
                lat: $lat, lon: $lon,
                disabled: isReadOnly,
                showElevation: !isSystemNavaidOrAirport,
                elev: $elev
            )

            // --- SEKTION 4: DETALJER ---
            detailsSection

            // --- KONVERTERING ---
            if !conversionProblems.isEmpty {
                Section("Cannot convert") {
                    ForEach(conversionProblems, id: \.self) { problem in
                        Text(problem).font(.footnote).foregroundColor(.red)
                    }
                }
            }
            if !conversionNotes.isEmpty {
                Section("Conversion") {
                    ForEach(conversionNotes, id: \.self) { note in
                        Text(note).font(.footnote)
                    }
                }
            }

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
                    // Inaktivera spara om det är Custom och tomt, eller om konverteringen inte går.
                    // För Managed types (WPT**) genereras ID vid sparning, så det är ok att det är tomt nu.
                    .disabled((isManagedType ? false : id.isEmpty) || !conversionProblems.isEmpty)
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
        if isReadOnly {
            if case .systemNavaid(let nv) = mode { Section("System Details") { Text("Type: \(nv.type)") } }
        } else {
            switch pointKind {
            case .airport: Section("Airport Details") { HStack { Text("Mag Var:"); TextField("Val", value: $magVar, format: .number).keyboardType(.numbersAndPunctuation) } }
            case .navaid: Section("Navaid Details") {
                HStack { Text("Freq:"); TextField("MHz", value: $freq, format: .number).keyboardType(.decimalPad) }
                HStack { Text("Mag Var:"); TextField("Val", value: $magVar, format: .number).keyboardType(.numbersAndPunctuation) }
            }
            case .waypoint: EmptyView()
            }
        }
    }

    private func loadData() {
        isAutoUpdating = true

        switch mode {
        case .airport(let ap):
            pointKind = .airport; originalKind = .airport
            originalID = ap.id; id = ap.id; name = ap.name; originalName = ap.name
            lat = ap.latitude; lon = ap.longitude; elev = ap.elevation; magVar = ap.magneticVariation
            hadA109AirportData = !ap.usage.isEmpty || !ap.longestRunway.isEmpty || !ap.rawUnknown1.isEmpty
        case .navaid(let nv):
            pointKind = .navaid; originalKind = .navaid
            originalID = nv.id; id = nv.id; name = nv.name; originalName = nv.name
            lat = nv.latitude; lon = nv.longitude; elev = nv.elevation; magVar = nv.magneticVariation; freq = nv.frequency
        case .waypoint(let wp):
            pointKind = .waypoint; originalKind = .waypoint
            originalID = wp.id; wpType = wp.type; originalName = wp.name
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

    /// The point as it will be saved in the selected point type.
    private func targetPoint() -> NavigationStore.UserPoint {
        let cleanName = NavigationStore.sanitizedName(name, maxLength: 15)
        let finalName = cleanName.isEmpty ? id : cleanName
        switch pointKind {
        case .waypoint:
            if isManagedType {
                let newId = navStore.nextAvailableId(for: wpType)
                return .waypoint(UserWaypoint(id: newId, name: newId, type: wpType, latitude: lat, longitude: lon, elevation: elev))
            }
            return .waypoint(UserWaypoint(id: id, name: finalName, type: wpType, latitude: lat, longitude: lon, elevation: elev))
        case .navaid:
            return .navaid(UserNavaid(id: id, name: finalName, latitude: lat, longitude: lon, elevation: elev, magneticVariation: magVar, frequency: freq))
        case .airport:
            return .airport(UserAirport(id: id, name: finalName, latitude: lat, longitude: lon, elevation: elev, magneticVariation: magVar))
        }
    }

    private func saveChanges() {
        guard !isReadOnly else { return }

        if isConverting, let from = originalKind {
            // Valideras igen i convertPoints; misslyckas den ändras ingenting
            navStore.convertPoints([.init(fromKind: from, fromId: originalID, target: targetPoint())])
            return
        }

        switch pointKind {
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
