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
    /// Bundle sizes, filled in lazily after the list appears.
    @Published private(set) var appSizes: [String: Int64] = [:]
    @Published var sortOrder: SortOrder = .name

    enum SortOrder: String, CaseIterable, Identifiable {
        case name, size, lastUsed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name:     return "Name"
            case .size:     return "Size"
            case .lastUsed: return "Last used"
            }
        }
    }

    @Published private(set) var plan: SWPUninstallPlan?
    @Published private(set) var isBuildingPlan = false
    @Published private(set) var isUninstalling = false
    @Published var tickedIDs: Set<String> = []
    @Published var isConfirming = false
    @Published private(set) var statusMessage: String?

    private let removal = SWPRemovalService()
    /// Identifies the plan build in flight. The detached build used to write
    /// `plan`/`tickedIDs` on completion with only a `guard let self`, so a
    /// slower first build could land on top of a newer one — or repopulate a
    /// plan the user had already dismissed with Back.
    private var planToken = 0

    // MARK: App list

    var filteredApps: [SWPInstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
        switch sortOrder {
        case .name:
            return base
        case .size:
            // Unsized apps sort last rather than as zero, so the list does not
            // reshuffle wildly while sizes stream in.
            return base.sorted { (appSizes[$0.id] ?? -1) > (appSizes[$1.id] ?? -1) }
        case .lastUsed:
            return base.sorted {
                ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast)
            }
        }
    }

    func size(of app: SWPInstalledApp) -> Int64? { appSizes[app.id] }

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
            // Sizes come second, at utility priority: measuring 70 bundles
            // takes seconds, and the list must be usable immediately.
            let sizes = SWPDiskSize.sizes(of: list.map(\.url))
            let mapped = Dictionary(uniqueKeysWithValues: zip(list.map(\.id), sizes))
            await MainActor.run { [weak self] in
                self?.appSizes = mapped
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
        planToken += 1
        let token = planToken
        isBuildingPlan = true
        statusMessage = nil
        refreshRunning()
        Task.detached(priority: .userInitiated) {
            let plan = SWPResidueFinder(app: app).buildPlan()
            await MainActor.run { [weak self] in
                guard let self, self.planToken == token, !self.isUninstalling else { return }
                self.plan = plan
                // The documented exception to zero-auto-selection: the user
                // explicitly picked this app, so its provably-exclusive files
                // start ticked — that is the product. Name matches never do.
                self.tickedIDs = Set(plan.exclusive.map(\.id))
                self.isBuildingPlan = false
            }
        }
    }

    /// Builds a plan for an app that is *already* in the Trash.
    ///
    /// The bundle is deliberately excluded from the tick set: the user has
    /// already dealt with it, and re-offering it would be confusing. Only the
    /// residue is on the table.
    func selectTrashedApp(_ app: SWPInstalledApp) {
        guard !isBuildingPlan, !isUninstalling else { return }
        planToken += 1
        let token = planToken
        isBuildingPlan = true
        statusMessage = nil
        Task.detached(priority: .userInitiated) {
            var plan = SWPResidueFinder(app: app).buildPlan()
            plan.bundleAlreadyTrashed = true
            await MainActor.run { [weak self] in
                guard let self, self.planToken == token, !self.isUninstalling else { return }
                self.plan = plan
                // Nothing is pre-ticked here. The documented exception to
                // zero-auto-selection is justified by the user choosing an app
                // in the uninstaller; a prompt they did not ask for is not
                // that, and the identity came from a bundle already in the
                // Trash rather than one they pointed at.
                self.tickedIDs = []
                self.isBuildingPlan = false
            }
        }
    }

    /// Ignored mid-uninstall: the removal operates on the plan it captured,
    /// and yanking the visible plan out from under the progress state would
    /// leave the pane showing the picker while files are still moving.
    func clearPlan() {
        guard !isUninstalling else { return }
        planToken += 1          // orphan any build still in flight
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
        let bundle = (plan?.bundleAlreadyTrashed == true) ? 0 : (plan?.appItem.sizeBytes ?? 0)
        return bundle + tickedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectionNeedsAdmin: Bool {
        tickedItems.contains { $0.requiresAdmin }
    }

    // MARK: Uninstall

    func performUninstall() {
        guard let plan, !isUninstalling else { return }
        if plan.bundleAlreadyTrashed, tickedItems.isEmpty {
            statusMessage = "Nothing selected — tick the leftovers you want removed."
            isConfirming = false
            return
        }
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
            let residueOnly = plan.bundleAlreadyTrashed
            if !residueOnly {
                // Tell the Trash watcher this bundle is ours, before the move,
                // so it does not turn round and offer to clean up after the
                // uninstall that is happening right now.
                NotificationCenter.default.post(name: SWPTrashWatcher.didTrashBundle,
                                                object: bundleItem.url.lastPathComponent)
            }
            let outcome = await Task.detached(priority: .userInitiated) { () -> SWPRemovalOutcome in
                // A bundle already in the Trash is not ours to move — and the
                // app-bundle gate would refuse a path inside ~/.Trash, which
                // would surface as a policy error for an action the user never
                // asked for. Residue only.
                if residueOnly {
                    var outcome = removal.trash(items)
                    if items.contains(where: { $0.requiresAdmin }) {
                        outcome.merge(removal.trashWithAuthorisation(items))
                    }
                    return outcome
                }
                return removal.uninstall(bundle: bundleItem, residues: items)
            }.value
            log.info("uninstall \(plan.app.name, privacy: .public): \(outcome.trashedCount) items, \(outcome.trashedBytes) bytes")

            let bundleGone = residueOnly
                ? outcome.trashedCount > 0
                : !FileManager.default.fileExists(atPath: plan.app.url.path)
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
