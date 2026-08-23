import SwiftUI
import AppKit

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
    @FocusState private var isFocused: Bool

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
        // Tab moves between rows, Space ticks the focused one, Return expands
        // it — the keyboard equivalent of the two things the mouse can do.
        .focusable()
        .focused($isFocused)
        .onKeyPress(.space) { engine.toggle(group); return .handled }
        .onKeyPress(.return) { engine.toggleExpansion(group); return .handled }
        .overlay(
            RoundedRectangle(cornerRadius: SWPTheme.Spacing.radiusCard, style: .continuous)
                .stroke(isFocused ? SWPTheme.Colors.accent : Color.clear, lineWidth: 2)
                .padding(-1)
        )
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

                HStack(spacing: 5) {
                    Text(group.subtitle)
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                        .lineLimit(1)
                        .layoutPriority(1)

                    ForEach(group.locationChips, id: \.self) { chip in
                        Text(chip)
                            .font(SWPTheme.Fonts.badge)
                            .foregroundStyle(SWPTheme.Colors.textDim)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(SWPTheme.Colors.surfaceHigh)
                            )
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
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
            .accessibilityLabel(isExpanded ? "Hide paths" : "Show paths")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { engine.toggle(group) }
        .onHover { isHovering = $0 }
        .background(isHovering ? SWPTheme.Colors.surfaceHigh.opacity(0.5) : Color.clear)
        // One row = one VoiceOver element that states what it is, how big it
        // is, how sure Sweep is, and whether it is selected.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name), \(group.confidence.label), \(SWPBytes.string(group.sizeBytes)), \(group.subtitle)")
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { engine.toggle(group) }
        .accessibilityAction(named: "Show paths") { engine.toggleExpansion(group) }
        .contextMenu {
            Button(isSelected ? "Deselect" : "Select") { engine.toggle(group) }
            Button(isExpanded ? "Hide Paths" : "Show Paths") { engine.toggleExpansion(group) }
            Divider()
            if let first = group.items.first {
                Button("Reveal in Finder") { engine.reveal(first) }
                Button("Copy Path\(group.items.count > 1 ? "s" : "")") {
                    let text = group.items.map(\.url.path).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Divider()
            Button("Always Ignore This") { engine.ignore(group) }
        }
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
                    .accessibilityLabel("Reveal in Finder")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
            }
        }
        .background(SWPTheme.Colors.background.opacity(0.4))
    }
}
