import Foundation
import Compression

/// Assembles the complete EuroNav5 "UpdateMedia" card payload — the same set
/// of files a planning station writes to the PCMCIA/PAS card:
///
///   ENMedia.ini                            (generic UpdateMedia descriptor)
///   db/SQL/USER4.tbl, USER4-{ID,LN,OI}.idx (the exported user layer)
///   db/SQL/scripts/User4.create.sql        (generic table schema)
///   db/{log,macros,pictures,settings,...}  (empty support folders)
///   FileTran.tgz                           (GNU-tar+gzip snapshot of db/)
///
/// The tarball format (GNU header magic, root:0 ownership, 0775/0664 modes,
/// gzip with no embedded filename) is byte-format-identical to the reference
/// FileTran.tgz — verified against the real card and the reference encoding.
enum Euronav5CardWriter {

    /// Card-relative file path -> bytes, plus empty directories to create.
    struct Card {
        var files: [String: Data]
        var directories: [String]
        var isEmpty: Bool { files.isEmpty }
    }

    /// Empty support folders present on every card (relative to the card root).
    static let supportDirectories = [
        "db", "db/SQL", "db/SQL/scripts", "db/log", "db/macros",
        "db/pictures", "db/settings", "db/settings/current", "db/settings/system",
    ]

    /// Generic UpdateMedia descriptor written at the card root (152 bytes, LF).
    static let enMediaIni = """
    [Description]
    EAM_Capabilities=Standard
    EAM_Name=EuroNav5
    EAM_FileSystem=
    EAM_Serial=
    EAM_Type=UpdateMedia
    EAM_VersionMax=1.39.45
    EAM_VersionMin=1.39.40
    """

    /// Generic User4 table schema (db/SQL/scripts/User4.create.sql, ends ");\n").
    static let user4CreateSQL = """
    CREATE TABLE User4(
      userObjectId INTEGER AUTO_INCREMENT,
      id INTEGER,
      DateDays SMALLINT,
      DateMonths SMALLINT,
      DateYears SMALLINT,
      TimeSeconds SMALLINT,
      TimeMinutes SMALLINT,
      TimeHours SMALLINT,
      Type CHAR(20),
      Name CHAR(20),
      Description CHAR(128),
      Label INTEGER,
      Apperance INTEGER,
      Latitude FLOAT(9),
      Longitude FLOAT(9),
      Elevation INTEGER,
      RangeLethal INTEGER,
      RangeDetection INTEGER,
      Attachment CHAR(15),
      Speed FLOAT,
      Course INTEGER,
      WarningSensitive BOOL,
      Class INTEGER default 0,
      Source INTEGER default 0,
    # shorter index name for Targa DTU
      KEY oi (userObjectId),
      KEY id (id),
      KEY ln (Longitude)
    );
    """ + "\n"

    /// Build the full card from the encoder's USER layer files (keyed by
    /// card-relative path, e.g. "db/SQL/USER4.tbl"). Returns an empty card if
    /// there is nothing to export.
    static func buildCard(userFiles: [String: Data], date: Date = Date()) -> Card {
        guard !userFiles.isEmpty else { return Card(files: [:], directories: []) }

        var files = userFiles
        files["ENMedia.ini"] = Data(enMediaIni.utf8)
        files["db/SQL/scripts/User4.create.sql"] = Data(user4CreateSQL.utf8)

        // FileTran.tgz is a snapshot of everything under db/ (not the root files).
        let mtime = UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970))
        let dbFiles = files
            .filter { $0.key.hasPrefix("db/") }
            .map { (name: $0.key, data: $0.value) }
            .sorted { $0.name < $1.name }
        files["FileTran.tgz"] = Euronav5Tar.makeTarGz(
            dirs: supportDirectories, files: dbFiles, mtime: mtime)

        return Card(files: files, directories: supportDirectories)
    }
}

/// Minimal GNU-format tar writer + gzip container, sufficient to reproduce the
/// EuroNav5 FileTran.tgz format. No external dependencies (uses Compression).
enum Euronav5Tar {

    // CRC-32 (IEEE) for the gzip trailer.
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // Raw DEFLATE (RFC 1951) via the Compression framework.
    private static func rawDeflate(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data() }
        var cap = input.count + input.count / 2 + 1024
        for _ in 0..<4 {
            var dst = Data(count: cap)
            let n = dst.withUnsafeMutableBytes { d -> Int in
                input.withUnsafeBytes { s in
                    compression_encode_buffer(
                        d.bindMemory(to: UInt8.self).baseAddress!, cap,
                        s.bindMemory(to: UInt8.self).baseAddress!, input.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 { dst.removeSubrange(n..<dst.count); return dst }
            cap *= 2
        }
        return Data()
    }

    /// gzip container: header (no filename, OS=Unix) + raw DEFLATE + CRC32 + ISIZE.
    private static func gzip(_ input: Data, mtime: UInt32) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00])
        var t = mtime.littleEndian
        withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
        out.append(0x00)              // XFL
        out.append(0x03)              // OS = Unix
        out.append(rawDeflate(input))
        var crc = crc32(input).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: input.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    // One 512-byte GNU/ustar header block (root:0, dirs 0775, files 0664).
    private static func header(name: String, size: Int, mtime: UInt32, isDir: Bool) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at off: Int) { for (i, b) in bytes.enumerated() { h[off + i] = b } }
        // octal field: (width-1) zero-padded digits + NUL
        func octal(_ value: UInt64, width: Int) -> [UInt8] {
            let digits = width - 1
            var s = String(value, radix: 8)
            if s.count < digits { s = String(repeating: "0", count: digits - s.count) + s }
            return Array(s.utf8) + [0]
        }
        put(Array(name.utf8), at: 0)                              // name (100)
        put(octal(isDir ? 0o775 : 0o664, width: 8), at: 100)      // mode
        put(octal(0, width: 8), at: 108)                          // uid
        put(octal(0, width: 8), at: 116)                          // gid
        put(octal(UInt64(size), width: 12), at: 124)              // size
        put(octal(UInt64(mtime), width: 12), at: 136)             // mtime
        for i in 148..<156 { h[i] = 0x20 }                        // chksum placeholder
        h[156] = isDir ? UInt8(ascii: "5") : UInt8(ascii: "0")    // typeflag
        put([0x75, 0x73, 0x74, 0x61, 0x72, 0x20], at: 257)        // magic "ustar "
        put([0x20, 0x00], at: 263)                                // version " \0"
        put(Array("root".utf8), at: 265)                          // uname
        put(Array("0".utf8), at: 297)                             // gname
        var sum = 0
        for b in h { sum += Int(b) }
        // chksum: 6 octal digits + NUL + space
        put(octal(UInt64(sum), width: 7) + [0x20], at: 148)
        return h
    }

    /// Build a GNU-format gzip tarball from directory + file entries.
    /// `dirs` and the `name` of each file are archive-relative paths.
    static func makeTarGz(dirs: [String], files: [(name: String, data: Data)],
                          mtime: UInt32) -> Data {
        var tar = Data()
        for dir in dirs {
            let name = dir.hasSuffix("/") ? dir : dir + "/"
            tar.append(contentsOf: header(name: name, size: 0, mtime: mtime, isDir: true))
        }
        for file in files {
            tar.append(contentsOf: header(name: file.name, size: file.data.count,
                                          mtime: mtime, isDir: false))
            tar.append(file.data)
            let pad = (512 - file.data.count % 512) % 512
            if pad > 0 { tar.append(Data(count: pad)) }
        }
        tar.append(Data(count: 1024))   // two zero blocks = end of archive
        return gzip(tar, mtime: mtime)
    }
}
