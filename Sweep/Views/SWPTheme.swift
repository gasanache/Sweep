import SwiftUI

// MARK: - Theme

/// The single source of truth for colour, type, spacing and radius.
///
/// Dark-only, like VSGSat. A cleaner is read as a diagnostic instrument, and
/// the near-black ground lets one warm accent carry every meaningful signal —
/// the ring, the primary button, the selected row. Supporting both appearances
/// would have meant two palettes to keep honest for no real gain in a utility
/// that lives in a single window.
enum SWPTheme {

    // MARK: Colors

    enum Colors {
        // Surfaces, lightest to darkest in z-order rather than value order.
        static let background   = Color(red: 0.043, green: 0.045, blue: 0.051)   // #0b0b0d
        static let surface      = Color(red: 0.078, green: 0.082, blue: 0.094)   // #141518
        static let surfaceHigh  = Color(red: 0.110, green: 0.114, blue: 0.130)   // #1c1d21
        static let border       = Color(red: 0.169, green: 0.176, blue: 0.196)   // #2b2d32
        static let borderStrong = Color(red: 0.239, green: 0.251, blue: 0.278)   // #3d4047

        // Text
        static let textPrimary   = Color(red: 0.929, green: 0.933, blue: 0.941)  // #edeef0
        static let textSecondary = Color(red: 0.612, green: 0.627, blue: 0.663)  // #9ca0a9
        static let textDim       = Color(red: 0.404, green: 0.420, blue: 0.455)  // #676b74

        /// The one accent. Warm gold reads as "dust and sweeping" without the
        /// alarm that red carries or the sterile default of system blue.
        static let accent      = Color(red: 0.949, green: 0.702, blue: 0.239)    // #f2b33d
        static let accentDeep  = Color(red: 0.847, green: 0.545, blue: 0.153)    // #d88b27

        // Confidence badges. Used small and sparingly — the palette stays
        // monochrome so that these few tints are the only colour that means
        // something in the results list. In Use is a deliberately cool,
        // unexciting steel: it marks data that belongs to a living app, which
        // should read as "occupied", not as an invitation.
        static let safe    = Color(red: 0.392, green: 0.831, blue: 0.588)        // #64d496
        static let review  = Color(red: 0.949, green: 0.702, blue: 0.239)        // #f2b33d
        static let caution = Color(red: 0.949, green: 0.451, blue: 0.400)        // #f27366
        static let inUse   = Color(red: 0.478, green: 0.616, blue: 0.769)        // #7a9dc4

        static func tint(for confidence: SWPConfidence) -> Color {
            switch confidence {
            case .safe:      return safe
            case .confirmed: return caution
            case .likely:    return review
            case .inUse:     return inUse
            }
        }
    }

    // MARK: Typography

    enum Fonts {
        static let hero        = Font.system(size: 46, weight: .medium, design: .rounded)
        static let heroUnit    = Font.system(size: 15, weight: .semibold, design: .rounded)
        static let title       = Font.system(size: 17, weight: .semibold)
        static let rowTitle    = Font.system(size: 13, weight: .medium)
        static let body        = Font.system(size: 12, weight: .regular)
        static let caption     = Font.system(size: 11, weight: .regular)
        static let badge       = Font.system(size: 9.5, weight: .semibold)
        static let mono        = Font.system(size: 10.5, weight: .regular, design: .monospaced)
        /// Sizes are compared down a column, so they must not shift width as
        /// digits change.
        static let number      = Font.system(size: 12, weight: .medium).monospacedDigit()
    }

    // MARK: Metrics

    enum Spacing {
        static let tight: CGFloat = 6
        static let row: CGFloat = 10
        static let section: CGFloat = 16
        static let pane: CGFloat = 20
        static let sidebarWidth: CGFloat = 208
        static let radiusCard: CGFloat = 12
        static let radiusRow: CGFloat = 9
        static let radiusBadge: CGFloat = 5
    }
}

// MARK: - Card style

/// Surface fill, continuous corners, hairline border — the chrome every panel
/// in Sweep shares. Adds no padding of its own, because the rows inside are
/// self-padding and a second inset made nested cards drift out of alignment.
struct SWPCardStyle: ViewModifier {

    var elevated: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SWPTheme.Spacing.radiusCard, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(elevated ? SWPTheme.Colors.surfaceHigh : SWPTheme.Colors.surface)
            .clipShape(shape)
            .overlay(shape.stroke(SWPTheme.Colors.border, lineWidth: 1))
    }
}

extension View {
    func swpCard(elevated: Bool = false) -> some View {
        modifier(SWPCardStyle(elevated: elevated))
    }
}
