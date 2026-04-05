import SwiftUI

// MARK: - VectorLayerRowView
// Renders only the layer header row. Shape rows are rendered by VectorLayerPanel.

struct VectorLayerRowView: View {
    @EnvironmentObject var vectorStore: VectorStore

    let layer: VectorLayer
    let depth: Int

    private let indent: CGFloat = 16

    var body: some View {
        let isFolderSelected = vectorStore.activeLayerId == layer.id && vectorStore.activeShapeId == nil
        let showAmberBg      = isFolderSelected
        let dimColor: Color  = layer.isSystem ? RutTheme.textMuted : RutTheme.textDim
        let nameColor: Color = isFolderSelected ? .white : dimColor

        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * indent, height: 1)

            // Expand/collapse chevron
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vectorStore.toggleLayerExpanded(id: layer.id)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(dimColor)
                    .rotationEffect(.degrees(layer.isExpanded ? 90 : 0))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)

            // Visibility eye
            Button { vectorStore.toggleLayerVisibility(id: layer.id) } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundColor(layer.isVisible ? dimColor : RutTheme.textMuted)
            }
            .buttonStyle(.plain)

            // Folder / lock icon
            Image(systemName: layer.isSystem ? "lock.fill" : "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(RutTheme.textMuted)

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
            vectorStore.activeShapeId = nil
            vectorStore.activeShapeLayerId = nil
            vectorStore.isEditingShape = false
            vectorStore.editingVertices = []
            vectorStore.setActiveLayer(layer.id)
        }
    }


}

// MARK: - VectorShapeRowView
// Standalone shape row, rendered by VectorLayerPanel (no reorder gesture parent).

struct VectorShapeRowView: View {
    @EnvironmentObject var vectorStore: VectorStore

    let shape: VectorShape
    let layerId: UUID
    let depth: Int

    private let indent: CGFloat = 16

    var body: some View {
        let isSelected   = vectorStore.activeShapeId == shape.id
        let isSystem     = vectorStore.layerIsSystem(id: layerId)
        let dimColor: Color  = isSystem ? RutTheme.textMuted : RutTheme.textDim
        let nameColor: Color = isSelected ? .white : dimColor

        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth + 1) * indent + 14, height: 1)

            Button {
                var updated = shape
                updated.isVisible.toggle()
                vectorStore.updateShape(updated, in: layerId)
            } label: {
                Image(systemName: shape.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundColor(shape.isVisible ? dimColor : RutTheme.textMuted)
            }
            .buttonStyle(.plain)

            if case .point = shape.geometry {
                VectorPointIconView(icon: shape.style.pointIcon, color: dimColor, size: 13)
            } else {
                Image(systemName: shapeIcon(shape.geometry))
                    .font(.system(size: 11))
                    .foregroundColor(dimColor)
            }

            Text(shape.name)
                .font(.system(size: 12))
                .foregroundColor(nameColor)
                .lineLimit(1)

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
            vectorStore.selectShape(id: shape.id, layerId: layerId)
        }
    }

    private func shapeIcon(_ geo: VectorGeometry) -> String {
        switch geo {
        case .point:    return "mappin.circle.fill"
        case .polyline: return "line.diagonal"
        case .polygon:  return "triangle"
        case .circle:   return "circle"
        }
    }
}
