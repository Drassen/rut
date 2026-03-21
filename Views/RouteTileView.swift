import SwiftUI

struct RouteTileView: View {
    let route: Route
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(route.name)
                .lineLimit(1)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundColor(isActive ? Color(red: 0.08, green: 0.10, blue: 0.14) : RutTheme.text)

            // Point count badge
            Text("\(route.pointRefs.count)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(route.pointRefs.count > 40
                    ? RutTheme.danger
                    : (isActive ? Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.6) : RutTheme.textMuted))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background((isActive ? Color.white : RutTheme.surface).opacity(0.2))
                .clipShape(Capsule())

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isActive
                        ? Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.7)
                        : RutTheme.textMuted)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(isActive ? 0.2 : 0.05))
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(
            isActive
                ? RutTheme.amber
                : RutTheme.surface2
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isActive ? RutTheme.amber.opacity(0.5) : RutTheme.border, lineWidth: 1)
        )
        .cornerRadius(9)
        .shadow(color: isActive ? RutTheme.amber.opacity(0.25) : .clear, radius: 6, x: 0, y: 2)
        .onTapGesture { onTap() }
    }
}
