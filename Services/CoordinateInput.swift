import SwiftUI
import CoreLocation

// MARK: - Coordinate parsing helper

/// Tries to parse a string as a coordinate. Understands:
///   • MGRS  (e.g. "33VXF1234567890", "33V XF 12345 67890", "33VXF12356789")
///   • Decimal degrees (e.g. "59.5", "-0.123")
///   • DMS compact (e.g. "593000N" handled by ACO parser, not needed here)
/// Returns nil if the string is not parseable as a single-axis value.
/// For MGRS (which contains both lat & lon), use parseMGRS directly.
enum CoordinateParser {
    static func parseMGRS(_ text: String) -> CLLocationCoordinate2D? {
        MGRSConverter.toCoordinate(text)
    }

    static func looksLikeMGRS(_ text: String) -> Bool {
        // Quick heuristic: starts with 1-2 digits, then a letter C-X, then 2 letters, then optional digits
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

    static func parseLatLon(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }
}

// MARK: - Reusable MGRS coordinate input view
// Drop-in replacement for a lat/lon pair. Accepts either MGRS (fills both)
// or separate decimal degrees.

struct MGRSCoordinateField: View {
    let label: String
    @Binding var lat: Double
    @Binding var lon: Double
    var disabled: Bool = false

    @State private var mgrsText: String = ""
    @State private var mgrsValid: Bool? = nil  // nil=empty, true=ok, false=invalid

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("MGRS or Lat / Lon", text: $mgrsText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .disabled(disabled)
                    .foregroundColor(disabled ? .secondary : .primary)
                    .onChange(of: mgrsText) { _, new in
                        let trimmed = new.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { mgrsValid = nil; return }
                        if CoordinateParser.looksLikeMGRS(trimmed) {
                            if let coord = CoordinateParser.parseMGRS(trimmed) {
                                lat = coord.latitude
                                lon = coord.longitude
                                mgrsValid = true
                            } else {
                                mgrsValid = false
                            }
                        } else {
                            mgrsValid = nil  // decimal mode — don't touch lat/lon here
                        }
                    }
                if let valid = mgrsValid {
                    Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(valid ? .green : .red)
                        .font(.system(size: 14))
                }
            }
            Text("MGRS (e.g. 33VXF1234567890) or enter lat/lon below")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - String lat/lon fields with MGRS awareness
// For views that already use String-based lat/lon fields (WaypointTypePickerSheet).

extension String {
    /// Parses the string as either decimal degrees or an MGRS string.
    /// For MGRS, returns the latitude component (use parsedAsCoordinate for both axes).
    func parsedAsLatitude(fallback: Double = 0) -> Double {
        if let d = Double(self.replacingOccurrences(of: ",", with: ".")) { return d }
        if let c = CoordinateParser.parseMGRS(self) { return c.latitude }
        return fallback
    }

    func parsedAsLongitude(fallback: Double = 0) -> Double {
        if let d = Double(self.replacingOccurrences(of: ",", with: ".")) { return d }
        if let c = CoordinateParser.parseMGRS(self) { return c.longitude }
        return fallback
    }

    /// If this string looks like MGRS, return the full coordinate; otherwise nil.
    var asMGRSCoordinate: CLLocationCoordinate2D? {
        CoordinateParser.looksLikeMGRS(self) ? CoordinateParser.parseMGRS(self) : nil
    }
}
