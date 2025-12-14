//
//  RouteIdGenerator.swift
//  Rut
//

import Foundation

enum RouteIdGenerator {
    static func sanitizeForRouteId(_ s: String) -> String {
        let upper = s.uppercased()
        return String(upper.filter { ch in
            (ch >= "A" && ch <= "Z") ||
            (ch >= "0" && ch <= "9") ||
            ch == "-"
        })
    }

    private static func alphaNumOnly(_ s: String) -> String {
        String(s.filter { ch in
            (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9")
        })
    }

    /// Create a unique 5-char route id based on `name`.
    /// - Parameters:
    ///   - name: route name
    ///   - taken: set of already used route ids (will be mutated)
    ///   - excluding: an id that is allowed to be reused (for rename of same route)
    static func makeUniqueId(fromName name: String,
                             taken: inout Set<String>,
                             excluding: String? = nil) -> String {
        var used = taken
        if let excluding { used.remove(excluding) }

        let sanitized = sanitizeForRouteId(name)
        let candidate5 = String(sanitized.prefix(5)).paddingRight(to: 5, with: "X")

        if !used.contains(candidate5) {
            taken.insert(candidate5)
            return candidate5
        }

        // Collision: use prefix3 + 2 digits (ABC01 .. ABC99)
        let prefix3Source = alphaNumOnly(sanitized)
        let prefix3 = String(prefix3Source.prefix(3)).paddingRight(to: 3, with: "X")

        for n in 1...99 {
            let id = prefix3 + String(format: "%02d", n)
            if !used.contains(id) {
                taken.insert(id)
                return id
            }
        }

        // Still collisions: prefix2 + 3 digits (AB001 .. AB999)
        let prefix2 = String(prefix3Source.prefix(2)).paddingRight(to: 2, with: "X")
        for n in 1...999 {
            let id = prefix2 + String(format: "%03d", n)
            if !used.contains(id) {
                taken.insert(id)
                return id
            }
        }

        // Worst-case fallback (should practically never happen)
        var i = 0
        while true {
            i += 1
            let id = "R" + String(format: "%04d", i) // R0001...
            if !used.contains(id) {
                taken.insert(id)
                return id
            }
        }
    }
}

private extension String {
    func paddingRight(to length: Int, with pad: Character) -> String {
        if self.count >= length { return String(self.prefix(length)) }
        return self + String(repeating: String(pad), count: length - self.count)
    }
}
