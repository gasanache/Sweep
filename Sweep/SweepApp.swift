import SwiftUI

// MARK: - App

@main
struct SweepApp: App {

    /// One engine and one uninstall store for the process, owned here and
    /// injected downward, matching the `@StateObject` at the root /
    /// `@EnvironmentObject` below pattern used across these projects.
    @StateObject private var engine = SWPScanEngine()
    @StateObject private var uninstaller = SWPUninstallStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Sweep", id: "main") {
            SWPRootView()
                .environmentObject(engine)
                .environmentObject(uninstaller)
                .frame(minWidth: 820, minHeight: 560)
                // Dark only. The palette is built for a near-black ground and a
                // single warm accent; rendered light it loses the contrast that
                // makes the confidence tints legible.
                .preferredColorScheme(.dark)
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
        }

        Window("About Sweep", id: "about") {
            SWPAboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
