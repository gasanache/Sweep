import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - App

@main
struct SweepApp: App {

    /// One engine and one uninstall store for the process, owned here and
    /// injected downward, matching the `@StateObject` at the root /
    /// `@EnvironmentObject` below pattern used across these projects.
    @StateObject private var engine = SWPScanEngine()
    @StateObject private var uninstaller = SWPUninstallStore()
    @StateObject private var trashWatcher = SWPTrashWatcher()
    @AppStorage(SWPSettings.watchTrashKey) private var watchTrash = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SWPSettings.appearanceKey) private var appearance = SWPAppearance.system

    var body: some Scene {
        Window("Sweep", id: "main") {
            SWPRootView()
                .environmentObject(engine)
                .environmentObject(uninstaller)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    appearance.apply()
                    trashWatcher.syncWithPreference()
                }
                .onChange(of: appearance) { _, newValue in newValue.apply() }
                .onChange(of: watchTrash) { _, _ in trashWatcher.syncWithPreference() }
                .alert("Clean up after \(trashWatcher.pending?.app.name ?? "")?",
                       isPresented: Binding(get: { trashWatcher.pending != nil },
                                            set: { if !$0 { trashWatcher.dismiss() } })) {
                    Button("Not Now", role: .cancel) { trashWatcher.dismiss() }
                    Button("Review Leftovers") {
                        if let caught = trashWatcher.pending {
                            engine.isUninstallerActive = true
                            uninstaller.selectTrashedApp(caught.app)
                        }
                        trashWatcher.dismiss()
                    }
                } message: {
                    Text("You moved this app to the Trash. Sweep can show the support files it left behind in your Library — the app itself is already handled.")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 940, height: 640)
        .commands {
            // The template's New Window entry makes no sense for a
            // single-window utility, and the stock grey About panel is
            // replaced by our own window below.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About Sweep") { openWindow(id: "about") }
            }
            CommandGroup(after: .saveItem) {
                Button("Export Diagnostics…") { exportDiagnostics() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Window("About Sweep", id: "about") {
            SWPAboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SWPSettingsView()
                .environmentObject(engine)
        }
        .windowResizability(.contentSize)
    }

    // MARK: Diagnostics

    /// Writes a plain-text report of the last scan to a file the user picks.
    /// Never sent anywhere — the user hands it to whoever needs it.
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sweep-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = SWPDiagnostics.report(result: engine.result,
                                         healthyStartup: engine.healthyStartupItems,
                                         ignoredCount: engine.ignoredCount,
                                         lastOutcome: engine.lastOutcome)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
