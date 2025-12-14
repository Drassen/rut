import Foundation

struct ExportedFile: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
}
