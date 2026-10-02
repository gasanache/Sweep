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
    @Published private(set) var isMeasuringSizes = false
    @Published var selectedAppID: String?
    private var hasLoadedApps = false
    private var inventoryGeneration = 0
    private var inventoryTask: Task<Void, Never>?
    private let loadApps: @Sendable () -> [SWPInstalledApp]
    private let measureApps: @Sendable ([SWPInstalledApp]) -> [String: Int64]
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
    @Published private(set) var lastOutcome: SWPRemovalOutcome?

    private let buildPlan: @Sendable (SWPInstalledApp) -> SWPUninstallPlan
    private let removePlan: @Sendable (SWPUninstallPlan, [SWPItem]) -> SWPRemovalOutcome
    private var planTask: Task<Void, Never>?

    init(buildPlan: @escaping @Sendable (SWPInstalledApp) -> SWPUninstallPlan = { SWPResidueFinder(app: $0).buildPlan() },
         removePlan: (@Sendable (SWPUninstallPlan, [SWPItem]) -> SWPRemovalOutcome)? = nil,
         loadApps: @escaping @Sendable () -> [SWPInstalledApp] = { SWPInstalledApps.list() },
         measureApps: @escaping @Sendable ([SWPInstalledApp]) -> [String: Int64] = { apps in
             let sizes = SWPDiskSize.sizes(of: apps.map(\.url))
             return Dictionary(uniqueKeysWithValues: zip(apps.map(\.id), sizes))
         }) {
        self.loadApps = loadApps
        self.measureApps = measureApps
        self.buildPlan = buildPlan
        self.removePlan = removePlan ?? { plan, items in
            let removal = SWPRemovalService()
            if plan.bundleAlreadyTrashed {
                var outcome = removal.trash(items)
                outcome.merge(removal.trashWithAuthorisation(items))
                return outcome
            }
            return removal.uninstall(bundle: plan.appItem, residues: items)
        }
    }
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
        guard !hasLoadedApps else { return }
        refreshApps()
    }

    /// Refresh only the picker. Never replace or silently rebuild a reviewed plan.
    func refreshApps() {
        guard !isLoadingApps, !isBuildingPlan, !isUninstalling, !isConfirming, plan == nil else { return }
        inventoryGeneration += 1
        let generation = inventoryGeneration
        inventoryTask?.cancel()
        isLoadingApps = true
        isMeasuringSizes = false
        refreshRunning()
        let load = loadApps
        let measure = measureApps
        inventoryTask = Task { [weak self] in
            let list = await Task.detached(priority: .userInitiated) { load() }.value
            guard let self, self.inventoryGeneration == generation, !Task.isCancelled else { return }
            self.apps = list
            self.hasLoadedApps = true
            self.isLoadingApps = false
            if let selected = self.selectedAppID, !list.contains(where: { $0.id == selected }) {
                self.selectedAppID = nil
            }
            self.appSizes = self.appSizes.filter { entry in list.contains { $0.id == entry.key } }
            self.isMeasuringSizes = true
            let sizes = await Task.detached(priority: .utility) { measure(list) }.value
            guard self.inventoryGeneration == generation, !Task.isCancelled else { return }
            self.appSizes = sizes
            self.isMeasuringSizes = false
            self.inventoryTask = nil
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
        startPlan(for: app, alreadyTrashed: false)
    }

    /// Builds a plan for an app that is *already* in the Trash.
    ///
    /// The bundle is deliberately excluded from the tick set: the user has
    /// already dealt with it, and re-offering it would be confusing. Only the
    /// residue is on the table.
    func selectTrashedApp(_ app: SWPInstalledApp) {
        startPlan(for: app, alreadyTrashed: true)
    }

    private func startPlan(for app: SWPInstalledApp, alreadyTrashed: Bool) {
        guard !isBuildingPlan, !isUninstalling else { return }
        planToken += 1
        let token = planToken
        isBuildingPlan = true
        plan = nil
        tickedIDs = []
        isConfirming = false
        statusMessage = nil
        lastOutcome = nil
        refreshRunning()
        let buildPlan = self.buildPlan
        planTask = Task.detached(priority: .userInitiated) { [weak self] in
            var plan = buildPlan(app)
            plan.bundleAlreadyTrashed = alreadyTrashed
            guard !Task.isCancelled else { return }
            let completed = plan
            await MainActor.run { [weak self] in
                guard let self, self.planToken == token, !self.isUninstalling else { return }
                self.plan = completed
                // Only an explicitly chosen installed app gets exclusive files
                // preselected. A Trash-watcher suggestion never does.
                self.tickedIDs = alreadyTrashed ? [] : Set(completed.exclusive.map(\.id))
                self.isBuildingPlan = false
                self.planTask = nil
            }
        }
    }

    /// Ignored mid-uninstall: the removal operates on the plan it captured,
    /// and yanking the visible plan out from under the progress state would
    /// leave the pane showing the picker while files are still moving.
    func clearPlan() {
        guard !isUninstalling else { return }
        planToken += 1          // orphan any build still in flight
        planTask?.cancel()
        planTask = nil
        isBuildingPlan = false
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
        guard let plan, !isUninstalling, !isBuildingPlan else { return }
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
            let removePlan = self.removePlan
            let bundleItem = plan.appItem
            let residueOnly = plan.bundleAlreadyTrashed
            if !residueOnly {
                // Tell the Trash watcher this bundle is ours, before the move,
                // so it does not turn round and offer to clean up after the
                // uninstall that is happening right now.
                NotificationCenter.default.post(name: SWPTrashWatcher.didTrashBundle,
                                                object: bundleItem.url.lastPathComponent)
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                removePlan(plan, items)
            }.value
            log.info("uninstall \(plan.app.name, privacy: .public): \(outcome.trashedCount) items, \(outcome.trashedBytes) bytes")

            recordOutcome(outcome, for: plan)
            refreshRunning()
        }
    }

    private func recordOutcome(_ outcome: SWPRemovalOutcome, for reviewed: SWPUninstallPlan) {
        lastOutcome = outcome
        let bundleGone = reviewed.bundleAlreadyTrashed
            || !FileManager.default.fileExists(atPath: reviewed.app.url.path)
        var details = outcome.failures.map { "\($0.path): \($0.reason)" }
            + outcome.refusedByPolicy.map { "Safety policy refused: \($0)" }
        if outcome.adminCancelled { details.append("Administrator authorization was cancelled; remaining files were not moved.") }
        if !bundleGone { details.append("The application is still installed.") }
        let summary = "Moved \(outcome.trashedCount) item\(outcome.trashedCount == 1 ? "" : "s") (\(SWPBytes.string(outcome.trashedBytes))) to the Trash for \(reviewed.app.name)."
        statusMessage = ([summary] + details).joined(separator: "\n")
        if bundleGone { apps.removeAll { $0.id == reviewed.app.id } }

        func exists(_ item: SWPItem) -> Bool {
            // Include dangling links as remaining, refused work as well.
            (try? FileManager.default.attributesOfItem(atPath: item.url.path)) != nil
        }
        let remaining = SWPUninstallPlan(app: reviewed.app, appItem: reviewed.appItem,
            exclusive: reviewed.exclusive.filter(exists), nameMatches: reviewed.nameMatches.filter(exists),
            shared: reviewed.shared, bundleAlreadyTrashed: bundleGone, receipts: reviewed.receipts)
        tickedIDs.formIntersection(Set((remaining.exclusive + remaining.nameMatches).map(\.id)))
        if bundleGone, details.isEmpty, tickedIDs.isEmpty {
            isUninstalling = false
            clearPlan()
        } else {
            plan = remaining
        }
    }
}
