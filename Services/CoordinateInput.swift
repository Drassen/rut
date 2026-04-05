import SwiftUI
import CoreLocation

// MARK: - Coordinate mode

enum CoordinateMode: String, CaseIterable {
    case latlon = "Lat/Lon"
    case mgrs   = "MGRS"
}

// MARK: - CoordinateParser helpers

enum CoordinateParser {
    static func parseMGRS(_ text: String) -> CLLocationCoordinate2D? {
        MGRSConverter.toCoordinate(text)
    }

    static func looksLikeMGRS(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " ", with: "")
                    .uppercased()
        guard s.count >= 3 else { return false }
        var i = s.startIndex
        var digitCount = 0
        while i < s.endIndex && s[i].isNumber && digitCount < 2 {
            i = s.index(after: i); digitCount += 1
        }
        guard digitCount >= 1, i < s.endIndex else { return false }
        let band = s[i]
        guard "C" <= band && band <= "X" && band != "I" && band != "O" else { return false }
        return true
    }
}

// MARK: - Coordinate input section
// A Form Section containing a Lat/Lon ↔ MGRS toggle.
// Switching modes converts the current values.

struct CoordinateInputSection: View {
    @Binding var lat: Double
    @Binding var lon: Double
    var disabled: Bool = false
    var showElevation: Bool = false
    @Binding var elev: Double

    @State private var mode: CoordinateMode = .latlon
    @State private var mgrsText: String = ""
    @State private var mgrsValid: Bool? = nil  // nil=empty/not-mgrs, true=ok, false=bad

    var body: some View {
        Section("Position") {
            // Mode toggle
            Picker("Format", selection: $mode) {
                ForEach(CoordinateMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .disabled(disabled)
            .onChange(of: mode) { _, newMode in
                switch newMode {
                case .mgrs:
                    // Convert current lat/lon to MGRS
                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    mgrsText = MGRSConverter.fromCoordinate(coord) ?? ""
                    mgrsValid = mgrsText.isEmpty ? nil : true
                case .latlon:
                    // Parse current MGRS back to lat/lon
                    if let coord = CoordinateParser.parseMGRS(mgrsText) {
                        lat = coord.latitude
                        lon = coord.longitude
                    }
                    mgrsValid = nil
                }
            }

            if mode == .mgrs {
                // MGRS single field
                HStack {
                    TextField("MGRS (e.g. 33VXF1234567890)", text: $mgrsText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .disabled(disabled)
                        .onChange(of: mgrsText) { _, new in
                            let trimmed = new.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { mgrsValid = nil; return }
                            if let coord = CoordinateParser.parseMGRS(trimmed) {
                                lat = coord.latitude
                                lon = coord.longitude
                                mgrsValid = true
                            } else {
                                mgrsValid = false
                            }
                        }
                    if let valid = mgrsValid {
                        Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(valid ? .green : .red)
                            .font(.system(size: 14))
                    }
                }
            } else {
                // Lat/Lon fields
                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow {
                        Text("Lat:")
                        TextField("Latitude", value: $lat, format: .number.precision(.fractionLength(4...6)))
                            .keyboardType(.numbersAndPunctuation)
                            .disabled(disabled)
                    }
                    GridRow {
                        Text("Lon:")
                        TextField("Longitude", value: $lon, format: .number.precision(.fractionLength(4...6)))
                            .keyboardType(.numbersAndPunctuation)
                            .disabled(disabled)
                    }
                }
            }

            if showElevation {
                HStack {
                    Text("Elev (ft):")
                    TextField("Elevation", value: $elev, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .disabled(disabled)
                }
            }
        }
        .onAppear {
            // Start in lat/lon mode; mgrsText empty until user switches
            mgrsText = ""
            mgrsValid = nil
        }
    }
}

// MARK: - String helpers (used by WaypointTypePickerSheet)

extension String {
    var asMGRSCoordinate: CLLocationCoordinate2D? {
        CoordinateParser.looksLikeMGRS(self) ? CoordinateParser.parseMGRS(self) : nil
    }
}
