import SwiftUI

// MARK: - VectorLayerPanel

struct VectorLayerPanel: View {
    @EnvironmentObject var vectorStore: VectorStore
    @State private var showAddLayerAlert = false
    @State private var newLayerName = ""

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Rectangle().fill(RutTheme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if vectorStore.layers.isEmpty {
                        Text("No layers")
                            .font(.system(size: 13))
                            .foregroundColor(RutTheme.textMuted)
                            .padding()
                    } else {
                        ForEach(vectorStore.layers) { layer in
                            VectorLayerRowView(layer: layer, depth: 0)
                                .environmentObject(vectorStore)
                            Rectangle().fill(RutTheme.border).frame(height: 0.5)
                        }
                    }
                    // Tap on empty space deselects
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { vectorStore.activeLayerId = nil }
                }
            }
        }
        .background(RutTheme.surface)
        .alert("New Layer", isPresented: $showAddLayerAlert) {
            TextField("Layer name", text: $newLayerName)
            Button("Add") {
                let name = newLayerName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    vectorStore.addLayer(name: name, parentId: vectorStore.activeLayerId)
                }
                newLayerName = ""
            }
            Button("Cancel", role: .cancel) { newLayerName = "" }
        }
    }

    private var panelHeader: some View {
        HStack {
            Text(vectorStore.activeLayerId != nil ? "Layers (sublayer)" : "Layers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(RutTheme.text)
            Spacer()
            Button {
                newLayerName = ""
                showAddLayerAlert = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(RutTheme.amber)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
