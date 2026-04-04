import SwiftUI

// MARK: - VectorLayerPanel

struct VectorLayerPanel: View {
    @EnvironmentObject var vectorStore: VectorStore
    @State private var showAddLayerAlert = false
    @State private var newLayerName = ""

    @State private var dragOverLayerId: UUID? = nil

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
                        ForEach(Array(vectorStore.layers.enumerated()), id: \.element.id) { index, layer in
                            layerEntry(layer: layer, index: index)
                        }
                    }
                    // Tap on empty space deselects
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vectorStore.activeLayerId = nil
                            vectorStore.deselectShape()
                        }
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

    @ViewBuilder
    private func layerEntry(layer: VectorLayer, index: Int) -> some View {
        VStack(spacing: 0) {
            if dragOverLayerId == layer.id {
                Rectangle().fill(RutTheme.amber).frame(height: 2)
            }
            VectorLayerRowView(layer: layer, depth: 0)
                .environmentObject(vectorStore)
                .draggable(layer.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let idString = items.first,
                          let sourceId = UUID(uuidString: idString),
                          let sourceIndex = vectorStore.layers.firstIndex(where: { $0.id == sourceId })
                    else { return false }
                    let dest = index > sourceIndex ? index - 1 : index
                    vectorStore.moveTopLevelLayer(from: sourceIndex, to: dest)
                    dragOverLayerId = nil
                    return true
                } isTargeted: { targeted in
                    dragOverLayerId = targeted ? layer.id : nil
                }
        }
        Rectangle().fill(RutTheme.border).frame(height: 0.5)
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
