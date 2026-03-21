import SwiftUI

// MARK: - App Theme
// Centralized colors and button styles for Rut's dark aviation UI.

enum RutTheme {
    // Backgrounds
    static let bg        = Color(red: 0.059, green: 0.082, blue: 0.118)  // #0F1530
    static let surface   = Color(red: 0.094, green: 0.125, blue: 0.173)  // #18202C
    static let surface2  = Color(red: 0.129, green: 0.169, blue: 0.224)  // #212B39
    static let border    = Color(red: 0.188, green: 0.239, blue: 0.302)  // #303D4D

    // Accent: aviation amber + muted HUD green
    static let amber     = Color(red: 0.816, green: 0.647, blue: 0.157)  // #D0A528
    static let amberDim  = Color(red: 0.816, green: 0.647, blue: 0.157).opacity(0.12)
    static let green     = Color(red: 0.298, green: 0.659, blue: 0.416)  // #4CA86A

    // Semantic
    static let danger    = Color(red: 0.847, green: 0.329, blue: 0.329)  // #D85454

    // Text
    static let text      = Color(red: 0.878, green: 0.906, blue: 0.937)  // #E0E7EF
    static let textDim   = Color(red: 0.478, green: 0.557, blue: 0.635)  // #7A8EA2
    static let textMuted = Color(red: 0.278, green: 0.345, blue: 0.412)  // #47586A
}

// MARK: - Button Styles

/// Filled amber button – primary action.
struct RutPrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Color(red: 0.08, green: 0.10, blue: 0.14))
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.vertical, compact ? 10 : 13)
            .background(RutTheme.amber.opacity(configuration.isPressed ? 0.65 : 1))
            .cornerRadius(10)
    }
}

/// Subtle secondary button – dark surface with border.
struct RutSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundColor(RutTheme.amber)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RutTheme.surface2.opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RutTheme.border, lineWidth: 1))
            .cornerRadius(8)
    }
}

/// Ghost / tinted button – amber tint on transparent bg.
struct RutGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundColor(RutTheme.amber.opacity(configuration.isPressed ? 0.55 : 0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RutTheme.amberDim.opacity(configuration.isPressed ? 0.4 : 1))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RutTheme.amber.opacity(0.25), lineWidth: 1))
            .cornerRadius(8)
    }
}
