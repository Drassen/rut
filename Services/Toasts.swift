//
//  Toasts.swift
//  Rut
//
//  Created by Andreas Pantesjö on 2025-12-19.
//
import Foundation
import Combine
import SwiftUI

// MARK: - Toast types

struct Toast {
    enum Level { case info, error }
    let level: Level
    let message: String

    static func info(_ message: String) -> Toast { Toast(level: .info, message: message) }
    static func error(_ message: String) -> Toast { Toast(level: .error, message: message) }
}

/// Completion state shown in the export modal after the spinner phase.
struct ExportCompletion: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Toast manager

final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var message: String = ""
    @Published var isVisible: Bool = false
    @Published var level: Toast.Level = .info

    /// Non-empty when an import produced warnings that didn't parse.
    /// Cleared when the user dismisses the warning sheet.
    @Published var importWarnings: [String] = []
    @Published var importWarningTitle: String = ""

    /// Drives the blocking export/save progress modal.
    @Published var isExporting: Bool = false
    @Published var exportMessage: String = "Exporting…"
    /// Set when an export finished and should show a completion message + button
    /// in the same modal that showed the spinner.
    @Published var exportCompletion: ExportCompletion? = nil

    private var dismissWorkItem: DispatchWorkItem?

    init() {}

    // MARK: - Export progress

    /// Runs an export/save off the main thread while showing a blocking
    /// progress modal, then delivers the result back on the main thread.
    ///
    /// `work` must only touch value types / thread-safe services — capture any
    /// model data into local copies before calling.
    func runExport<T>(_ message: String = "Exporting…",
                      work: @escaping () throws -> T,
                      onSuccess: @escaping (T) -> Void,
                      onFailure: @escaping (Error) -> Void) {
        exportMessage = message
        isExporting = true
        // Keep the spinner up for a minimum time. Exports can finish faster
        // than a covering sheet (e.g. the folder picker) dismisses; without
        // this the spinner is occluded the whole time and only the result
        // shows. The floor guarantees it's visible once the sheet is gone.
        let minVisible: TimeInterval = 0.8
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            let elapsed = Date().timeIntervalSince(start)
            let remaining = max(0, minVisible - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                self.isExporting = false
                switch result {
                case .success(let value): onSuccess(value)
                case .failure(let error): onFailure(error)
                }
            }
        }
    }

    func show(_ toast: Toast) {
        dismissWorkItem?.cancel()
        
        DispatchQueue.main.async {
            self.message = toast.message
            self.level = toast.level
            self.isVisible = true
        }
        
        ErrorLogger.shared.log("TOAST: \(toast.message)")
        
        let workItem = DispatchWorkItem { [weak self] in
            withAnimation {
                self?.isVisible = false
            }
        }
        
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    func show(_ message: String) { show(.info(message)) }

    func show(message: String, kind: Toast.Level = .info) {
        show(Toast(level: kind, message: message))
    }

    func showError(_ error: Error) {
        show(.error(error.localizedDescription))
    }
}
