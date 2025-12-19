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

// MARK: - Toast manager

final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var message: String = ""
    @Published var isVisible: Bool = false
    @Published var level: Toast.Level = .info
    
    private var dismissWorkItem: DispatchWorkItem?

    init() {}

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
