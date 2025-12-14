//
//  errors.swift
//  Rut
//

import Foundation
import os

// MARK: - Error logger

/// Simple singleton logger:
/// - Writes to Xcode console via os.Logger
/// - Also appends to Documents/Logs/Rut.log
final class ErrorLogger {
    static let shared = ErrorLogger()

    private let logger: Logger
    private let fm = FileManager.default

    private init() {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.serveraren.rut"
        self.logger = Logger(subsystem: subsystem, category: "Rut")
    }

    // MARK: Console + file

    func logInfo(_ message: String) {
        log(level: "INFO", osLevel: .info, message: message)
    }

    func logError(_ message: String) {
        log(level: "ERROR", osLevel: .error, message: message)
    }

    func logError(_ error: Error) {
        logError(error.localizedDescription)
        log(level: "ERROR", osLevel: .error, message: "Error type: \(String(reflecting: type(of: error)))")
    }

    // Backwards-compat
    func log(_ message: String) { logInfo(message) }
    func log(_ error: Error) { logError(error) }

    private func log(level: String, osLevel: OSLogType, message: String) {
        let line = "[\(level)] [\(Date())] \(message)"

        // 1) Xcode console (ONE output path -> no duplicates)
        logger.log(level: osLevel, "\(line, privacy: .public)")

        // 2) File append
        appendToFile(line + "\n")
    }

    private func appendToFile(_ text: String) {
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logsDir = docs.appendingPathComponent("Logs", isDirectory: true)
        let logFile = logsDir.appendingPathComponent("Rut.log")

        if !fm.fileExists(atPath: logsDir.path) {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }

        guard let data = text.data(using: .utf8) else { return }

        if fm.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

// MARK: - RutError

enum RutError: LocalizedError {
    case zipNotSupported
    case importFailed(String)
    case invalidFormat(String)
    case invalidEncoding
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .zipNotSupported:
            return "ZIP files are not supported."
        case .importFailed(let msg):
            return "Import failed: \(msg)"
        case .invalidFormat(let msg):
            return "Invalid format: \(msg)"
        case .invalidEncoding:
            return "File encoding is invalid or unsupported."
        case .ioError(let msg):
            return "File I/O error: \(msg)"
        }
    }
}
