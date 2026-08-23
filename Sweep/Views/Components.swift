import SwiftUI

// MARK: - Badge

/// Small pill used for confidence and for "Admin".
struct SWPBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text.uppercased())
            .font(SWPTheme.Fonts.badge)
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .accessibilityLabel("\(text) tier")
            .background(tint.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: SWPTheme.Spacing.radiusBadge, style: .continuous)
                    .stroke(tint.opacity(0.28), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: SWPTheme.Spacing.radiusBadge,
                                        style: .continuous))
    }
}

// MARK: - Checkbox

/// A tick box that reads at a glance in a dense list.
///
/// SwiftUI's `Toggle(.checkbox)` was tried first and rejected: it renders at
/// system blue, which would have put a second accent colour in a palette built
/// around exactly one.
struct SWPCheckbox: View {
    let isOn: Bool
    var tint: Color = SWPTheme.Colors.accent

    var body: some View {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(isOn ? tint : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .stroke(isOn ? tint : SWPTheme.Colors.borderStrong, lineWidth: 1.2)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(SWPTheme.Colors.background)
                    .opacity(isOn ? 1 : 0)
            )
            .frame(width: 15, height: 15)
            .animation(.easeOut(duration: 0.12), value: isOn)
            // A shape-based tick box is invisible to VoiceOver without this:
            // it has no text, no control identity, and no state to report.
            .accessibilityElement()
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("Select")
            .accessibilityValue(isOn ? "selected" : "not selected")
    }
}

// MARK: - Primary button

struct SWPPrimaryButtonStyle: ButtonStyle {
    var tint: Color = SWPTheme.Colors.accent
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            // Disabled uses a dimmed *text* colour rather than the window
            // ground: the ground is near-white in light mode, and drawing it on
            // a 30%-accent fill left the label all but invisible.
            .foregroundStyle(isEnabled ? SWPTheme.Colors.background
                                       : SWPTheme.Colors.textDim)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled ? tint : SWPTheme.Colors.surfaceHigh)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isEnabled ? .clear : SWPTheme.Colors.border, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Quiet button for secondary actions, so the gold stays scarce enough to mean
/// "this is the action".
struct SWPSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SWPTheme.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(SWPTheme.Colors.surfaceHigh)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(SWPTheme.Colors.border, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Icon tile

/// Rounded glyph tile used in the sidebar and in empty states.
struct SWPIconTile: View {
    let symbol: String
    var tint: Color = SWPTheme.Colors.accent
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(tint.opacity(0.13))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
            // Decorative: the adjacent label already carries the meaning.
            .accessibilityHidden(true)
    }
}

// MARK: - Divider

struct SWPHairline: View {
    var body: some View {
        Rectangle()
            .fill(SWPTheme.Colors.border)
            .frame(height: 1)
    }
}
