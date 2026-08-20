import Foundation
import AppKit
import os

// MARK: - Uninstall store

/// State for the uninstaller pane: the app list, the residue plan for the
/// selected app, tick state, and the removal itself.
///
/// Separate from `SWPScanEngine` on purpose — the two flows share the removal
/// service and the safety policy but nothing about their state, and one store
/// with two half-related state machines was how selection bugs happened in an
/// earlier sketch of the scan flow.
@MainActor
final class SWPUninstallStore: ObservableObject {

    private let log = Logger(subsystem: "com.gasanache.sweep", category: "uninstall")

    // MARK: Published state

    @Published private(set) var apps: [SWPInstalledApp] = []
    @Published private(set) var isLoadingApps = false
    @Published private(set) var runningBundleIDs: Set<String> = []
    @Published var query = ""

    @Published private(set) var plan: SWPUninstallPlan?
    @Published private(set) var isBuildingPlan = false
    @Published private(set) var isUninstalling = false
    @Published var tickedIDs: Set<String> = []
    @Published var isConfirming = false
    @Published private(set) var statusMessage: String?

    private let removal = SWPRemovalService()

    // MARK: App list

    var filteredApps: [SWPInstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func loadAppsIfNeeded() {
        guard apps.isEmpty, !isLoadingApps else { return }
        isLoadingApps = true
        refreshRunning()
        Task.detached(priority: .userInitiated) {
            let list = SWPInstalledApps.list()
            await MainActor.run { [weak self] in
                self?.apps = list
                self?.isLoadingApps = false
            }
        }
    }

    func refreshRunning() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier?.lowercased() })
    }

    func isRunning(_ app: SWPInstalledApp) -> Bool {
        !app.bundleID.isEmpty && runningBundleIDs.contains(app.bundleID)
    }

    // MARK: Plan

    func select(_ app: SWPInstalledApp) {
        guard !isBuildingPlan, !isUninstalling else { return }
        isBuildingPlan = true
        statusMessage = nil
        refreshRunning()
        Task.detached(priority: .userInitiated) {
            let plan = SWPResidueFinder(app: app).buildPlan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.plan = plan
                // The documented exception to zero-auto-selection: the user
                // explicitly picked this app, so its provably-exclusive files
                // start ticked — that is the product. Name matches never do.
                self.tickedIDs = Set(plan.exclusive.map(\.id))
                self.isBuildingPlan = false
            }
        }
    }

    /// Ignored mid-uninstall: the removal operates on the plan it captured,
    /// and yanking the visible plan out from under the progress state would
    /// leave the pane showing the picker while files are still moving.
    func clearPlan() {
        guard !isUninstalling else { return }
        plan = nil
        tickedIDs = []
        isConfirming = false
    }

    func toggle(_ item: SWPItem) {
        guard !isUninstalling else { return }
        if tickedIDs.contains(item.id) {
            tickedIDs.remove(item.id)
        } else {
            tickedIDs.insert(item.id)
        }
    }

    var tickedItems: [SWPItem] {
        guard let plan else { return [] }
        return (plan.exclusive + plan.nameMatches).filter { tickedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        (plan?.appItem.sizeBytes ?? 0) + tickedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectionNeedsAdmin: Bool {
        tickedItems.contains { $0.requiresAdmin }
    }

    // MARK: Uninstall

    func performUninstall() {
        guard let plan, !isUninstalling else { return }
        isConfirming = false
        isUninstalling = true
        let items = SWPRemovalService.prunedOfDescendants(tickedItems)

        Task { @MainActor in
            defer { isUninstalling = false }

            // Never pull a running app's bundle out from under it: ask it to
            // quit and wait. If it refuses, stop — the user can close it and
            // try again, which beats a half-removed live application.
            if let running = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier?.lowercased() == plan.app.bundleID
                    && !plan.app.bundleID.isEmpty }) {
                running.terminate()
                for _ in 0..<25 where !running.isTerminated {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard running.isTerminated else {
                    statusMessage = "\(plan.app.name) wouldn't quit. Close it, then try again."
                    refreshRunning()
                    return
                }
            }

            // Off the main actor: the trash loop and the admin password
            // prompt are blocking, and "Working…" must actually render while
            // they run.
            let removal = self.removal
            let bundleItem = plan.appItem
            let outcome = await Task.detached(priority: .userInitiated) {
                removal.uninstall(bundle: bundleItem, residues: items)
            }.value
            log.info("uninstall \(plan.app.name, privacy: .public): \(outcome.trashedCount) items, \(outcome.trashedBytes) bytes")

            let bundleGone = !FileManager.default.fileExists(atPath: plan.app.url.path)
            if outcome.adminCancelled, !bundleGone {
                statusMessage = "Authorisation was cancelled — nothing was removed."
            } else if bundleGone {
                let count = outcome.trashedCount
                var message = "Moved \(plan.app.name) to the Trash — \(count) item\(count == 1 ? "" : "s"), \(SWPBytes.string(outcome.trashedBytes)). Recoverable until you empty the Trash."
                if outcome.adminCancelled {
                    message += " System-level files were skipped (authorisation cancelled)."
                }
                statusMessage = message
                apps.removeAll { $0.id == plan.app.id }
                isUninstalling = false   // must precede clearPlan's guard
                clearPlan()
            } else if let failure = outcome.failures.first {
                statusMessage = "Couldn't remove \(plan.app.name): \(failure.reason)"
            } else if let refused = outcome.refusedByPolicy.first {
                statusMessage = "The safety policy refused \(refused)."
            } else {
                statusMessage = "The app could not be moved to the Trash."
            }
            refreshRunning()
        }
    }
}
