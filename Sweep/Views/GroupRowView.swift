import SwiftUI

// MARK: - Group row

/// One owner's leftovers as a single collapsible row.
///
/// The tick box sits on the group, never on individual paths. The decision a
/// user is equipped to make is "do I still want anything from Krisp?", not
/// "should this particular HTTPStorages folder survive?" — offering per-path
/// ticks would imply a precision nobody has the information to exercise.
struct SWPGroupRowView: View {

    @EnvironmentObject private var engine: SWPScanEngine
    let group: SWPGroup

    @State private var isHovering = false

    private var isSelected: Bool { engine.isSelected(group) }
    private var isExpanded: Bool { engine.expandedGroupIDs.contains(group.id) }
    private var tint: Color { SWPTheme.Colors.tint(for: group.confidence) }

    var body: some View {
        VStack(spacing: 0) {
            summaryRow

            if isExpanded {
                SWPHairline()
                pathList
            }
        }
        .swpCard(elevated: isSelected)
        .overlay(
            RoundedRectangle(cornerRadius: SWPTheme.Spacing.radiusCard, style: .continuous)
                .stroke(isSelected ? SWPTheme.Colors.accent.opacity(0.45) : Color.clear,
                        lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.14), value: isExpanded)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    // MARK: Summary

    private var summaryRow: some View {
        HStack(spacing: 10) {
            Button { engine.toggle(group) } label: {
                SWPCheckbox(isOn: isSelected)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(SWPTheme.Fonts.rowTitle)
                        .foregroundStyle(SWPTheme.Colors.textPrimary)
                        .lineLimit(1)

                    // The "Safe" badge would appear on every row in three of the
                    // five categories, so it is suppressed — a badge that never
                    // varies carries no information.
                    if group.confidence != .safe {
                        SWPBadge(text: group.confidence.label, tint: tint)
                    }
                    if group.requiresAdmin {
                        SWPBadge(text: "Admin", tint: SWPTheme.Colors.review)
                    }
                }

                Text(group.subtitle)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(SWPBytes.string(group.sizeBytes))
                .font(SWPTheme.Fonts.number)
                .foregroundStyle(isSelected
                                 ? SWPTheme.Colors.accent : SWPTheme.Colors.textSecondary)

            Button { engine.toggleExpansion(group) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the exact paths")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { engine.toggle(group) }
        .onHover { isHovering = $0 }
        .background(isHovering ? SWPTheme.Colors.surfaceHigh.opacity(0.5) : Color.clear)
    }

    // MARK: Paths

    /// Exact paths, revealed on demand.
    ///
    /// Always available and never hidden behind a preference: an app that moves
    /// files must be able to show precisely which files, or the user is being
    /// asked to trust a number.
    private var pathList: some View {
        VStack(spacing: 0) {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    SWPHairline().opacity(0.5)
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayPath)
                            .font(SWPTheme.Fonts.mono)
                            .foregroundStyle(SWPTheme.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(item.location)
                            .font(SWPTheme.Fonts.caption)
                            .foregroundStyle(SWPTheme.Colors.textDim)
                    }

                    Spacer(minLength: 8)

                    Text(SWPBytes.string(item.sizeBytes))
                        .font(SWPTheme.Fonts.caption.monospacedDigit())
                        .foregroundStyle(SWPTheme.Colors.textDim)

                    Button { engine.reveal(item) } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10.5))
                            .foregroundStyle(SWPTheme.Colors.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .background(SWPTheme.Colors.background.opacity(0.4))
    }
}
