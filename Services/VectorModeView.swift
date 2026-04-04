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
            VStack(spacing: 0) {
                modeToggleHeader
                VectorLayerPanel()
                    .environmentObject(vectorStore)
            }
            .frame(width: 280)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VectorToolbar()
                .environmentObject(vectorStore)
                .environmentObject(toastManager)
        }
    }

    // MARK: iPhone layout

    @State private var showLayerPanel = false

    private var phoneLayout: some View {
        ZStack(alignment: .bottomTrailing) {
            mapArea
                .safeAreaInset(edge: .top, spacing: 0) {
                    modeToggleHeader
                }
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

    // MARK: Mode toggle header (shown at top of panel in vector mode)

    private var modeToggleHeader: some View {
        HStack {
            Spacer()
            HStack(spacing: 2) {
                modeBtn(mode: .navigation, icon: "map.fill")
                modeBtn(mode: .vector,     icon: "scribble")
            }
            .padding(3)
            .background(RutTheme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RutTheme.border, lineWidth: 1))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RutTheme.surface)
        Rectangle().fill(RutTheme.border).frame(height: 1)
    }

    @ViewBuilder
    private func modeBtn(mode: AppMode, icon: String) -> some View {
        let isActive = core.appMode == mode
        Button { core.appMode = mode } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: isActive ? .bold : .regular))
                .foregroundColor(isActive ? .black : RutTheme.textDim)
                .frame(width: 28, height: 24)
                .background(isActive ? RutTheme.amber : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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
