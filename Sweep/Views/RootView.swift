import SwiftUI

// MARK: - Root

/// Window shell: sidebar, main pane, action bar.
///
/// One window, no tabs, no inspector. The whole product is a three-step
/// sequence — scan, review, trash — and every extra surface would be somewhere
/// for that sequence to get lost.
struct SWPRootView: View {

    @EnvironmentObject private var engine: SWPScanEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SWPSidebarView()
                    .frame(width: SWPTheme.Spacing.sidebarWidth)

                Rectangle()
                    .fill(SWPTheme.Colors.border)
                    .frame(width: 1)

                mainPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if engine.hasResults, !engine.isUninstallerActive {
                SWPHairline()
                actionBar
            }
        }
        .background(SWPTheme.Colors.background)
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
        .onAppear {
            // Debug affordances for headless UI verification: land on a
            // specific pane or state without clicking, so every screen can be
            // exercised and screenshotted from the command line.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--uninstaller") {
                engine.isUninstallerActive = true
            } else if arguments.contains("--scan") {
                engine.scan()
            } else if arguments.contains("--about") {
                openWindow(id: "about")
            }
        }
    }

    // MARK: Main pane

    @ViewBuilder
    private var mainPane: some View {
        if engine.isUninstallerActive {
            SWPUninstallView()
        } else {
            switch engine.phase {
            case .idle, .scanning:
                SWPScanHeroView()
            case .results, .removing:
                SWPResultsView()
            }
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: SWPTheme.Spacing.row) {
            selectionSummary

            Spacer(minLength: SWPTheme.Spacing.section)

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

            if engine.hasUnselectedSafeGroups {
                Button("Select Safe") { engine.selectAllSafe() }
                    .buttonStyle(SWPSecondaryButtonStyle())
                    .help("Tick every group marked Safe — rebuildable data with no installed owner. In Use, Orphaned and Review groups are never batch-selected.")
            }

            Button("Rescan") { engine.scan() }
                .buttonStyle(SWPSecondaryButtonStyle())
                .disabled(engine.phase == .removing)

            let isRemoving = engine.phase == .removing
            Button {
                engine.confirmRemoval()
            } label: {
                Text(isRemoving ? "Removing…"
                     : engine.selectedItems.isEmpty ? "Nothing Selected" : "Move to Trash")
            }
            .buttonStyle(SWPPrimaryButtonStyle(isEnabled: !engine.selectedItems.isEmpty && !isRemoving))
            .disabled(engine.selectedItems.isEmpty || isRemoving)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, SWPTheme.Spacing.pane)
        .padding(.vertical, 12)
        .background(SWPTheme.Colors.surface)
    }

    private var selectionSummary: some View {
        HStack(spacing: 7) {
            let bytes = SWPBytes.split(engine.selectedBytes)

            Text(bytes.value)
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(engine.selectedItems.isEmpty
                                 ? SWPTheme.Colors.textDim : SWPTheme.Colors.accent)
            Text(bytes.unit)
                .font(SWPTheme.Fonts.heroUnit)
                .foregroundStyle(engine.selectedItems.isEmpty
                                 ? SWPTheme.Colors.textDim : SWPTheme.Colors.accent)
                .padding(.trailing, 3)

            Text(engine.selectedItems.count == 1
                 ? "1 item selected" : "\(engine.selectedItems.count) items selected")
                .font(SWPTheme.Fonts.caption)
                .foregroundStyle(SWPTheme.Colors.textDim)

            if engine.selectionNeedsAdmin {
                SWPBadge(text: "Admin", tint: SWPTheme.Colors.review)
            }
        }
    }
}
