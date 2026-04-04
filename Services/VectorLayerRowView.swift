import SwiftUI

// MARK: - VectorLayerRowView

/// Recursive row that renders a VectorLayer node at a given indentation depth.
struct VectorLayerRowView: View {
    @EnvironmentObject var vectorStore: VectorStore

    let layer: VectorLayer
    let depth: Int

    @State private var showRenameAlert = false
    @State private var renameText = ""

    private let indent: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            layerRow
            if layer.isExpanded {
                ForEach(layer.shapes) { shape in
                    shapeRow(shape)
                }
                ForEach(layer.children) { child in
                    VectorLayerRowView(layer: child, depth: depth + 1)
                        .environmentObject(vectorStore)
                }
            }
        }
        .alert("Rename Layer", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Save") { vectorStore.renameLayer(id: layer.id, name: renameText) }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Layer row

    private var layerRow: some View {
        let isFolderSelected  = vectorStore.activeLayerId == layer.id && vectorStore.activeShapeId == nil
        let hasSelectedChild  = !isFolderSelected && layerContainsActiveShape(layer)
        let showAmberBg       = isFolderSelected || hasSelectedChild
        let nameColor: Color  = isFolderSelected ? .white : RutTheme.textDim

        return HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * indent, height: 1)

            // Expand/collapse chevron
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vectorStore.toggleLayerExpanded(id: layer.id)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(RutTheme.textDim)
                    .rotationEffect(.degrees(layer.isExpanded ? 90 : 0))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)

            // Visibility eye (always available, even for system layers)
            Button { vectorStore.toggleLayerVisibility(id: layer.id) } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundColor(layer.isVisible ? RutTheme.textDim : RutTheme.textMuted)
            }
            .buttonStyle(.plain)

            // Folder / lock icon
            Image(systemName: layer.isSystem ? "lock.fill" : "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(layer.isSystem ? RutTheme.textMuted : RutTheme.textDim)

            // Name
            Text(layer.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(nameColor)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Delete — non-system layers only
            if !layer.isSystem {
                Button(role: .destructive) {
                    vectorStore.deleteLayer(id: layer.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(RutTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(showAmberBg ? RutTheme.amber.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            vectorStore.setActiveLayer(layer.id)
            vectorStore.deselectShape()
        }
        .onLongPressGesture {
            guard !layer.isSystem else { return }
            renameText = layer.name
            showRenameAlert = true
        }
    }

    // MARK: - Shape row

    @ViewBuilder
    private func shapeRow(_ shape: VectorShape) -> some View {
        let isSelected = vectorStore.activeShapeId == shape.id
        let nameColor: Color = isSelected ? .white : RutTheme.textDim

        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth + 1) * indent + 14, height: 1)

            // Visibility — eye always available (even in system layers)
            Button {
                var updated = shape
                updated.isVisible.toggle()
                vectorStore.updateShape(updated, in: layer.id)
            } label: {
                Image(systemName: shape.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundColor(shape.isVisible ? RutTheme.textDim : RutTheme.textMuted)
            }
            .buttonStyle(.plain)

            // Shape type icon
            Image(systemName: shapeIcon(shape.geometry))
                .font(.system(size: 11))
                .foregroundColor(RutTheme.textDim)

            // Name
            Text(shape.name)
                .font(.system(size: 12))
                .foregroundColor(nameColor)
                .lineLimit(1)

            // Color dot
            Circle()
                .fill(Color(hex: shape.style.strokeColor))
                .frame(width: 10, height: 10)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? RutTheme.amber.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            vectorStore.selectShape(id: shape.id, layerId: layer.id)
        }
    }

    // MARK: - Helpers

    /// Recursively checks if this layer or any descendant contains the active shape.
    private func layerContainsActiveShape(_ l: VectorLayer) -> Bool {
        guard let activeId = vectorStore.activeShapeId else { return false }
        if l.shapes.contains(where: { $0.id == activeId }) { return true }
        return l.children.contains { layerContainsActiveShape($0) }
    }

    private func shapeIcon(_ geo: VectorGeometry) -> String {
        switch geo {
        case .point:    return "mappin"
        case .polyline: return "line.diagonal"
        case .polygon:  return "triangle"
        case .circle:   return "circle"
        }
    }
}
