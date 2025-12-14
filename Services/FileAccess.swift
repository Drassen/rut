import Foundation

enum FileAccess {
    enum FileAccessError: LocalizedError {
        case failedToCreateSandboxCopy(String)
        
        var errorDescription: String? {
            switch self {
            case .failedToCreateSandboxCopy(let msg):
                return "Failed to create sandbox copy: \(msg)"
            }
        }
    }
    
    /// Create a temporary sandbox copy of a picked/shared file.
    /// Uses:
    /// - security-scoped access when needed
    /// - NSFileCoordinator for provider-backed URLs (Files / ForeFlight / iCloud providers)
    static func makeSandboxCopy(of originalURL: URL) throws -> URL {
        let fm = FileManager.default
        
        let dir = fm.temporaryDirectory.appendingPathComponent("RutImports", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let ext = originalURL.pathExtension.isEmpty ? "" : "." + originalURL.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("import-\(UUID().uuidString)\(ext)")
        
        let didStart = originalURL.startAccessingSecurityScopedResource()
        defer { if didStart { originalURL.stopAccessingSecurityScopedResource() } }
        
        var coordinatorError: NSError?
        var innerError: Error?
        
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: originalURL, options: [], error: &coordinatorError) { readableURL in
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                
                // Copy the coordinated readable URL into our sandbox
                try fm.copyItem(at: readableURL, to: dest)
            } catch {
                innerError = error
            }
        }
        
        if let coordinatorError {
            throw coordinatorError
        }
        if let innerError {
            throw innerError
        }
        if !fm.fileExists(atPath: dest.path) {
            throw FileAccessError.failedToCreateSandboxCopy("Destination does not exist after copy.")
        }
        
        return dest
    }
}
