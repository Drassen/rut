import SwiftUI

// MARK: - VectorLayerRowView

/// Recursive row that renders a VectorLayer node at a given indentation depth.
struct VectorLayerRowView: View {
    @EnvironmentObject var vectorStore: VectorStore

    let layer: VectorLayer
    let depth: Int

    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var editingShape: (shape: VectorShape, layerId: UUID)? = nil

    private let indent: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            layerRow
            if layer.isExpanded {
                // Shapes
                ForEach(layer.shapes) { shape in
                    shapeRow(shape)
                }
                // Children (recursive)
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
        .sheet(item: Binding(
            get: { editingShape.map { IdentifiedShape(shape: $0.shape, layerId: $0.layerId) } },
            set: { if $0 == nil { editingShape = nil } }
        )) { identified in
            VectorShapeEditorView(shape: identified.shape, layerId: identified.layerId)
                .environmentObject(vectorStore)
        }
    }

    private var layerRow: some View {
        HStack(spacing: 6) {
            // Indent
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

            // Visibility eye
            Button { vectorStore.toggleLayerVisibility(id: layer.id) } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundColor(layer.isVisible ? RutTheme.textDim : RutTheme.textMuted)
            }
            .buttonStyle(.plain)

            // Folder icon
            Image(systemName: layer.isSystem ? "lock.fill" : "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(layer.isSystem ? RutTheme.textMuted : RutTheme.amber)

            // Name
            Text(layer.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isActiveLayer ? RutTheme.amber : RutTheme.text)
                .lineLimit(1)
                .onTapGesture {
                    vectorStore.setActiveLayer(layer.id)
                }
                .onLongPressGesture {
                    if !layer.isSystem {
                        renameText = layer.name
                        showRenameAlert = true
                    }
                }

            Spacer(minLength: 4)

            // Delete button (not for system layers)
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
        .padding(.vertical, 5)
        .background(
            isActiveLayer
                ? RutTheme.amber.opacity(0.08)
                : Color.clear
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func shapeRow(_ shape: VectorShape) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth + 1) * indent + 14, height: 1)

            // Visibility
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
                .foregroundColor(RutTheme.textDim)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Color dot
            Circle()
                .fill(Color(hex: shape.style.strokeColor))
                .frame(width: 10, height: 10)

            // Delete
            Button(role: .destructive) {
                vectorStore.deleteShape(shapeId: shape.id, in: layer.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(RutTheme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            editingShape = (shape: shape, layerId: layer.id)
        }
    }

    private var isActiveLayer: Bool { vectorStore.activeLayerId == layer.id }

    private func shapeIcon(_ geo: VectorGeometry) -> String {
        switch geo {
        case .point:    return "circle.fill"
        case .polyline: return "line.diagonal"
        case .polygon:  return "hexagon"
        case .circle:   return "circle"
        }
    }
}

// Wrapper to make optional sheet binding work
private struct IdentifiedShape: Identifiable {
    let id = UUID()
    let shape: VectorShape
    let layerId: UUID
}
