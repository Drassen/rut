import Foundation

// The ACO parser in this folder is a Swift port of the acoparse reference implementation
// (acoparse/parser_lib/python). Python is authoritative: where the two disagree the port
// has a bug. These helpers reproduce the Python behaviour the reference relies on, so the
// port gives the same answers (checked with acoparse's parity dump and compare.py).

enum ACOPy {
    static let degToRad = Double.pi / 180.0
    static let radToDeg = 180.0 / Double.pi

    /// `math.radians`
    static func radians(_ x: Double) -> Double { x * degToRad }

    /// `math.degrees`
    static func degrees(_ x: Double) -> Double { x * radToDeg }

    /// `a % b` for floats: the result takes the sign of the divisor.
    static func mod(_ a: Double, _ b: Double) -> Double {
        var m = fmod(a, b)
        if m != 0 {
            if (b < 0) != (m < 0) { m += b }
        } else {
            m = copysign(0, b)
        }
        return m
    }

    /// `round(x)`: half to even.
    static func round(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

    /// `s.strip()`
    static func strip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `s.partition(sep)`
    static func partition(_ s: String, _ sep: String) -> (head: String, found: Bool, tail: String) {
        guard let r = s.range(of: sep) else { return (s, false, "") }
        return (String(s[..<r.lowerBound]), true, String(s[r.upperBound...]))
    }

    /// `repr(s)` for a str, as used in warning messages.
    static func repr(_ s: String) -> String {
        let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if Character(scalar) == quote {
                    out += "\\\(quote)"
                } else if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append(quote)
        return out
    }

    /// Line breaks normalised to "\n", as Python's text-mode file reading does.
    static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Python's `re` on top of NSRegularExpression. Patterns use `(?<name>…)` for `(?P<name>…)`.
struct ACORegex {
    private let regex: NSRegularExpression

    init(_ pattern: String, multiline: Bool = false) {
        // Patterns are constants in this module; an invalid one is a programming error.
        regex = try! NSRegularExpression(pattern: pattern, options: multiline ? [.anchorsMatchLines] : [])
    }

    struct Match {
        fileprivate let result: NSTextCheckingResult
        fileprivate let source: NSString

        /// A named group's text, or nil when the group did not take part (Python's `None`).
        subscript(name: String) -> String? {
            let range = result.range(withName: name)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }

        /// `m.group(0)`
        var text: String { source.substring(with: result.range) }
    }

    /// `re.finditer`
    func matches(in s: String) -> [Match] {
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { Match(result: $0, source: ns) }
    }

    /// `re.search`, and `re.match` for patterns anchored with `^`
    func firstMatch(in s: String) -> Match? {
        let ns = s as NSString
        return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
            .map { Match(result: $0, source: ns) }
    }

    func contains(_ s: String) -> Bool { firstMatch(in: s) != nil }

    /// `re.sub` with a literal replacement
    func replacing(in s: String, with replacement: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// `re.split` for a pattern without capture groups
    func split(_ s: String) -> [String] {
        let ns = s as NSString
        var pieces: [String] = []
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        pieces.append(ns.substring(from: last))
        return pieces
    }
}
