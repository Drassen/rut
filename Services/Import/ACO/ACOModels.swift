import Foundation

// Port of acoparse/models.py — what an ACO describes.

/// Something the parser could not handle, kept rather than raised.
struct ACOParseWarning {
    let message: String
    var line: Int = 0
    var setName: String? = nil
    /// The set or record the warning is about, so it can be shown to a user.
    var raw: String = ""

    /// `str(warning)`
    var description: String {
        guard line != 0 else { return message }
        let set = setName.flatMap { $0.isEmpty ? nil : ", \($0)" } ?? ""
        return "\(message) (line \(line)\(set))"
    }
}

/// One airspace control means: an ACMID set plus everything under it.
struct ACOAirspace {
    var name = ""
    /// The `ACM:` code, e.g. `CORRTE`, `ROZ`, `REFPT`.
    var acmType: String? = nil
    /// The `USE:` code, e.g. `SAAFR`, `AAR`.
    var usage: String? = nil
    var geometry: ACOGeometry? = nil
    var vertical: ACOVerticalExtent? = nil
    var periods: [ACOTimePeriod] = []
    var remarks: [String] = []
    /// Every `KEY:VALUE` field seen, so nothing is lost to the model.
    var attributes: [String: String] = [:]
    /// The raw sets this airspace was built from.
    var sets: [ACOSetLine] = []
    /// From CONTAUTH — who controls the airspace while it is active.
    var controllingAuthority: String? = nil
    /// The record carries no data beyond its name (USMTF no-data marker `-`).
    var isNil = false
    var line = 0

    var category: String { ACOModels.categorise(acmType, usage) }

    /// Human-readable expansion of the ACM type, or the code itself.
    var description: String {
        guard let acmType, !acmType.isEmpty else { return "Unknown" }
        return ACOModels.acmTypes[acmType.uppercased()] ?? acmType
    }

    var shapeKind: String? { geometry?.kind }
    var lowerFt: Double? { vertical?.lowerFt }
    var upperFt: Double? { vertical?.upperFt }
    var start: ACODateTime? { periods.compactMap(\.start).min() }
    var stop: ACODateTime? { periods.compactMap(\.stop).max() }

    /// `dict.setdefault`
    mutating func setAttributeIfAbsent(_ key: String, _ value: String) {
        if attributes[key] == nil { attributes[key] = value }
    }
}

/// A parsed ACO message.
struct ACODocument {
    var airspaces: [ACOAirspace] = []
    /// Every set in the file, including header and unrecognised ones.
    var sets: [ACOSetLine] = []
    var warnings: [ACOParseWarning] = []
    /// Message-level fields from MSGID, EXER, OPER, TIMEFRM.
    var header: [String: String] = [:]
    var validFrom: ACODateTime? = nil
    var validTo: ACODateTime? = nil
    var source: String? = nil

    var exercise: String? { header["exercise"] }
    var operation: String? { header["operation"] }
    var originator: String? { header["originator"] }
    var serial: String? { header["serial"] }

    /// Count of airspaces per ACM type.
    func summary() -> [String: Int] {
        var counts: [String: Int] = [:]
        for a in airspaces {
            let key = (a.acmType ?? "").isEmpty ? "UNKNOWN" : a.acmType!
            counts[key, default: 0] += 1
        }
        return counts
    }
}

enum ACOModels {
    /// Known `ACM:` codes and what they stand for.
    static let acmTypes: [String: String] = [
        // Airspace control means seen in live NATO ACOs
        "ATC": "Air Traffic Control Area",
        "SUA": "Special Use Airspace",
        "ADAREA": "Air Defense Area",
        "ADOA": "Air Defense Operations Area",
        "PROC": "Procedural Control",
        // Zones and areas
        "ROZ": "Restricted Operations Zone",
        "RESTOP": "Restricted Operations Area",
        "HIDACZ": "High Density Airspace Control Zone",
        "MOA": "Military Operations Area",
        "TAOR": "Tactical Area of Responsibility",
        "ADIZ": "Air Defense Identification Zone",
        "WFZ": "Weapons Free Zone",
        "WEZ": "Weapons Engagement Zone",
        "FEZ": "Fighter Engagement Zone",
        "MEZ": "Missile Engagement Zone",
        "JEZ": "Joint Engagement Zone",
        "NFA": "No Fire Area",
        "KILLBOX": "Kill Box",
        "KB": "Kill Box",
        "ATKAR": "Attack Area",
        "BSA": "Brigade Support Area",
        "DZ": "Drop Zone",
        "LZ": "Landing Zone",
        "PZ": "Pickup Zone",
        "AAR": "Air-to-Air Refuelling Area",
        "ARA": "Air Refuelling Area",
        "CAP": "Combat Air Patrol",
        "JSA": "Joint Special Area",
        "TBA": "Target Box Area",
        // Routes and corridors
        "CORRTE": "Corridor Route",
        "CORRIDOR": "Corridor",
        "SAAFR": "Standard Use Army Aircraft Flight Route",
        "LLTR": "Low Level Transit Route",
        "MRR": "Minimum Risk Route",
        "TC": "Transit Corridor",
        "AC": "Air Corridor",
        "ROUTE": "Route",
        // Points
        "REFPT": "Reference Point",
        "ACP": "Air Control Point",
        "CP": "Contact Point",
        "IP": "Initial Point",
        "EG": "Entry Gate",
        "XG": "Exit Gate",
        "BE": "Bullseye",
        "NAVAID": "Navigation Aid",
        // USE: codes, which name the purpose rather than the means
        "UAV": "Unmanned Aerial Vehicle Operations",
        "NOFLY": "No-Fly Area",
        "DA": "Danger Area",
        "TSA": "Temporary Segregated Area",
        "RA": "Restricted Area",
        "ROA": "Restricted Operations Area",
        "TCA": "Terminal Control Area",
        "CTA": "Control Area",
        "CONTZN": "Control Zone",
        "TRNG": "Training Area",
        "WARN": "Warning Area",
        "AOA": "Area of Operations",
        "JOA": "Joint Operations Area",
        "RECCE": "Reconnaissance",
        "AEW": "Airborne Early Warning",
        "CAS": "Close Air Support",
        "ASCA": "Airspace Coordination Area",
        "HIMEZ": "High Altitude Missile Engagement Zone",
        "LOMEZ": "Low Altitude Missile Engagement Zone",
        "LMEZ": "Low Altitude Missile Engagement Zone",
        "SL": "Safe Lane",
        "IFFON": "IFF On Line",
        "IFFOFF": "IFF Off Line",
    ]

    /// Coarse categories for grouping and styling, in the reference's lookup order.
    private static let categories: [(name: String, members: Set<String>)] = [
        ("CORRIDOR", ["CORRTE", "CORRIDOR", "SAAFR", "LLTR", "MRR", "TC", "AC", "ROUTE", "SL", "TR"]),
        ("POINT", ["REFPT", "ACP", "CP", "IP", "EG", "XG", "BE", "NAVAID", "IFFON", "IFFOFF"]),
        ("ROZ", ["ROZ", "RESTOP", "ROA", "RA", "NOFLY", "DA", "WARN"]),
        ("ZONE", ["HIDACZ", "MOA", "TAOR", "ADIZ", "JSA", "ATC", "SUA", "ADAREA", "ADOA",
                  "TSA", "TCA", "CTA", "CONTZN", "TRNG", "AOA", "JOA", "PROC"]),
        ("FIRES", ["WFZ", "WEZ", "FEZ", "MEZ", "JEZ", "NFA", "KILLBOX", "KB", "ATKAR", "TBA",
                   "HIMEZ", "LOMEZ", "LMEZ"]),
        ("SUPPORT", ["AAR", "ARA", "CAP", "DZ", "LZ", "PZ", "BSA", "UAV", "RECCE", "AEW", "CAS"]),
    ]

    /// Map an `ACM:`/`USE:` code onto a coarse category; unrecognised codes are `OTHER`.
    static func categorise(_ acmType: String?, _ usage: String?) -> String {
        for code in [acmType, usage] {
            guard let code, !code.isEmpty else { continue }
            let token = ACOPy.strip(code).uppercased()
            if let category = categories.first(where: { $0.members.contains(token) }) {
                return category.name
            }
        }
        return "OTHER"
    }
}
