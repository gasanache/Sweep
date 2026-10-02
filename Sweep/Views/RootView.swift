import SwiftUI

// MARK: - Root

/// Window shell: sidebar, main pane, action bar.
///
/// Privacy and Local AI operations have their own stores and never
/// participate in the cleaner's batch selection or removal state.
struct SWPRootView: View {

    @EnvironmentObject private var engine: SWPScanEngine
    @EnvironmentObject private var uninstaller: SWPUninstallStore
    @StateObject private var privacy = SWPPrivacyStore()
    @StateObject private var localAI = SWPLocalAIStore()
    @StateObject private var storage = SWPStorageStore()

    private var isMutationInProgress: Bool {
        localAI.isRemoving || privacy.isResetting || uninstaller.isUninstalling || engine.isMutating
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SWPSidebarView()
                    .disabled(isMutationInProgress)
                    .frame(width: SWPTheme.Spacing.sidebarWidth)

                Rectangle()
                    .fill(SWPTheme.Colors.border)
                    .frame(width: 1)

                mainPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(isMutationInProgress)
            }

            if engine.destination != .privacy, engine.destination != .storage,
               let folder = engine.restorableFolders.first {
                SWPHairline()
                recoveryBar(folder: folder)
                    .disabled(isMutationInProgress || engine.isConfirming)
            }

            // Gated on the pane, not on whether anything was found: an empty
            // result hid the action bar entirely, taking the only visible
            // Rescan button with it and leaving no way forward.
            if engine.destination.isCleanup, engine.phase == .results || engine.phase == .removing {
                SWPHairline()
                actionBar
                    .disabled(engine.isMutating)
            }
        }
        .background(SWPTheme.Colors.background)
        .background(shortcutSink)
        // The hidden title bar still contributes a top safe-area inset, and
        // the layout used to start below it: the panes' *backgrounds* bled to
        // the window's top edge but the sidebar divider — a Rectangle in the
        // layout, not a background — stopped an inch short. Claim the full
        // height and let the headers' own top padding clear the traffic
        // lights, which is what that padding was sized for anyway.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $engine.isConfirming) {
            SWPConfirmSheet()
                .environmentObject(engine)
        }
        .onChange(of: engine.destination) { oldValue, newValue in
            if oldValue == .storage, newValue != .storage { storage.cancel() }
        }
        .onChange(of: engine.result.aiInventory?.scannedAt) { _, _ in
            if let snapshot = engine.result.aiInventory { localAI.acceptInventory(snapshot) }
        }
        .onChange(of: localAI.additionalFolders) { _, folders in
            engine.additionalAIFolders = folders
        }
        .onChange(of: uninstaller.isUninstalling) { _, active in
            if !active { engine.refreshRestorable() }
        }
        .onChange(of: localAI.isRemoving) { _, active in
            if !active { engine.refreshRestorable() }
        }
        .onAppear { engine.refreshRestorable() }
    }

    // MARK: Main pane

    @ViewBuilder
    private var mainPane: some View {
        switch engine.destination {
        case .storage:
            SWPStorageView(store: storage)
        case .localAI:
            SWPLocalAIView(store: localAI)
        case .privacy:
            SWPPrivacyView(store: privacy)
        case .uninstaller:
            SWPUninstallView(onOpenLocalAI: {
                localAI.showsCleanup = true
                openLocalAI()
            })
        case .cleanup:
            switch engine.phase {
            case .idle, .scanning:
                SWPScanHeroView()
            case .results, .removing:
                SWPResultsView(onOpenLocalAI: {
                localAI.showsCleanup = false
                openLocalAI()
            })
            }
        }
    }

    private func openLocalAI() {
        guard !isMutationInProgress else { return }
        engine.destination = .localAI
    }

    /// Zero-sized buttons that exist only to own keyboard shortcuts.
    ///
    /// SwiftUI attaches a shortcut to a control, and Sweep's sidebar rows are
    /// already buttons with their own click behaviour — hanging ⌘1…⌘5 on them
    /// would fire the shortcut from whichever row happened to be in the view
    /// tree. A hidden sink keeps the bindings in one place.
    private var shortcutSink: some View {
        ZStack {
            ForEach(Array(SWPCategory.allCases.enumerated()), id: \.element) { index, category in
                Button("") { engine.destination = .cleanup(category) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { engine.destination = .uninstaller }
                .keyboardShortcut("u", modifiers: .command)
            Button("") { engine.destination = .privacy }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { refreshCurrentTool() }
                .keyboardShortcut("r", modifiers: .command)
        }
        .disabled(isMutationInProgress)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func refreshCurrentTool() {
        guard !isMutationInProgress else { return }
        switch engine.destination {
        case .storage: storage.refresh()
        case .localAI: Task { await localAI.refresh() }
        case .privacy: Task { await privacy.refresh() }
        case .uninstaller: uninstaller.refreshApps()
        case .cleanup: engine.scan()
        }
    }

    private func recoveryBar(folder: URL) -> some View {
        HStack(spacing: SWPTheme.Spacing.row) {
            Text("Recover files from the latest Trash batch.")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(engine.isRestoring ? "Restoring" : "Restore Last Batch") {
                guard !isMutationInProgress, !engine.isConfirming else { return }
                engine.destination = .cleanup(.leftovers)
                engine.restore(from: folder)
            }
            .buttonStyle(SWPSecondaryButtonStyle())
            .fixedSize()
            .help("Restore supported files from \(folder.lastPathComponent). Existing files are never overwritten.")
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.vertical, 8)
        .background(SWPTheme.Colors.surface)
    }

    // MARK: Action bar

    private var actionBar: some View {
        let summary = engine.selectionSummary
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: SWPTheme.Spacing.section) {
                selectionSummary(summary).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: SWPTheme.Spacing.section)
                actionButtons(summary).fixedSize()
            }
            VStack(alignment: .leading, spacing: SWPTheme.Spacing.row) {
                selectionSummary(summary)
                HStack {
                    Spacer(minLength: 0)
                    actionButtons(summary).fixedSize()
                }
            }
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.vertical, 12)
        .background(SWPTheme.Colors.surface)
    }

    private func actionButtons(_ summary: SWPScanEngine.SelectionSummary) -> some View {
        HStack(spacing: SWPTheme.Spacing.row) {
            if engine.result.trashBytes > 0 {
                Button {
                    engine.revealTrash()
                } label: {
                    Label("Trash \(SWPBytes.string(engine.result.trashBytes))",
                          systemImage: "trash")
                }
                .buttonStyle(SWPSecondaryButtonStyle())
                .help("Open the Trash in Finder")
            }

            if summary.hasUnselectedSafeShown {
                Button("Select Safe Shown") { engine.selectAllSafe() }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .help("Select only Safe groups shown in this category. Hidden groups and other evidence tiers are left unchanged.")
            }

            Button("Rescan") { engine.scan() }
                .buttonStyle(SWPSecondaryButtonStyle())
                .disabled(engine.phase == .removing)

            let isRemoving = engine.phase == .removing
            let isEmpty = summary.itemCount == 0
            Button {
                engine.confirmRemoval()
            } label: {
                Text(isRemoving ? "Removing"
                     : isEmpty ? "Nothing Selected" : "Move to Trash")
            }
            .buttonStyle(SWPPrimaryButtonStyle(isEnabled: !isEmpty && !isRemoving))
            .disabled(isEmpty || isRemoving)
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private func selectionSummary(_ summary: SWPScanEngine.SelectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                let bytes = SWPBytes.split(summary.bytes)
                let tint = summary.itemCount == 0 ? SWPTheme.Colors.textDim : SWPTheme.Colors.accent

                Text(bytes.value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                Text(bytes.unit)
                    .font(SWPTheme.Fonts.heroUnit)
                    .foregroundStyle(tint)
                    .padding(.trailing, 3)

                Text(summary.itemCount == 1
                     ? "1 item selected" : "\(summary.itemCount) items selected")
                    .font(SWPTheme.Fonts.caption)
                    .foregroundStyle(SWPTheme.Colors.textDim)
                if summary.needsAdmin {
                    SWPBadge(text: "Admin", tint: SWPTheme.Colors.review)
                }
            }

            if summary.hiddenGroupCount > 0 {
                HStack(spacing: 8) {
                    SWPBadge(text: "\(summary.hiddenGroupCount) group\(summary.hiddenGroupCount == 1 ? "" : "s") outside this view",
                             tint: SWPTheme.Colors.review)
                        .help("Selected groups in another category or hidden by filters. They remain included in the removal review.")
                    Button("Deselect Hidden") { engine.deselectHidden() }
                        .buttonStyle(.plain)
                        .font(SWPTheme.Fonts.caption)
                        .foregroundStyle(SWPTheme.Colors.textSecondary)
                        .disabled(engine.phase == .removing)
                }
            }
        }
    }
}
