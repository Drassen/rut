import SwiftUI
import MapKit

// MARK: - VectorModeView

struct VectorModeView: View {
    @EnvironmentObject var navStore: NavigationStore
    @EnvironmentObject var vectorStore: VectorStore
    @EnvironmentObject var toastManager: ToastManager
    @EnvironmentObject var core: CoreServices

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            // iPhone: layer panel as bottom sheet
            phoneLayout
        } else {
            // iPad landscape: side panel
            ipadLayout
        }
    }

    // MARK: iPad layout

    private var ipadLayout: some View {
        HStack(spacing: 0) {
            mapArea
            Rectangle().fill(RutTheme.border).frame(width: 1)
            VectorLayerPanel()
                .environmentObject(vectorStore)
                .frame(width: 280)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VectorToolbar()
                .environmentObject(vectorStore)
                .environmentObject(toastManager)
                .environmentObject(core)
        }
    }

    // MARK: iPhone layout

    @State private var showLayerPanel = false

    private var phoneLayout: some View {
        ZStack(alignment: .bottomTrailing) {
            mapArea
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VectorToolbar()
                        .environmentObject(vectorStore)
                        .environmentObject(toastManager)
                }

            Button {
                showLayerPanel = true
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(RutTheme.text)
                    .frame(width: 44, height: 44)
                    .background(RutTheme.surface)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(RutTheme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .padding([.trailing, .bottom], 80)
        }
        .sheet(isPresented: $showLayerPanel) {
            NavigationStack {
                VectorLayerPanel()
                    .environmentObject(vectorStore)
                    .navigationTitle("Layers")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showLayerPanel = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .tint(RutTheme.amber)
        }
    }

    // MARK: Map area (shared)

    private var mapArea: some View {
        RutMapView(
            onPointTap: nil,    // navigation data is non-interactive in vector mode
            onMapLongPress: nil
        )
        .environmentObject(navStore)
        .environmentObject(vectorStore)
        .environmentObject(core)
    }
}
