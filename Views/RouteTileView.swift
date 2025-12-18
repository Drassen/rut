import SwiftUI

struct RouteTileView: View {
    let route: Route
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(route.name)")
                .lineLimit(1)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive ? .white : .primary)
            
            Text("\(route.pointRefs.count)")
                .lineLimit(1)
                .fontWeight(.regular)
                .foregroundColor(route.pointRefs.count>40 ? .red : .white.opacity(0.6))

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(isActive ? .white.opacity(0.8) : .secondary)
                    .padding(4)
                    .background(Color.black.opacity(0.1))
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(isActive ? Color.blue : Color(.secondarySystemBackground))
        .cornerRadius(8)
        .onTapGesture {
            onTap()
        }
    }
}
