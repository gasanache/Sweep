import SwiftUI

// MARK: - Results

/// The reviewing surface: one category at a time, groups sorted by evidence
/// then by size.
struct SWPResultsView: View {

    @EnvironmentObject private var engine: SWPScanEngine

    private var groups: [SWPGroup] { engine.result.groups(in: engine.selectedCategory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let outcome = engine.lastOutcome {
                outcomeBanner(outcome)
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                    .padding(.bottom, SWPTheme.Spacing.row)
            }

            if groups.isEmpty && engine.selectedCategory != .startup {
                if engine.selectedCategory == .leftovers, engine.result.inventoryUnreliable {
                    VStack(spacing: 0) {
                        inventoryNote
                        Spacer()
                    }
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                } else {
                    emptyState
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(groups) { group in
                            SWPGroupRowView(group: group)
                        }

                        if engine.selectedCategory == .startup {
                            healthyStartupSection
                        }

                        if !engine.result.unreadablePaths.isEmpty,
                           engine.selectedCategory == .leftovers {
                            permissionNote
                        }
                    }
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                    .padding(.bottom, SWPTheme.Spacing.pane)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.selectedCategory.title)
                    .font(SWPTheme.Fonts.title)
                    .foregroundStyle(SWPTheme.Colors.textPrimary)
                Text(engine.selectedCategory.blurb)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }

            Spacer()

            if !groups.isEmpty {
                let allSelected = groups.allSatisfy { engine.isSelected($0) }
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        engine.deselectAll(in: engine.selectedCategory)
                    } else {
                        engine.selectAll(in: engine.selectedCategory)
                    }
                }
                .buttonStyle(SWPSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.top, 34)
        .padding(.bottom, SWPTheme.Spacing.section)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            SWPIconTile(symbol: "checkmark", tint: SWPTheme.Colors.safe, size: 40)
            Text("Nothing to clean here")
                .font(SWPTheme.Fonts.rowTitle)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
            Text(engine.selectedCategory.blurb)
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Startup extras

    /// Working background agents, listed read-only.
    ///
    /// Sweep will not offer to remove these — they belong to apps that are
    /// installed and running. They are shown because "what actually loads at
    /// login" is the question this category exists to answer, and hiding the
    /// healthy majority would make the list look alarmingly short.
    @ViewBuilder
    private var healthyStartupSection: some View {
        if !engine.healthyStartupItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("ALSO LOADING AT LOGIN")
                        .font(SWPTheme.Fonts.badge)
                        .tracking(0.7)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                    Text("· owned by installed apps, left alone")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                }
                .padding(.top, SWPTheme.Spacing.section)

                VStack(spacing: 0) {
                    ForEach(Array(engine.healthyStartupItems.enumerated()), id: \.element.id) {
                        index, entry in
                        if index > 0 { SWPHairline() }
                        HStack(spacing: 8) {
                            Circle()
                                .fill(SWPTheme.Colors.safe.opacity(0.7))
                                .frame(width: 5, height: 5)
                            Text(entry.label)
                                .font(SWPTheme.Fonts.mono)
                                .foregroundStyle(SWPTheme.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(entry.scopeLabel)
                                .font(SWPTheme.Fonts.caption)
                                .foregroundStyle(SWPTheme.Colors.textDim)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
                .swpCard()
            }
        }
    }

    // MARK: Removal outcome

    /// What the last removal actually did — including the parts that went
    /// wrong. The uninstaller has always said this; the scan flow used to
    /// stay silent on failures and a cancelled password prompt, leaving rows
    /// in the list with no explanation.
    private func outcomeBanner(_ outcome: SWPRemovalOutcome) -> some View {
        let failedCount = outcome.failures.count + outcome.refusedByPolicy.count
        let isClean = failedCount == 0 && !outcome.adminCancelled

        var text = outcome.trashedCount > 0
            ? "Moved \(outcome.trashedCount) item\(outcome.trashedCount == 1 ? "" : "s") (\(SWPBytes.string(outcome.trashedBytes))) to the Trash."
            : "Nothing was moved."
        if outcome.adminCancelled {
            text += " System items were skipped — authorisation was cancelled."
        }
        if failedCount > 0 {
            text += " \(failedCount) item\(failedCount == 1 ? "" : "s") couldn't be moved."
        }

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: isClean ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(isClean ? SWPTheme.Colors.safe : SWPTheme.Colors.review)
            Text(text)
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { engine.clearOutcome() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(11)
        .swpCard()
    }

    // MARK: Inventory health

    /// Shown when the installed-app inventory came back suspiciously small.
    ///
    /// In that state the leftovers scan refuses to run — with a near-empty
    /// index, everything on the disk would read as orphaned — and an empty
    /// list must say why it is empty rather than let the user conclude their
    /// Mac is spotless.
    private var inventoryNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(SWPTheme.Colors.review)
            VStack(alignment: .leading, spacing: 3) {
                Text("Leftover detection was skipped this scan")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                Text("The installed-app inventory looked incomplete — Spotlight may still be indexing. Sweep refuses to guess in that state; rescan in a few minutes.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .swpCard()
        .padding(.top, SWPTheme.Spacing.section)
    }

    // MARK: Permissions

    /// Full Disk Access note.
    ///
    /// Shown only when a location actually failed to read, rather than as a
    /// permanent nag: most of what Sweep needs is readable without it.
    private var permissionNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundStyle(SWPTheme.Colors.review)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(engine.result.unreadablePaths.count) location\(engine.result.unreadablePaths.count == 1 ? "" : "s") could not be read")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                Text("Grant Full Disk Access in System Settings › Privacy & Security for a complete scan.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .swpCard()
        .padding(.top, SWPTheme.Spacing.section)
    }
}
