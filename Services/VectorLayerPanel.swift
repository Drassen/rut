import SwiftUI

// MARK: - VectorLayerPanel

struct VectorLayerPanel: View {
    @EnvironmentObject var vectorStore: VectorStore
    @EnvironmentObject var toastManager: ToastManager

    // Drag state is local to the panel — keeps it out of VectorStore/@Published
    // so the map doesn't re-render on every finger move.
    @State private var draggingLayerId: UUID? = nil
    @State private var dragTargetIndex: Int? = nil
    @State private var draggingLayerParentId: UUID? = nil
    @State private var dragIntoTarget: Bool = false
    @State private var draggingShapeId: UUID? = nil
    @State private var draggingShapeLayerId: UUID? = nil
    @State private var dragShapeTargetIndex: Int? = nil

    @State private var showAddLayerAlert = false
    @State private var newLayerName = ""

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Rectangle().fill(RutTheme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let layerEntries = vectorStore.flatLayerEntries()
                    let panelEntries = vectorStore.flatPanelEntries()

                    if layerEntries.isEmpty {
                        Text("No layers")
                            .font(.system(size: 13))
                            .foregroundColor(RutTheme.textMuted)
                            .padding()
                    } else {
                        ForEach(Array(layerEntries.enumerated()), id: \.element.layer.id) { layerIdx, entry in
                            flatLayerEntry(entry: entry, layerFlatIndex: layerIdx,
                                           layerCount: layerEntries.count,
                                           panelEntries: panelEntries)
                        }
                    }
                    // Fill remaining scroll area so tap gesture below covers it
                    Color.clear.frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .onTapGesture {
                vectorStore.activeLayerId = nil
                vectorStore.deselectShape()
            }
        }
        .background(RutTheme.surface)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(RutTheme.border).frame(height: 1)
                VectorExportButton()
                    .environmentObject(vectorStore)
                    .environmentObject(toastManager)
            }
            .background(RutTheme.surface)
        }
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
    private func flatLayerEntry(entry: VectorStore.FlatLayerEntry,
                                 layerFlatIndex: Int,
                                 layerCount: Int,
                                 panelEntries: [VectorStore.FlatPanelEntry]) -> some View {
        let isLayerDropTarget = draggingLayerId != nil && dragTargetIndex == layerFlatIndex
        let dropInto          = isLayerDropTarget && dragIntoTarget

        // Shape drag indicator on layer header rows
        let layerPanelIdx     = panelEntries.firstIndex(where: { $0.id == entry.layer.id }) ?? -1
        let isShapeDropTarget = draggingShapeId != nil
                                && dragShapeTargetIndex == layerPanelIdx

        VStack(spacing: 0) {
            if isLayerDropTarget && !dropInto {
                Rectangle().fill(RutTheme.amber).frame(height: 2)
            }
            VectorLayerRowView(layer: entry.layer, depth: entry.depth)
                .environmentObject(vectorStore)
                .opacity(draggingLayerId == entry.layer.id ? 0.4 : 1.0)
                .overlay(dropInto ? RoundedRectangle(cornerRadius: 4)
                    .stroke(RutTheme.amber, lineWidth: 2) : nil)
                .simultaneousGesture(entry.layer.isSystem ? nil : reorderGesture(
                    layerId: entry.layer.id, flatIndex: layerFlatIndex, totalCount: layerCount))

            // Shape drop indicator below layer header (= first child position)
            if isShapeDropTarget {
                Rectangle().fill(RutTheme.amber).frame(height: 2)
            }

            if entry.layer.isExpanded {
                let layerId = entry.layer.id
                ForEach(Array(entry.layer.shapes.enumerated()), id: \.element.id) { idx, shape in
                    // Find this shape's index in the panel flat list
                    let panelIdx = panelEntries.firstIndex(where: { $0.id == shape.id }) ?? 0
                    VStack(spacing: 0) {
                        if draggingShapeId != nil,
                           draggingShapeId != shape.id,
                           dragShapeTargetIndex == panelIdx {
                            Rectangle().fill(RutTheme.amber).frame(height: 2)
                        }
                        VectorShapeRowView(shape: shape, layerId: layerId, depth: entry.depth)
                            .environmentObject(vectorStore)
                            .opacity(draggingShapeId == shape.id ? 0.4 : 1.0)
                            .simultaneousGesture(shapeReorderGesture(
                                shapeId: shape.id, layerId: layerId,
                                panelIndex: panelIdx, totalCount: panelEntries.count))
                    }
                }
            }
        }
        Rectangle().fill(RutTheme.border).frame(height: 0.5)
    }

    // MARK: - Layer reorder gesture (uses flat layer index)

    private func reorderGesture(layerId: UUID, flatIndex: Int, totalCount: Int) -> some Gesture {
        let rowHeight: CGFloat = 37
        return LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 4, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                guard vectorStore.activeLayerId == layerId,
                      vectorStore.activeShapeId == nil else { return }
                if draggingLayerId == nil {
                    draggingLayerId = layerId
                }
                let exactDelta = drag.translation.height / rowHeight
                let intDelta   = Int(exactDelta < 0 ? ceil(exactDelta) : floor(exactDelta))
                let frac       = exactDelta - Double(intDelta)
                let posInRow   = exactDelta < 0 ? 1.0 + frac : frac
                let targetIdx  = max(0, min(totalCount - 1, flatIndex + intDelta))

                let entries = vectorStore.flatLayerEntries()
                let targetEntry = entries[targetIdx]
                let canDropInto = !targetEntry.layer.isSystem && targetEntry.layer.id != layerId

                dragTargetIndex = targetIdx
                dragIntoTarget  = canDropInto && posInRow > 0.55
            }
            .onEnded { value in
                let into = dragIntoTarget
                let dest = dragTargetIndex ?? flatIndex
                defer {
                    draggingLayerId       = nil
                    draggingLayerParentId = nil
                    dragTargetIndex       = nil
                    dragIntoTarget        = false
                }
                guard case .second(true, _) = value else { return }
                vectorStore.moveLayerToFlatIndex(layerId, flatIndex: dest, asChild: into)
            }
    }

    // MARK: - Shape reorder gesture (uses flat panel index, cross-layer)

    private func shapeReorderGesture(shapeId: UUID, layerId: UUID,
                                      panelIndex: Int, totalCount: Int) -> some Gesture {
        let rowHeight: CGFloat = 33
        return LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 4, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                guard vectorStore.activeShapeId == shapeId else { return }
                if draggingShapeId == nil {
                    draggingShapeId = shapeId
                    draggingShapeLayerId = layerId
                }
                let delta = Int(round(drag.translation.height / rowHeight))
                let candidate = max(0, min(totalCount - 1, panelIndex + delta))
                // Don't allow targeting a locked/system layer
                let entries = vectorStore.flatPanelEntries()
                let targetIsLocked: Bool = {
                    switch entries[candidate] {
                    case .layer(let l, _, _): return l.isSystem
                    case .shape(_, let lid, _): return vectorStore.layerIsSystem(id: lid)
                    }
                }()
                if !targetIsLocked {
                    dragShapeTargetIndex = candidate
                }
            }
            .onEnded { value in
                let dest = dragShapeTargetIndex ?? panelIndex
                defer {
                    draggingShapeId      = nil
                    draggingShapeLayerId = nil
                    dragShapeTargetIndex = nil
                }
                guard case .second(true, _) = value else { return }
                if dest != panelIndex {
                    vectorStore.moveShapeToFlatPanel(shapeId: shapeId, fromLayerId: layerId,
                                                     toPanelIndex: dest)
                }
            }
    }

    private var panelHeader: some View {
        HStack {
            Text("Layers")
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
