import Foundation

// Port of acoparse/timeperiod.py — NATO date-time groups and the APERIOD set.
// 011200ZJAN2026 is the 1st at 12:00Z in January 2026; the year may be two digits or missing.

/// A UTC date and time to the minute.
struct ACODateTime: Comparable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int

    static func < (a: ACODateTime, b: ACODateTime) -> Bool {
        (a.year, a.month, a.day, a.hour, a.minute) < (b.year, b.month, b.day, b.hour, b.minute)
    }

    /// `datetime.isoformat()` of a UTC datetime.
    var isoformat: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:00+00:00", year, month, day, hour, minute)
    }
}

/// An activation window, as far as it could be determined.
struct ACOTimePeriod {
    var start: ACODateTime? = nil
    var stop: ACODateTime? = nil
    /// `DISCRETE`, `CONTINUOUS`, `DAILY`, … as written in the set.
    var mode: String? = nil
    var raw: String = ""

    var isContinuous: Bool { (mode ?? "").uppercased().hasPrefix("CONT") }
}

enum ACODTG {
    private static let months = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
        "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
    ]

    private static let pattern = ACORegex(
        #"(?<day>\d{2})(?<hour>\d{2})(?<minute>\d{2})Z\s*(?<month>JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\s*(?<year>\d{4}|\d{2})?"#)

    /// The first date-time group in `text`, or nil when there is none or its fields are out of range.
    static func parse(_ text: String, defaultYear: Int?) -> ACODateTime? {
        guard let m = pattern.firstMatch(in: text.uppercased()) else { return nil }

        let year: Int
        if let yearText = m["year"], let value = Int(yearText) {
            year = yearText.count == 2 ? 2000 + value : value
        } else {
            guard let defaultYear else { return nil }
            year = defaultYear
        }

        guard let month = months[m["month"]!], let day = Int(m["day"]!),
              let hour = Int(m["hour"]!), let minute = Int(m["minute"]!) else { return nil }
        // Python's datetime() rejects out-of-range fields; the reference then returns None.
        guard (1...9999).contains(year), hour <= 23, minute <= 59,
              day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        return ACODateTime(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    /// Every date-time group in `text`, skipping any that are invalid.
    static func findAll(_ text: String, defaultYear: Int?) -> [ACODateTime] {
        pattern.matches(in: text.uppercased()).compactMap { parse($0.text, defaultYear: defaultYear) }
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}
