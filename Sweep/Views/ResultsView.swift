import SwiftUI
import AppKit

// MARK: - Results

/// The reviewing surface: one category at a time, groups sorted by evidence
/// then by size.
struct SWPResultsView: View {

    @EnvironmentObject private var engine: SWPScanEngine
    @State private var isConfirmingSimulators = false
    @State private var isShowingIgnored = false
    let onOpenLocalAI: () -> Void

    /// Category groups after the user's filter and sort (3.1, 3.2).
    private var groups: [SWPGroup] {
        engine.visibleGroups(in: engine.selectedCategory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if engine.hasResults || engine.filter.isActive {
                filterBar
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                    .padding(.bottom, SWPTheme.Spacing.row)
            }

            if let outcome = engine.lastOutcome {
                outcomeBanner(outcome)
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                    .padding(.bottom, SWPTheme.Spacing.row)
            } else if let message = engine.restoreMessage {
                restoreBanner(message)
                    .padding(.horizontal, SWPTheme.Spacing.pane)
                    .padding(.bottom, SWPTheme.Spacing.row)
            }

            // One scroll view in every state. The empty case used to be a
            // sibling branch, which meant an empty category also hid the
            // ignored-items footer and the Full Disk Access note — the two
            // things most likely to explain *why* it was empty.
            ScrollView {
                LazyVStack(spacing: 5) {
                    if engine.selectedCategory == .leftovers {
                        Button(action: onOpenLocalAI) {
                            Label(engine.result.aiInventory.map { "AI & Models: " + $0.summary + ($0.isPartial ? " · partial coverage" : "") }
                                  ?? "Discover AI tools, shared caches and model files in AI & Models",
                                  systemImage: "cpu")
                                .font(SWPTheme.Fonts.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(SWPSecondaryButtonStyle())
                        .padding(.bottom, SWPTheme.Spacing.row)
                    }
                    if groups.isEmpty {
                        if engine.selectedCategory == .leftovers,
                           engine.result.inventoryUnreliable {
                            inventoryNote
                        } else if engine.selectedCategory == .developer, !SWPSettings.scansDeveloper {
                            developerDisabledNote
                        } else {
                            emptyState
                        }
                    }

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

                    ignoredFooter
                }
                .padding(.horizontal, SWPTheme.Spacing.pane)
                .padding(.bottom, SWPTheme.Spacing.pane)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            if engine.isRescanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rescanning \(engine.currentStage.title.lowercased())…")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .swpCard(elevated: true)
                .padding(.top, 30)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.isRescanning)
        .alert("Disable this startup item?",
               isPresented: Binding(get: { engine.pendingDisable != nil },
                                    set: { if !$0 { engine.pendingDisable = nil } })) {
            Button("Cancel", role: .cancel) { engine.pendingDisable = nil }
            Button("Disable") {
                if let entry = engine.pendingDisable { engine.disableStartupJob(entry) }
            }
        } message: {
            Text(engine.pendingDisable.map { entry in
                "\(entry.label) will be unloaded and its configuration moved to the Trash, so it no longer starts at login.\n\nIts app is still installed. User and system-installed agents are unloaded in your current login session; other logged-in accounts may keep their agents running until logout. Restore Last Batch can restore supported configuration files but does not restart jobs."
            } ?? "")
        }
        .alert("Delete unavailable simulators?", isPresented: $isConfirmingSimulators) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { engine.deleteUnavailableSimulators() }
        } message: {
            // Delegate to simctl, which owns the simulator database.
            Text("Runs Xcode's own simctl to remove simulator devices whose runtime is no longer installed.\n\nThis does not go to the Trash and cannot be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.selectedCategory.title)
                        .font(SWPTheme.Fonts.title)
                        .foregroundStyle(SWPTheme.Colors.textPrimary)
                    Text(engine.selectedCategory.blurb)
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if !groups.isEmpty {
                    let allSelected = groups.allSatisfy { engine.isSelected($0) }
                    Button(allSelected ? "Deselect Visible" : "Select Visible") {
                        if allSelected {
                            engine.deselectAll(in: engine.selectedCategory)
                        } else {
                            engine.selectAll(in: engine.selectedCategory)
                        }
                    }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .fixedSize()
                    .help("Changes only the groups shown in this category. Out-of-view selections stay unchanged.")
                }
            }

            if engine.selectedCategory == .developer {
                Button(engine.isDeletingSimulators ? "Working" : "Delete Unavailable Simulators") {
                    isConfirmingSimulators = true
                }
                .buttonStyle(SWPSecondaryButtonStyle())
                .disabled(engine.isDeletingSimulators)
                .help("Removes simulator devices whose runtime is gone, using Xcode's own tool")
            }
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.top, 34)
        .padding(.bottom, SWPTheme.Spacing.section)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SWPSearchField(placeholder: "Filter by name or path", text: $engine.filter.query,
                               identifier: "results.search")
                Picker("Sort by", selection: $engine.sortOrder) {
                    ForEach(SWPSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 155)
                .tint(SWPTheme.Colors.accent)
                .accessibilityLabel("Sort order")
            }

            HStack(spacing: 8) {
                Picker("Minimum size", selection: $engine.filter.minimumSize) {
                    ForEach(SWPMinimumSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .help("Minimum total group size, using the last scan's measurements")
                .accessibilityLabel("Minimum group size")

                Picker("Evidence", selection: $engine.filter.evidence) {
                    Text("All evidence").tag(Optional<SWPConfidence>.none)
                    ForEach([SWPConfidence.safe, .confirmed, .likely, .inUse], id: \.self) { evidence in
                        Text(evidence.label).tag(Optional(evidence))
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityLabel("Evidence filter")

                Spacer(minLength: 0)
                if engine.filter.isActive {
                    Button("Clear Filters") { engine.clearFilters() }
                        .buttonStyle(SWPSecondaryButtonStyle())
                        .fixedSize()
                        .help("Reset name/path, size and evidence filters without changing selections")
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Empty

    /// Distinguishes "this category is clean" from "your filter matched
    /// nothing" — calling the second one clean is a lie the user can act on.
    private var emptyState: some View {
        let findingCount = engine.result.groups(in: engine.selectedCategory).count
        let noMatches = engine.filter.isActive && findingCount > 0
        return VStack(spacing: 10) {
            SWPIconTile(symbol: noMatches ? "magnifyingglass" : "checkmark",
                        tint: noMatches ? SWPTheme.Colors.textDim : SWPTheme.Colors.safe,
                        size: 40)
            Text(noMatches ? "No matches for these filters" : "Nothing to clean here")
                .font(SWPTheme.Fonts.rowTitle)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
            Text(noMatches ? "This category has \(findingCount) finding\(findingCount == 1 ? "" : "s") hidden by your filters."
                           : engine.selectedCategory.blurb)
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)
            if engine.filter.isActive {
                Button("Clear Filters") { engine.clearFilters() }
                    .buttonStyle(SWPSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
                    Text("· not included in cleanup")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                    Spacer(minLength: 8)
                    Button("Open Login Items") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .buttonStyle(SWPSecondaryButtonStyle())
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
                            Button("Disable") { engine.pendingDisable = entry }
                                .buttonStyle(.plain)
                                .font(SWPTheme.Fonts.caption)
                                .foregroundStyle(SWPTheme.Colors.accent)
                                .help("Unload this job and move its plist to the Trash — reversible")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .combine)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(SWPTheme.Fonts.body)
                if outcome.trashedCount > 0 {
                    Text("Files still occupy space in Trash until it is emptied.")
                        .font(SWPTheme.Fonts.caption)
                }
                if failedCount > 0 {
                    DisclosureGroup("\(failedCount) items need attention") {
                        ScrollView {
                            Text((outcome.failures.map { "\($0.path): \($0.reason)" }
                                  + outcome.refusedByPolicy.map { "Safety policy refused: \($0)" }).joined(separator: "\n\n"))
                                .font(SWPTheme.Fonts.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160).padding(.top, 6)
                    }
                    .font(SWPTheme.Fonts.caption)
                    Text("Review these reasons before trying again. Files already moved remain in the Trash batch.")
                        .font(SWPTheme.Fonts.caption)
                }
            }
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
            .accessibilityLabel("Dismiss")
        }
        .padding(11)
        .swpCard()
    }

    /// Result of a restore, shown where the removal banner would be.
    private func restoreBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 12))
                .foregroundStyle(engine.restoreFailures.isEmpty ? SWPTheme.Colors.safe : SWPTheme.Colors.review)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                if !engine.restoreFailures.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView {
                            Text(engine.restoreFailures.joined(separator: "\n"))
                                .font(SWPTheme.Fonts.caption)
                                .foregroundStyle(SWPTheme.Colors.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                    }
                    .font(SWPTheme.Fonts.caption)
                }
            }
            Spacer(minLength: 8)
            Button { engine.restoreMessage = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SWPTheme.Colors.textDim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(11)
        .swpCard()
    }

    // MARK: Ignored items

    /// Footer listing what the user has permanently excluded.
    ///
    /// An ignore that cannot be reviewed or undone is a trap: the item simply
    /// stops appearing and there is no way to remember why. Collapsed by
    /// default so it costs nothing when the list is empty or uninteresting.
    @ViewBuilder
    private var ignoredFooter: some View {
        if engine.ignoredCount > 0 {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(SWPTheme.Colors.textDim)
                    Text("\(engine.ignoredCount) ignored")
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textDim)
                    Button(isShowingIgnored ? "hide" : "show") {
                        isShowingIgnored.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.accent)
                    Spacer(minLength: 8)
                    if isShowingIgnored {
                        Button("Clear All") { engine.clearIgnoreList() }
                            .buttonStyle(.plain)
                            .font(SWPTheme.Fonts.caption)
                            .foregroundStyle(SWPTheme.Colors.textDim)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if isShowingIgnored {
                    SWPHairline().opacity(0.5)
                    ForEach(engine.ignoredPaths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(SWPTheme.Fonts.mono)
                                .foregroundStyle(SWPTheme.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("Stop Ignoring") { engine.stopIgnoring(path) }
                                .buttonStyle(.plain)
                                .font(SWPTheme.Fonts.caption)
                                .foregroundStyle(SWPTheme.Colors.accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
            .swpCard()
            .padding(.top, SWPTheme.Spacing.section)
        }
    }

    /// The category is empty because the user switched it off, not because
    /// there is nothing there. A green tick reading "Nothing to clean here"
    /// over a disabled scan is simply false.
    private var developerDisabledNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "pause.circle")
                .font(.system(size: 12))
                .foregroundStyle(SWPTheme.Colors.review)
            VStack(alignment: .leading, spacing: 4) {
                Text("Developer scanning is switched off")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textSecondary)
                Text("Sweep is not looking at Xcode derived data, archives, device support or package caches. Turn it back on in Settings.")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(SWPSecondaryButtonStyle())
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .swpCard()
        .padding(.top, SWPTheme.Spacing.section)
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
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(SWPSecondaryButtonStyle())
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .swpCard()
        .padding(.top, SWPTheme.Spacing.section)
    }
}
