//
//  ExportProgressOverlay.swift
//  Rut
//

import SwiftUI

/// Blocking modal for export/save. Shows a spinner while `isExporting`, then
/// morphs—in the same card—into a completion message + button when
/// `exportCompletion` is set. Driven by `ToastManager`.
struct ExportProgressOverlay: View {
    // Observe ToastManager directly: it's a nested ObservableObject, so a view
    // watching only `core` would not re-render when these @Published change.
    @EnvironmentObject var toastManager: ToastManager

    private var isVisible: Bool {
        toastManager.isExporting || toastManager.exportCompletion != nil
    }

    var body: some View {
        ZStack {
            if isVisible {
                // Dimmed, tap-blocking backdrop.
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { } // swallow taps so the UI is blocked

                card
                    .padding(.horizontal, 28)
                    .padding(.vertical, 26)
                    .frame(maxWidth: 320)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(RutTheme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(RutTheme.border, lineWidth: 1))
                    )
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .animation(.easeInOut(duration: 0.2), value: toastManager.isExporting)
    }

    @ViewBuilder
    private var card: some View {
        if let completion = toastManager.exportCompletion {
            VStack(spacing: 14) {
                Text(completion.title)
                    .font(.headline)
                    .foregroundColor(RutTheme.text)
                    .multilineTextAlignment(.center)
                Text(completion.message)
                    .font(.subheadline)
                    .foregroundColor(RutTheme.textDim)
                    .multilineTextAlignment(.center)
                Button("OK") {
                    toastManager.exportCompletion = nil
                }
                .buttonStyle(RutPrimaryButtonStyle())
                .padding(.top, 4)
            }
        } else {
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(RutTheme.amber)
                Text(toastManager.exportMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(RutTheme.text)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
