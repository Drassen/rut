import SwiftUI
import UniformTypeIdentifiers

// MARK: - VectorLayerPanel

struct VectorLayerPanel: View {
    @EnvironmentObject var vectorStore: VectorStore
    @State private var showAddLayerAlert = false
    @State private var newLayerName = ""

    // Drag-to-reorder state
    @State private var draggingLayerId: UUID? = nil
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
                            VStack(spacing: 0) {
                                // Drop zone indicator above this row
                                if dragOverLayerId == layer.id {
                                    Rectangle()
                                        .fill(RutTheme.amber)
                                        .frame(height: 2)
                                }

                                VectorLayerRowView(layer: layer, depth: 0)
                                    .environmentObject(vectorStore)
                                    .opacity(draggingLayerId == layer.id ? 0.4 : 1.0)
                                    .onDrag {
                                        draggingLayerId = layer.id
                                        return NSItemProvider(object: layer.id.uuidString as NSString)
                                    }
                                    .onDrop(of: [.plainText], isTargeted: { targeted in
                                        dragOverLayerId = targeted ? layer.id : nil
                                    }) { providers in
                                        handleDrop(providers: providers, targetIndex: index)
                                        return true
                                    }
                            }
                            Rectangle().fill(RutTheme.border).frame(height: 0.5)
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

    private func handleDrop(providers: [NSItemProvider], targetIndex: Int) {
        providers.first?.loadObject(ofClass: NSString.self) { item, _ in
            guard let idString = item as? String,
                  let sourceId = UUID(uuidString: idString),
                  let sourceIndex = vectorStore.layers.firstIndex(where: { $0.id == sourceId }) else {
                DispatchQueue.main.async { self.draggingLayerId = nil; self.dragOverLayerId = nil }
                return
            }
            DispatchQueue.main.async {
                let dest = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
                vectorStore.moveTopLevelLayer(from: sourceIndex, to: dest)
                self.draggingLayerId = nil
                self.dragOverLayerId = nil
            }
        }
    }
}
