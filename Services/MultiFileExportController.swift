import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// SwiftUI wrapper for UIDocumentPickerViewController(forExporting:)
/// Accepts pre-written file URLs to ensure availability before presentation.
struct MultiFileExportController: UIViewControllerRepresentable {
    var fileURLs: [URL]
    var onCompletion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Initiera direkt med URL:erna. Filerna antas redan finnas på disk.
        let picker = UIDocumentPickerViewController(forExporting: fileURLs, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: MultiFileExportController

        init(_ parent: MultiFileExportController) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onCompletion(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCompletion(false)
        }
    }
}
