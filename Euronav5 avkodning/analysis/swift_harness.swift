// Verification harness for Euronav5Encoder.swift.
// Reads fixtures.json (figure-level inputs extracted from the reference
// sets), regenerates every .tbl/.idx with the Swift encoder and
// byte-compares against the reference files.
//
// Run via: python3 verify_swift.py   (compiles with swiftc and executes)

import Foundation

let fixturesURL = URL(fileURLWithPath: "fixtures.json")
let root = URL(fileURLWithPath: "..")

guard let raw = try? Data(contentsOf: fixturesURL),
      let sets = try? JSONSerialization.jsonObject(with: raw) as? [String: [String: Any]] else {
    print("FAIL cannot read fixtures.json")
    exit(1)
}

var failures = 0
var fileCount = 0

for setName in sets.keys.sorted(by: { (Int($0.dropFirst(3)) ?? 0) < (Int($1.dropFirst(3)) ?? 0) }) {
    let set = sets[setName]!
    let figDicts = set["figures"] as! [[String: Any]]
    let fileMeta = set["files"] as! [String: [String: Any]]

    var figures: [Euronav5Encoder.Figure] = []
    var figFile: [String] = []
    for d in figDicts {
        let kind: Euronav5Encoder.FigureKind
        switch d["kind"] as! String {
        case "line":    kind = .line
        case "polygon": kind = .polygon
        default:        kind = .circle
        }
        let pts = (d["points"] as! [[Any]]).map {
            (Int32(($0[0] as! NSNumber).intValue), Int32(($0[1] as! NSNumber).intValue))
        }
        var elevation: Int32?
        if let e = d["elevation"] as? NSNumber {
            elevation = Int32(e.intValue)
        }
        figures.append(Euronav5Encoder.Figure(
            kind: kind,
            name: d["name"] as! String,
            type: d["type"] as! String,
            points: pts,
            radiusMeters: Int32((d["radius"] as! NSNumber).intValue),
            elevationMeters: elevation))
        figFile.append(d["file"] as! String)
    }

    let oids = Euronav5Encoder.assignObjectIds(figures)

    for (fname, meta) in fileMeta {
        let t = (meta["ts"] as! [NSNumber]).map { UInt16($0.intValue) }
        let ts = Euronav5Encoder.Timestamp(year: t[0], month: t[1], day: t[2],
                                           hour: t[3], minute: t[4], second: t[5])
        // Figures of this file in row order. The fixture's session-order
        // array preserves per-file row order (rows are written in
        // creation order), so a filtered pass suffices.
        var fileFigs: [Euronav5Encoder.Figure] = []
        var fileOids: [Int32] = []
        for (i, d) in figDicts.enumerated() where d["file"] as! String == fname {
            fileFigs.append(figures[i])
            fileOids.append(oids[i])
        }
        guard let out = Euronav5Encoder.exportLayer(figures: fileFigs,
                                                    objectIds: fileOids, ts: ts) else {
            print("FAIL \(setName)/\(fname): empty export")
            failures += 1
            continue
        }
        let base = fname.replacingOccurrences(of: ".tbl", with: "")
        let produced: [(String, Data)] = [
            (fname, out.tbl),
            ("\(base)-ID.idx", out.idIdx),
            ("\(base)-LN.idx", out.lnIdx),
            ("\(base)-OI.idx", out.oiIdx),
        ]
        for (name, data) in produced {
            fileCount += 1
            let refURL = root.appendingPathComponent("\(setName)/db/SQL/\(name)")
            let ref = try! Data(contentsOf: refURL)
            if data == ref {
                print("PASS \(setName)/\(name)")
            } else {
                failures += 1
                let firstDiff = zip(data, ref).enumerated().first { $1.0 != $1.1 }?.offset
                print("FAIL \(setName)/\(name) len \(data.count) vs \(ref.count) firstDiff \(firstDiff.map(String.init) ?? "len")")
            }
        }
    }
}

print(failures == 0
      ? "SWIFT ENCODER: ALL \(fileCount) FILES BYTE-EXACT"
      : "SWIFT ENCODER: \(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
