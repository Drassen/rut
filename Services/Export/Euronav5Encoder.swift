import Foundation

/// Byte-exact encoder for the Euronav5 USER-database format
/// (`USERN.tbl` + `USERN-{ID,LN,OI}.idx`).
///
/// Direct port of the verified Python reference implementation in
/// `Euronav5 avkodning/analysis/euronav5.py`. Format specification and
/// proofs: `Docs/Euronav5/`. Every rule here reproduced all 45 files of
/// the 10 reference sets byte-for-byte (run `verify_all.py`, sections
/// "figure-level regeneration").
///
/// Foundation-only on purpose so it can be compiled and tested outside
/// the app target (see `Euronav5 avkodning/analysis/verify_swift.py`).
struct Euronav5Encoder {

    // MARK: - Figure model

    enum FigureKind {
        /// Open polyline: one record per vertex, USEROBJECTID = +counter.
        case line
        /// Closed shape: vertices WITHOUT closing repeat (the encoder adds
        /// it), USEROBJECTID = -counter.
        case polygon
        /// Single-record object with a radius, USEROBJECTID = 0.
        case circle
        /// Single-record object without a radius (production "obstacle
        /// point" pattern), USEROBJECTID = 0.
        case point
    }

    struct Figure {
        var kind: FigureKind
        /// User-visible figure name; stored as max 20 latin-1 bytes.
        var name: String
        /// Zone type string ("" for plain drawings). Verified values:
        /// NAVIGATIONALZONE, DANGERZONE, RESTRICTEDZONE, PROHIBITEDZONE,
        /// OBSTACLE.
        var type: String = ""
        /// Vertices as (lat, lon) microdegrees. For .circle/.point: one
        /// element, the center. For .polygon: WITHOUT the closing repeat.
        var points: [(Int32, Int32)]
        /// Circle radius in metres (.circle only).
        var radiusMeters: Int32 = 0
        /// Zone ceiling / object height in metres; nil = not set (-1025).
        var elevationMeters: Int32?
        /// Warning-system flag. nil = derive from elevation (the planner
        /// behaviour observed in 100% of reference data).
        var warningSensitive: Bool?
    }

    struct Timestamp {
        var year: UInt16, month: UInt16, day: UInt16
        var hour: UInt16, minute: UInt16, second: UInt16

        init(year: UInt16, month: UInt16, day: UInt16,
             hour: UInt16, minute: UInt16, second: UInt16) {
            (self.year, self.month, self.day) = (year, month, day)
            (self.hour, self.minute, self.second) = (hour, minute, second)
        }

        init(date: Date = Date(), calendar: Calendar = .current) {
            let c = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            self.init(year: UInt16(c.year!), month: UInt16(c.month!),
                      day: UInt16(c.day!), hour: UInt16(c.hour!),
                      minute: UInt16(c.minute!), second: UInt16(c.second!))
        }
    }

    // MARK: - Format constants

    static let headerSize = 3480
    static let pageSize = 4104
    static let recordSize = 256
    static let recordsPerPage = 16
    static let elevationNotSet: Int32 = -1025

    /// TYPE -> APPERANCE (appMatrix style id). Verified pairings from the
    /// reference sets; OBSTACLE values follow the production database
    /// (581 = most common single-point obstacle style, 81 = closed
    /// obstacle figures) since no planner-drawn obstacle sample exists.
    static func appearance(forType type: String, kind: FigureKind) -> Int32 {
        switch type {
        case "":                 return 806  // FDRAWING
        case "NAVIGATIONALZONE": return 802  // FNAVIGATIONAL
        case "DANGERZONE":       return 800  // FDANGER
        case "RESTRICTEDZONE":   return 803  // FOPERATION
        case "PROHIBITEDZONE":   return 806  // FDRAWING
        case "OBSTACLE":         return kind == .polygon ? 81 : 581
        default:                 return 806
        }
    }

    /// Constant 3480-byte header template (from set1/USER2.tbl with the two
    /// variable fields zeroed). See Docs/Euronav5/TBL_FORMAT.md.
    static let headerTemplate: Data = {
        let b64 =
        "AxgIEAABAAAAAAAAYGYDAFVTRVJPQkpFQ1RJRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAElEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAERBVEVEQVlTAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAACAERBVEVNT05USFMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAERBVEVZRUFSUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRJTUVTRUNPTkRTAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRJTUVNSU5V" +
        "VEVTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAACAFRJTUVIT1VSUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAFRZUEUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAAHAE5BTUUAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAAH" +
        "AERFU0NSSVBUSU9OAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAgAAHAExBQkVMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAEFQUEVSQU5DRQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAExBVElUVURFAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAFAExPTkdJVFVERQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAEVMRVZBVElPTgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFJBTkdFTEVUSEFMAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFJB" +
        "TkdFREVURUNUSU9OAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAADAEFUVEFDSE1FTlQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwAHAFNQRUVEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAENPVVJTRQAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAADAFdBUk5JTkdTRU5TSVRJVkUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAENMQVNTAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAFNPVVJDRQAAAAAAAAAAAAAAAAAAAAAAADAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAE9JAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAABJRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJAAAATE4AAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAcQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let data = Data(base64Encoded: b64)!
        precondition(data.count == headerSize)
        return data
    }()

    // MARK: - USEROBJECTID assignment

    /// Session rule (verified on all 10 sets + production): one counter
    /// k = 1, 2, 3, ... per created figure across ALL layers, in creation
    /// order. Open line -> +k, closed polygon -> -k, single-record object
    /// -> 0 (slot still consumed).
    static func assignObjectIds(_ figures: [Figure]) -> [Int32] {
        var ids: [Int32] = []
        for (i, f) in figures.enumerated() {
            let k = Int32(i + 1)
            switch f.kind {
            case .line:           ids.append(k)
            case .polygon:        ids.append(-k)
            case .circle, .point: ids.append(0)
            }
        }
        return ids
    }

    // MARK: - Records

    struct Record {
        var id: Int32
        var objectId: Int32
        var ts: Timestamp
        var type: String
        var name: String
        var appearance: Int32
        var latitude: Int32
        var longitude: Int32
        var elevation: Int32
        var rangeDetection: Int32
        var warningSensitive: UInt8
    }

    /// Flatten one layer's figures (with pre-assigned object ids, in
    /// creation order) into row records. Row IDs run 1..N per file.
    static func records(figures: [Figure], objectIds: [Int32],
                        ts: Timestamp) -> [Record] {
        precondition(figures.count == objectIds.count)
        var out: [Record] = []
        for (f, oid) in zip(figures, objectIds) {
            let elev = f.elevationMeters ?? elevationNotSet
            let warn: UInt8 = (f.warningSensitive ?? (f.elevationMeters != nil)) ? 1 : 0
            var pts = f.points
            if f.kind == .polygon, let first = pts.first {
                pts.append(first)  // close the ring
            }
            for (lat, lon) in pts {
                out.append(Record(
                    id: Int32(out.count + 1), objectId: oid, ts: ts,
                    type: f.type, name: f.name,
                    appearance: appearance(forType: f.type, kind: f.kind),
                    latitude: lat, longitude: lon, elevation: elev,
                    rangeDetection: f.kind == .circle ? f.radiusMeters : 0,
                    warningSensitive: warn))
            }
        }
        return out
    }

    // MARK: - Little-endian helpers

    private static func put(_ v: Int32, _ buf: inout [UInt8], _ at: Int) {
        withUnsafeBytes(of: v.littleEndian) { buf.replaceSubrange(at..<at + 4, with: $0) }
    }
    private static func put(_ v: UInt32, _ buf: inout [UInt8], _ at: Int) {
        withUnsafeBytes(of: v.littleEndian) { buf.replaceSubrange(at..<at + 4, with: $0) }
    }
    private static func put(_ v: UInt16, _ buf: inout [UInt8], _ at: Int) {
        withUnsafeBytes(of: v.littleEndian) { buf.replaceSubrange(at..<at + 2, with: $0) }
    }
    private static func put(_ s: String, _ buf: inout [UInt8], _ at: Int, max: Int) {
        let bytes = Array(s.unicodeScalars.filter { $0.value < 256 }
            .map { UInt8($0.value) }.prefix(max))
        buf.replaceSubrange(at..<at + bytes.count, with: bytes)
    }

    /// 256-byte record per Docs/Euronav5/TBL_FORMAT.md.
    static func encode(_ r: Record) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: recordSize)
        put(r.id, &b, 0x00)
        put(r.objectId, &b, 0x04)
        put(r.ts.day, &b, 0x08); put(r.ts.month, &b, 0x0a); put(r.ts.year, &b, 0x0c)
        put(r.ts.second, &b, 0x0e); put(r.ts.minute, &b, 0x10); put(r.ts.hour, &b, 0x12)
        put(r.type, &b, 0x14, max: 20)
        put(r.name, &b, 0x29, max: 20)
        // DESCRIPTION (0x3e, 129 B) empty
        put(Int32(1), &b, 0xbf)              // LABEL
        put(r.appearance, &b, 0xc3)
        put(r.latitude, &b, 0xc7)
        put(r.longitude, &b, 0xcb)
        put(r.elevation, &b, 0xcf)
        // RANGELETHAL (0xd3) = 0
        put(r.rangeDetection, &b, 0xd7)
        // ATTACHMENT (0xdb, 16 B) empty; SPEED (0xeb, f64) = 0; COURSE (0xf3) = 0
        b[0xf7] = r.warningSensitive
        // CLASS (0xf8) = 0; SOURCE (0xfc) = 0
        return b
    }

    // MARK: - .tbl

    static func buildTbl(records: [Record]) -> Data {
        var hdr = [UInt8](headerTemplate)
        let pageCount = max(1, (records.count + recordsPerPage - 1) / recordsPerPage)
        put(UInt32(pageCount), &hdr, 0x08)
        put(UInt32(records.count + 1), &hdr, 0x68)   // next row id
        var out = Data(hdr)
        for p in 0..<pageCount {
            let chunk = records[p * recordsPerPage..<min((p + 1) * recordsPerPage, records.count)]
            var page = [UInt8](repeating: 0, count: pageSize)
            put(UInt32(recordSize), &page, 0)
            put(UInt32(chunk.count), &page, 4)
            for (i, r) in chunk.enumerated() {
                page.replaceSubrange(8 + i * recordSize..<8 + (i + 1) * recordSize,
                                     with: encode(r))
            }
            out.append(contentsOf: page)
        }
        return out
    }

    // MARK: - .idx (B-tree, order 63, bottom-up splits)

    enum IndexKind { case id, ln, oi }

    private static let maxKeys = 63
    private static let splitAt = 31  // left keeps 31, median up, right gets 32

    private final class Node {
        let idx: Int
        let isLeaf: Bool
        var pairs: [(key: Int32, value: Int32)] = []
        var kids: [Int] = []
        var parent: Int?
        init(idx: Int, isLeaf: Bool) { self.idx = idx; self.isLeaf = isLeaf }
    }

    private final class Tree {
        var nodes: [Node] = [Node(idx: 0, isLeaf: true)]
        var root = 0
        /// planner quirk: after an internal split, child slot 63 keeps the
        /// pre-split pointer instead of being cleared
        var stale63: [Int: Int] = [:]

        func alloc(isLeaf: Bool) -> Node {
            let n = Node(idx: nodes.count, isLeaf: isLeaf)
            nodes.append(n)
            return n
        }

        func insert(_ key: Int32, _ value: Int32) {
            var n = nodes[root]
            while !n.isLeaf {
                var i = 0
                while i < n.pairs.count && key >= n.pairs[i].key { i += 1 }
                let c = nodes[n.kids[i]]
                c.parent = n.idx
                n = c
            }
            var i = 0
            while i < n.pairs.count && key >= n.pairs[i].key { i += 1 }
            n.pairs.insert((key, value), at: i)
            while n.pairs.count > Euronav5Encoder.maxKeys {
                n = split(n)
            }
        }

        private func split(_ n: Node) -> Node {
            let med = n.pairs[Euronav5Encoder.splitAt]
            let r = alloc(isLeaf: n.isLeaf)
            r.pairs = Array(n.pairs[(Euronav5Encoder.splitAt + 1)...])
            if !n.isLeaf {
                r.kids = Array(n.kids[(Euronav5Encoder.splitAt + 1)...])
                stale63[n.idx] = n.kids[63]
                n.kids.removeSubrange((Euronav5Encoder.splitAt + 1)...)
            }
            n.pairs.removeSubrange(Euronav5Encoder.splitAt...)
            if n.parent == nil && n.idx == root {
                let nr = alloc(isLeaf: false)
                nr.pairs = [med]
                nr.kids = [n.idx, r.idx]
                root = nr.idx
                return nr
            }
            let p = nodes[n.parent!]
            let j = p.kids.firstIndex(of: n.idx)!
            p.pairs.insert(med, at: j)
            p.kids.insert(r.idx, at: j + 1)
            r.parent = p.idx
            return p
        }
    }

    static func buildIdx(records: [Record], kind: IndexKind) -> Data {
        precondition(!records.isEmpty)
        let key: (Record) -> Int32 = {
            switch kind {
            case .id: return $0.objectId
            case .ln: return $0.longitude
            case .oi: return $0.id
            }
        }
        let tree = Tree()
        for r in records {
            tree.insert(key(r), r.id)
        }
        let sorted = records.map { (k: key($0), v: $0.id) }
            .sorted { ($0.k, $0.v) < ($1.k, $1.v) }
        let maxKey = sorted.last!.k, minKey = sorted.first!.k
        let maxRow = sorted.last(where: { $0.k == maxKey })!.v
        let minRow = sorted.first(where: { $0.k == minKey })!.v

        var h = [UInt8](repeating: 0, count: 60)
        put(UInt16(3), &h, 0x00); put(UInt16(3), &h, 0x02)
        put(Int32(60 + 768 * tree.root), &h, 0x04)
        put(Int32(0), &h, 0x08)
        put(Int32(-1), &h, 0x0c); put(Int32(-1), &h, 0x10)
        put(maxKey, &h, 0x14)
        put(UInt32(0x80000000), &h, 0x18); put(UInt32(0x80000000), &h, 0x1c)
        put(maxRow, &h, 0x20); put(maxRow, &h, 0x24)
        put(minKey, &h, 0x28)
        put(UInt32(0x80000000), &h, 0x2c); put(UInt32(0x80000000), &h, 0x30)
        put(minRow, &h, 0x34); put(minRow, &h, 0x38)
        var out = Data(h)

        for n in tree.nodes {
            var b = [UInt8](repeating: 0, count: 768)
            put(Int32(n.pairs.count), &b, 0)
            var slots = [Int32](repeating: -1, count: 64)
            for (q, c) in n.kids.enumerated() {
                slots[q] = Int32(60 + 768 * c)
            }
            if !n.isLeaf, let stale = tree.stale63[n.idx], n.kids.count <= 63 {
                slots[63] = Int32(60 + 768 * stale)
            }
            for (q, s) in slots.enumerated() {
                put(s, &b, 8 + q * 4)
            }
            for (q, p) in n.pairs.enumerated() {
                put(p.key, &b, 264 + q * 8)
                put(p.value, &b, 268 + q * 8)
            }
            out.append(contentsOf: b)
        }
        return out
    }

    // MARK: - Layer export

    struct LayerFiles {
        var tbl: Data
        var idIdx: Data
        var lnIdx: Data
        var oiIdx: Data
    }

    /// Export one layer file. `objectIds` come from `assignObjectIds` over
    /// the whole session (all layers, creation order).
    static func exportLayer(figures: [Figure], objectIds: [Int32],
                            ts: Timestamp) -> LayerFiles? {
        let recs = records(figures: figures, objectIds: objectIds, ts: ts)
        guard !recs.isEmpty else { return nil }
        return LayerFiles(tbl: buildTbl(records: recs),
                          idIdx: buildIdx(records: recs, kind: .id),
                          lnIdx: buildIdx(records: recs, kind: .ln),
                          oiIdx: buildIdx(records: recs, kind: .oi))
    }

    static func microdegrees(_ degrees: Double) -> Int32 {
        Int32((degrees * 1_000_000).rounded())
    }
}
