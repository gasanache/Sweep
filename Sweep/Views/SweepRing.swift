import SwiftUI

// MARK: - Sweep ring

/// The animated dial at the centre of the hero.
///
/// Three concentric arcs at different radii and speeds. The counter-rotation is
/// the whole point: two arcs turning the same way read as a spinner (a thing
/// you wait on), while opposed arcs read as a mechanism doing work. During a
/// scan they run fast; at rest they drift, so the window never looks frozen.
///
/// Driven by `TimelineView(.animation)` rather than a `repeatForever`
/// animation. Repeating animations on a view that also changes state get
/// cancelled and restarted on every re-render, which made the ring visibly
/// stutter each time the progress label changed.
struct SWPSweepRing: View {

    /// `nil` while scanning — the dial is indeterminate. A value renders a
    /// definite arc, used to show what fraction of the findings are ticked.
    var progress: Double?
    var isActive: Bool
    var diameter: CGFloat = 190

    var body: some View {
        // Full frame rate only while a scan is running; the idle drift renders
        // at 20 fps, which the slow rotation hides completely. A decorative
        // dial has no business keeping a utility app on a 60 Hz wake cycle.
        TimelineView(.animation(minimumInterval: isActive ? 1.0 / 60.0 : 1.0 / 20.0,
                                paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let speed: Double = isActive ? 1.0 : 0.16

            ZStack {
                // Track
                Circle()
                    .stroke(SWPTheme.Colors.border, lineWidth: 1)
                    .frame(width: diameter, height: diameter)

                Circle()
                    .stroke(SWPTheme.Colors.border.opacity(0.6), lineWidth: 1)
                    .frame(width: diameter * 0.74, height: diameter * 0.74)

                // Outer arc, clockwise. Suppressed while a definite arc is
                // showing: both are drawn on the SAME radius, so they overlaid
                // each other and the join between the solid arc and the
                // rotating translucent one read as a cut in the ring.
                if progress == nil {
                    arc(trim: 0.34, lineWidth: 3.5, diameter: diameter,
                        gradient: [SWPTheme.Colors.accent.opacity(0.05),
                                   SWPTheme.Colors.accent])
                        .rotationEffect(.degrees(time * 62 * speed))
                }

                // Middle arc, counter-clockwise and dimmer, so it reads as
                // depth rather than as a second spinner competing for
                // attention.
                arc(trim: 0.20, lineWidth: 2, diameter: diameter * 0.74,
                    gradient: [SWPTheme.Colors.accentDeep.opacity(0.04),
                               SWPTheme.Colors.accentDeep.opacity(0.75)])
                    .rotationEffect(.degrees(-time * 41 * speed))

                // Inner hairline, fastest, only visible while working.
                if isActive {
                    arc(trim: 0.12, lineWidth: 1.5, diameter: diameter * 0.52,
                        gradient: [SWPTheme.Colors.accent.opacity(0.0),
                                   SWPTheme.Colors.accent.opacity(0.55)])
                        .rotationEffect(.degrees(time * 128))
                }

                // Definite progress overlay, drawn over its own full-circle
                // track so the remaining portion still reads as part of a ring
                // rather than as a gap.
                if let progress, progress > 0 {
                    Circle()
                        .stroke(SWPTheme.Colors.accent.opacity(0.12), lineWidth: 3.5)
                        .frame(width: diameter, height: diameter)

                    Circle()
                        .trim(from: 0, to: min(max(progress, 0), 1))
                        .stroke(
                            SWPTheme.Colors.accent,
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                        )
                        .frame(width: diameter, height: diameter)
                        .rotationEffect(.degrees(-90))
                        .shadow(color: SWPTheme.Colors.accent.opacity(0.35), radius: 8)
                }
            }
            .frame(width: diameter, height: diameter)
            // Room for the stroke's outer half and the progress arc's glow.
            // `.drawingGroup()` rasterises into a buffer the size of the view
            // it is applied to, so with a frame of exactly `diameter` the
            // shadow was sliced off square — a straight vertical cut down the
            // right-hand side of the ring. The negative padding afterwards
            // keeps the layout footprint unchanged.
            .padding(Self.glowInset)
            .drawingGroup()
            .padding(-Self.glowInset)
        }
    }

    /// Half the stroke width plus enough for the 8 pt shadow to fall off.
    private static let glowInset: CGFloat = 24

    /// One trimmed arc with a gradient that spans exactly the arc.
    ///
    /// `AngularGradient(colors:center:)` lays its ramp across the full 360° and
    /// wraps from the last colour straight back to the first, so a trimmed arc
    /// showed only the first slice of the ramp and carried a hard seam wherever
    /// the 0° boundary fell underneath it. Bounding the gradient to the arc's
    /// own sweep removes the seam and lets the fade actually run end to end.
    private func arc(trim: Double, lineWidth: CGFloat, diameter: CGFloat,
                     gradient: [Color]) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(
                AngularGradient(gradient: Gradient(colors: gradient),
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(360 * trim)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: diameter, height: diameter)
    }
}
