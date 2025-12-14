import UniformTypeIdentifiers

extension UTType {
    // Your own format (.rut)
    static let rutRUT = UTType(exportedAs: "com.serveraren.rut.rut", conformingTo: .data)

    // Imported/common route formats
    static let rutFPL = UTType(importedAs: "com.serveraren.rut.fpl", conformingTo: .xml)
    static let rutGPX = UTType(importedAs: "com.serveraren.rut.gpx", conformingTo: .xml)
    static let rutRTE = UTType(importedAs: "com.serveraren.rut.rte", conformingTo: .text)

    // A109 binary parts
    static let rutA109P01 = UTType(importedAs: "com.serveraren.rut.a109.p01", conformingTo: .data)
    static let rutA109HD  = UTType(importedAs: "com.serveraren.rut.a109.hd", conformingTo: .data)
}
