import SwiftUI
import AppKit

// MARK: - Theme

/// The single source of truth for colour, type, spacing and radius.
///
/// Dark-first: the palette was designed for a near-black ground where one warm
/// accent carries every meaningful signal — the ring, the primary button, the
/// selected row. The light counterpart preserves that intent rather than
/// merely inverting it, and every text pair in it was checked to WCAG AA
/// including the alpha-composited badge cases. Appearance follows the system
/// unless overridden in Settings.
enum SWPTheme {

    // MARK: Colors

    enum Colors {

        /// A token that resolves per appearance.
        ///
        /// `NSColor(name:dynamicProvider:)` rather than reading a SwiftUI
        /// `@Environment(\.colorScheme)` in every view: the provider is asked
        /// again whenever the effective appearance changes, so a token works
        /// identically in the main window, in a sheet, in the About window and
        /// in an `NSSavePanel` — none of which share an environment.
        private static func token(dark: UInt32, light: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }

        // Surfaces, ordered by z-role rather than by value. The light ramp
        // inverts the value order deliberately: `surfaceHigh` is *darker* than
        // `surface` on light, because a selected row has to gain weight, and
        // on a white ground gaining weight means going down, not up.
        static let background   = token(dark: 0x0B0B0D, light: 0xEDEFF2)
        static let surface      = token(dark: 0x141518, light: 0xFFFFFF)
        static let surfaceHigh  = token(dark: 0x1C1D21, light: 0xE4E8EE)
        static let border       = token(dark: 0x2B2D32, light: 0xD3D8E0)
        static let borderStrong = token(dark: 0x3D4047, light: 0x858D9B)

        // Text. `textDim` is intentionally stricter in light than its dark
        // counterpart: it carries real content (paths, counts, timestamps) and
        // the dark value only reaches ~3.4:1, short of AA. The light value
        // clears 4.5:1 on every surface rather than reproducing that shortfall.
        static let textPrimary   = token(dark: 0xEDEEF0, light: 0x15171B)
        static let textSecondary = token(dark: 0x9CA0A9, light: 0x4E5560)
        static let textDim       = token(dark: 0x676B74, light: 0x5F6674)

        /// The one accent. Warm gold reads as "dust and sweeping" on black;
        /// on white the same hue has to carry its signal through depth instead
        /// of brightness, so light mode uses a deep bronze of the same hue.
        /// That single value solves two constraints at once — `SWPCheckbox`
        /// and `SWPPrimaryButtonStyle` both draw their foreground in
        /// `background`, so a dark accent is what makes the button label and
        /// the tick glyph legible (5.9:1) without inventing an on-accent token.
        static let accent      = token(dark: 0xF2B33D, light: 0x7D5200)
        /// Recessive ring gradient. The relationship inverts rather than the
        /// value: darker than `accent` on black, lighter than it on white.
        static let accentDeep  = token(dark: 0xD88B27, light: 0xA87828)

        // Confidence tints. Hues are held across appearances (safe 148°,
        // review 39°, caution 4°, inUse 209°) so the meanings stay learnable.
        // The light values are darker than a naive inversion because
        // `SWPBadge` paints its tint at 14% and then sets the same tint as
        // 9.5 pt text on top — that composite, over a *selected* card, is the
        // lowest-contrast pairing in the app and is what set the floor.
        static let safe    = token(dark: 0x64D496, light: 0x0B5C30)
        static let review  = token(dark: 0xF2B33D, light: 0x7D5200)
        static let caution = token(dark: 0xF27366, light: 0xA3271F)
        static let inUse   = token(dark: 0x7A9DC4, light: 0x28598A)

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

// MARK: - Hex

extension NSColor {
    /// 0xRRGGBB literal → colour. Used only by the theme's token table, where
    /// hex is the form the palette was designed and contrast-checked in.
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
