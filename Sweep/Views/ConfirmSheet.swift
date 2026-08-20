import SwiftUI

// MARK: - Confirmation

/// The last screen before anything moves.
///
/// States the exact count, the exact size, and — crucially — that the
/// destination is the Trash rather than oblivion. Users approach this category
/// of app braced for an irreversible mistake, and the single most reassuring
/// thing it can say is that Put Back still works.
struct SWPConfirmSheet: View {

    @EnvironmentObject private var engine: SWPScanEngine

    private var groups: [SWPGroup] { engine.selectedGroups }
    private var adminCount: Int { engine.selectedItems.filter(\.requiresAdmin).count }
    private var inUseCount: Int { groups.filter { $0.confidence == .inUse }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: SWPTheme.Spacing.section) {
            header
            summary

            if inUseCount > 0 { inUseNote }
            if adminCount > 0 { adminNote }

            buttons
        }
        .padding(SWPTheme.Spacing.pane)
        .frame(width: 430)
        .background(SWPTheme.Colors.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            SWPIconTile(symbol: "trash", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Move to Trash?")
                    .font(SWPTheme.Fonts.title)
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                Text("Recoverable with Put Back in Finder.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(engine.selectedItems.count) items from \(groups.count) app\(groups.count == 1 ? "" : "s")")
                    .font(SWPTheme.Fonts.body)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                Spacer()
                Text(SWPBytes.string(engine.selectedBytes))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(SWPTheme.Colors.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            SWPHairline()

            // Capped at eight rows: a scrolling wall of names inside a
            // confirmation dialog stops being read.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(groups.prefix(8)) { group in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(SWPTheme.Colors.tint(for: group.confidence))
                                .frame(width: 5, height: 5)
                            Text(group.name)
                                .font(SWPTheme.Fonts.caption)
                                .foregroundStyle(SWPTheme.Colors.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(SWPBytes.string(group.sizeBytes))
                                .font(SWPTheme.Fonts.caption.monospacedDigit())
                                .foregroundStyle(SWPTheme.Colors.textDim)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                    }

                    if groups.count > 8 {
                        HStack {
                            Text("and \(groups.count - 8) more")
                                .font(SWPTheme.Fonts.caption)
                                .foregroundStyle(SWPTheme.Colors.textDim)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 150)
        }
        .swpCard()
    }

    // MARK: In use

    /// The user ticked caches belonging to apps that are still installed.
    /// Not a warning that something will break — a plain statement of the
    /// cost, because "cleaning" a live app's cache is the most common way
    /// tools in this category disappoint people.
    private var inUseNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 12))
                .foregroundStyle(SWPTheme.Colors.inUse)
            Text("\(inUseCount) group\(inUseCount == 1 ? " belongs" : "s belong") to apps that are still installed. They will rebuild this data — next launches may be slower, and offline content may need downloading again.")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .swpCard()
    }

    // MARK: Admin

    private var adminNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12))
                .foregroundStyle(SWPTheme.Colors.review)
            Text("\(adminCount) item\(adminCount == 1 ? " is" : "s are") in /Library and need your password. They move to a dated folder inside the Trash, and any matching background daemon is unloaded first.")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .swpCard()
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 9) {
            Spacer()
            Button("Cancel") { engine.isConfirming = false }
                .buttonStyle(SWPSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button("Move to Trash") { engine.performRemoval() }
                .buttonStyle(SWPPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}
