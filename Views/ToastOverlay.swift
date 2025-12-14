//
//  ToastOverlay.swift
//  Rut
//

import SwiftUI

/// Overlay that shows toast messages from ToastManager at the bottom of the screen.
struct ToastOverlay: View {
    @EnvironmentObject var core: CoreServices
    
    var body: some View {
        ZStack {
            if core.toastManager.isVisible {
                VStack {
                    Spacer()
                    Text(core.toastManager.message)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.85))
                        )
                        .foregroundColor(.white)
                        .padding(.bottom, 24)
                        .onTapGesture {
                            withAnimation {
                                core.toastManager.isVisible = false
                            }
                        }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: core.toastManager.isVisible)
    }
}
