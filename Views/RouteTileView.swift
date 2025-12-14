import SwiftUI

struct RouteTileView: View {
    let route: Route
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(route.name)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.9) : Color.accentColor.opacity(0.3))
        .foregroundColor(.white)
        .cornerRadius(4)
        .onTapGesture {
            onTap()
        }
    }
}
