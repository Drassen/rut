import Foundation

// Port of acoparse/lexer.py — split a USMTF message into sets, fields and subfields.
// Deliberately dumb and lossless: unknown sets survive untouched.

/// One `/`-separated field within a set.
struct ACOField {
    let raw: String

    /// Text before the first `:`, e.g. `NAME` in `NAME:A01`.
    var qualifier: String? {
        let p = ACOPy.partition(raw, ":")
        return p.found ? ACOPy.strip(p.head).uppercased() : nil
    }

    /// Text after the first `:`, or the whole field if there is none.
    var value: String {
        let p = ACOPy.partition(raw, ":")
        return ACOPy.strip(p.found ? p.tail : raw)
    }
}

/// One USMTF set, e.g. `EFFLEVEL/RARA:000GND-005GND//`.
struct ACOSetLine {
    /// Set identifier, upper-cased (`ACMID`, `EFFLEVEL`, `CIRCLE`, …).
    let name: String
    /// Fields after the set name, in order.
    let fields: [ACOField]
    /// The set exactly as it appeared in the source, minus the `//`.
    let raw: String
    /// 1-based line number where the set started.
    let line: Int

    /// Field at `index` (0-based, excluding the set name), or nil.
    func positional(_ index: Int) -> String? {
        index >= 0 && index < fields.count ? fields[index].raw : nil
    }
}

enum ACOLexer {
    private static let whitespace = ACORegex(#"\s+"#)

    /// Split a raw ACO/USMTF message into sets. Line breaks inside a set collapse to single
    /// spaces; a trailing fragment without a closing `//` is still emitted.
    static func tokenize(_ source: String) -> [ACOSetLine] {
        let scalars = Array(ACOPy.normalizeNewlines(source).unicodeScalars)
        var sets: [ACOSetLine] = []
        var start = 0
        var lineNo = 1
        var i = 0
        let n = scalars.count

        func text(_ from: Int, _ to: Int) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[from..<to])
            return String(view)
        }

        while i < n {
            if scalars[i] == "\n" {
                lineNo += 1
                i += 1
                continue
            }
            if scalars[i] == "/", i + 1 < n, scalars[i + 1] == "/" {
                let chunk = text(start, i)
                if let s = buildSet(chunk, lineOf(chunk, lineNo)) { sets.append(s) }
                i += 2
                start = i
                continue
            }
            i += 1
        }

        let tail = text(start, n)
        if !ACOPy.strip(tail).isEmpty, let s = buildSet(tail, lineOf(tail, lineNo)) {
            sets.append(s)
        }
        return sets
    }

    /// Line where the chunk's content began, given the line it ended on.
    private static func lineOf(_ chunk: String, _ endLine: Int) -> Int {
        let content = chunk.drop(while: { $0.isWhitespace })
        return max(1, endLine - content.filter { $0 == "\n" }.count)
    }

    private static func buildSet(_ chunk: String, _ line: Int) -> ACOSetLine? {
        let raw = ACOPy.strip(whitespace.replacing(in: chunk.replacingOccurrences(of: "\n", with: " "), with: " "))
        guard !raw.isEmpty else { return nil }
        let p = ACOPy.partition(raw, "/")
        let name = ACOPy.strip(p.head).uppercased()
        guard !name.isEmpty else { return nil }
        let fields = p.tail.isEmpty ? [] : p.tail.components(separatedBy: "/").map { ACOField(raw: ACOPy.strip($0)) }
        return ACOSetLine(name: name, fields: fields, raw: raw, line: line)
    }
}
