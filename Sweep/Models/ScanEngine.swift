import Foundation
import SwiftUI
import AppKit
import os

// MARK: - Phase

enum SWPPhase: Equatable {
    case idle
    case scanning(String)
    case results
    case removing
}

// MARK: - Scan stages

/// The five stages a scan moves through, in order.
///
/// Named rather than a bare percentage because "Scanning Caches" tells the
/// user something a spinner cannot: which part of their disk is being read,
/// and therefore why it is taking as long as it is.
enum SWPScanStage: Int, CaseIterable, Identifiable {
    case inventory, leftovers, developer, disposable, startup

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .inventory:  return "Inventory"
        case .leftovers:  return "Leftovers"
        case .developer:  return "Developer"
        case .disposable: return "Caches & Logs"
        case .startup:    return "Startup"
        }
    }
}

// MARK: - Sort order

enum SWPSortOrder: String, CaseIterable, Identifiable {
    case evidence, size, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .evidence: return "Evidence"
        case .size:     return "Size"
        case .name:     return "Name"
        }
    }
}

// MARK: - Scan engine

/// The app's single source of truth: owns the scan, the selection and the
/// removal, and publishes everything the views render.
///
/// One store rather than a view model per screen. The three screens are three
/// states of one workflow, not independent surfaces, and splitting them meant
/// selection state had to be threaded between objects that could disagree
/// about which scan it belonged to.
@MainActor
final class SWPScanEngine: ObservableObject {

    private let log = Logger(subsystem: "com.gasanache.sweep", category: "engine")

    // MARK: Published state

    @Published private(set) var phase: SWPPhase = .idle
    @Published private(set) var result = SWPScanResult()
    @Published private(set) var healthyStartupItems: [SWPStartupEntry] = []
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var lastOutcome: SWPRemovalOutcome?
    /// Stage currently running, and the stages already finished. Drives the
    /// segmented progress under the ring.
    @Published private(set) var currentStage: SWPScanStage = .inventory
    @Published private(set) var completedStages: Set<SWPScanStage> = []
    /// True while a rescan is running over results that are still on screen.
    /// Lets the results view stay put instead of blanking — a rescan that
    /// empties the window makes the app feel like it lost your work.
    @Published private(set) var isRescanning = false

    var stageProgress: Double {
        Double(completedStages.count) / Double(SWPScanStage.allCases.count)
    }

    @Published var selectedCategory: SWPCategory = .leftovers
    /// Whether the main pane shows the uninstaller instead of scan content.
    /// UI-navigation state, held here because the engine is the window's root
    /// store; the uninstaller's own data lives in `SWPUninstallStore`.
    @Published var isUninstallerActive = false
    /// Free-text filter over the results list (3.1). Matches group names and
    /// the paths inside them, so searching "chrome" finds a group whose title
    /// is a vendor but whose paths say Chrome.
    @Published var query = ""
    @Published var sortOrder: SWPSortOrder = .evidence
    @Published var selectedGroupIDs: Set<String> = []
    @Published var expandedGroupIDs: Set<String> = []
    @Published var isConfirming = false

    /// Mirrored into engine state so the views actually refresh.
    ///
    /// `SWPIgnoreList` is its own `ObservableObject`, but nothing observed it:
    /// a plain `let` on the engine publishes nothing when the nested object
    /// changes, so the ignored count and the Stop Ignoring buttons never
    /// updated until some unrelated redraw happened to occur.
    @Published private(set) var ignoredPathList: [String] = []
    let ignoreList = SWPIgnoreList()
    private let removal = SWPRemovalService()
    private var scanTask: Task<Void, Never>?
    /// Monotonic scan identity. A cancelled scan's detached work keeps
    /// running, and its progress callbacks arrive on the main actor *after*
    /// the cancellation — without this stamp, a stale callback could flip the
    /// UI back to "Scanning …" with no scan alive to ever end it. Every
    /// callback and completion checks the generation it was born with.
    private var scanGeneration = 0
    /// Accumulates streamed stages. Main-actor state rather than a local of
    /// the scan task: the stage callbacks run on the main actor, so a local
    /// would be mutated from five separate contexts while the scan task read
    /// it — a real race that let `healthyStartup` come back empty on a fast
    /// scan, not merely a compiler complaint.
    private var streamedResult = SWPScanResult()

    init() { ignoredPathList = ignoreList.paths.sorted() }

    // MARK: Derived

    var selectedGroups: [SWPGroup] {
        result.groups.filter { selectedGroupIDs.contains($0.id) }
    }

    var selectedItems: [SWPItem] {
        selectedGroups.flatMap(\.items)
    }

    var selectedBytes: Int64 {
        selectedGroups.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectionNeedsAdmin: Bool {
        selectedGroups.contains { $0.requiresAdmin }
    }

    var hasResults: Bool { !result.groups.isEmpty }

    /// Selected groups the current filter is hiding.
    ///
    /// Selection deliberately survives filtering — typing in the search box
    /// should not silently untick your work — but that means the action bar can
    /// read "12 items selected" over a list showing two rows. The count stays
    /// accurate and the UI says how many are out of sight, rather than quietly
    /// letting someone trash rows they cannot see.
    var hiddenSelectedCount: Int {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        let visible = Set(SWPCategory.allCases.flatMap { visibleGroups(in: $0).map(\.id) })
        return selectedGroupIDs.subtracting(visible).count
    }

    /// Groups for a category after filtering and sorting.
    ///
    /// `.evidence` keeps the default order defined by `SWPScanResult` (hard
    /// evidence first, then size) — the ordering the tiers exist to express.
    func visibleGroups(in category: SWPCategory) -> [SWPGroup] {
        var groups = result.groups(in: category)

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            groups = groups.filter { group in
                group.name.localizedCaseInsensitiveContains(trimmed)
                    || group.items.contains { $0.url.path.localizedCaseInsensitiveContains(trimmed) }
            }
        }

        switch sortOrder {
        case .evidence: return groups
        case .size:     return groups.sorted { $0.sizeBytes > $1.sizeBytes }
        case .name:     return groups.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        }
    }

    // MARK: Scanning

    /// Set when a rescan is asked for while one is already running, so the
    /// request is honoured on completion instead of silently dropped. Several
    /// callers (clearing the ignore list, restoring, disabling a startup item)
    /// depend on the rescan actually happening to reconcile what they changed.
    private var rescanPending = false

    func scan() {
        guard phase != .removing else { return }
        guard scanTask == nil else {
            rescanPending = true
            return
        }
        scanGeneration += 1
        let generation = scanGeneration

        // Keep whatever is on screen while a rescan runs (3.6). Only a first
        // scan clears, because there is nothing to preserve.
        isRescanning = hasResults
        streamedResult = SWPScanResult()
        completedStages = []
        currentStage = .inventory
        // A rescan keeps the results pane and its list; only a first scan
        // shows the hero. Setting `.scanning` unconditionally sent the user
        // back to the hero screen and blanked everything — which made the
        // whole "keep results visible" path unreachable.
        if isRescanning {
            phase = .results
        } else {
            result = SWPScanResult()
            phase = .scanning("Taking inventory")
        }
        // Selection survives a rescan. Group ids are path-derived and stable
        // by design, so re-ticking after every side action (clearing the
        // ignore list, restoring, disabling a startup item) was pure loss.
        // Ids that no longer exist are pruned when the scan completes.
        lastOutcome = nil

        let ignored = ignoreList.snapshot()
        // Gathered here because `NSWorkspace` is main-actor work; the inventory
        // itself stays Foundation-only so it still compiles into the tests and
        // the headless harness.
        let running = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier?.lowercased() })

        scanTask = Task { [weak self] in
            await Self.performScan(
                ignored: ignored,
                runningBundleIDs: running,
                // The weak capture is read on each closure's own frame rather
                // than from inside a nested concurrent closure.
                progress: { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.scanGeneration == generation else { return }
                        self.phase = .scanning(message)
                    }
                },
                // `async` so each stage is *awaited* by the scanner before the
                // next one starts. Five main-actor hops per scan, and in
                // exchange every stage is guaranteed applied before the
                // completion block reads the accumulated result (3.5).
                stage: { [weak self] stage, groups, partial in
                    await MainActor.run {
                        guard let self, self.scanGeneration == generation else { return }
                        self.streamedResult.groups += groups
                        self.streamedResult.merge(partial)
                        // During a rescan the old list stays until the new one
                        // has something in it. Publishing the accumulator from
                        // the very first stage — which carries zero groups —
                        // emptied the window the instant a rescan started.
                        if !self.isRescanning || !self.streamedResult.groups.isEmpty {
                            self.result = self.streamedResult
                        }
                        self.completedStages.insert(stage)
                        if self.phase == .removing { return }
                        if let next = SWPScanStage(rawValue: stage.rawValue + 1) {
                            self.currentStage = next
                        }
                        self.isRescanning = false
                    }
                })

            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.healthyStartupItems = self.streamedResult.healthyStartup
            self.lastScanDate = Date()
            // A removal may have started while this scan was running. The
            // scan does not own the phase in that case — overwriting it
            // re-armed "Move to Trash" while files were still moving.
            if self.phase != .removing { self.phase = .results }
            self.isRescanning = false
            self.completedStages = Set(SWPScanStage.allCases)
            let live = Set(self.result.groups.map(\.id))
            self.selectedGroupIDs.formIntersection(live)
            self.scanTask = nil
            self.refreshRestorable()
            if self.rescanPending {
                self.rescanPending = false
                self.scan()
            }
            self.log.info("scan complete: \(self.streamedResult.groups.count) groups, \(self.streamedResult.totalBytes) bytes")
        }
    }

    func cancelScan() {
        // Bumping the generation orphans every callback of the cancelled scan;
        // the handler in `performScan` cancels the detached work for real.
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        isRescanning = false
        phase = result.groups.isEmpty ? .idle : .results
    }

    /// Runs the four scanners off the main actor.
    ///
    /// `detached` rather than a plain `Task`: the engine is `@MainActor`, so an
    /// inherited context would drag several seconds of synchronous filesystem
    /// walking onto the main thread and freeze the window mid-scan.
    /// `Task.detached` deliberately does **not** inherit cancellation — that is
    /// the whole point of detaching — so cancelling `scanTask` left the walk
    /// running to completion and every `Task.isCancelled` check inside the
    /// scanners was dead code. `withTaskCancellationHandler` bridges the two:
    /// the outer task's cancellation explicitly cancels the detached child,
    /// which is what makes those checks fire.
    nonisolated private static func performScan(
        ignored: Set<String>,
        runningBundleIDs: Set<String>,
        progress: @escaping @Sendable (String) -> Void,
        stage: @escaping @Sendable (SWPScanStage, [SWPGroup], SWPScanResult) async -> Void
    ) async {
        let work = Task.detached(priority: .userInitiated) {
            progress("Taking inventory of installed apps")
            let inventory = SWPAppInventory.build(runningBundleIDs: runningBundleIDs)
            var meta = SWPScanResult()
            meta.appsInventoried = inventory.appCount
            meta.inventoryUnreliable = !inventory.isTrustworthy
            await stage(.inventory, [], meta)
            if Task.isCancelled { return }

            var unreadable: [String] = []
            let orphanScanner = SWPOrphanScanner(inventory: inventory)
            let orphanGroups = orphanScanner.scan(unreadable: &unreadable,
                                                  ignored: ignored) { location in
                progress("Scanning \(location)")
            }
            var orphanMeta = SWPScanResult()
            orphanMeta.unreadablePaths = unreadable
            await stage(.leftovers, orphanGroups, orphanMeta)
            if Task.isCancelled { return }

            // Claim orphan paths so the disposable sweep cannot list the same
            // folder twice under a friendlier label.
            var claimed = Set(orphanGroups.flatMap(\.items).map { $0.url.standardizedFileURL.path })

            var junkScanner = SWPJunkScanner(inventory: inventory, claimed: claimed,
                                             ignored: ignored)
            let developerGroups = junkScanner.scanDeveloper(
                emitGroups: SWPSettings.scansDeveloper) { progress("Scanning \($0)") }
            claimed.formUnion(developerGroups.flatMap(\.items).map(\.url.path))
            await stage(.developer, developerGroups, SWPScanResult())
            if Task.isCancelled { return }

            let cacheGroups = junkScanner.scanCaches { progress("Scanning \($0)") }
            let logGroups = junkScanner.scanLogs { progress("Scanning \($0)") }
            await stage(.disposable, cacheGroups + logGroups, SWPScanResult())
            if Task.isCancelled { return }

            progress("Checking startup items")
            let startupScanner = SWPStartupScanner(inventory: inventory)
            let startup = startupScanner.scan(ignored: ignored) { progress("Scanning \($0)") }

            progress("Measuring the Trash")
            var tail = SWPScanResult()
            tail.trashBytes = SWPJunkScanner.trashSize()
            tail.healthyStartup = startup.healthy
            await stage(.startup, startup.groups, tail)
        }

        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: Selection

    // Deliberately no pre-selection of any kind. Earlier versions ticked the
    // "safe" tier automatically; even that turned out to be the wrong default —
    // it handed the user a multi-gigabyte confirmation sheet they had not
    // composed. A scan now ends with zero ticks, and `selectAllSafe()` exists
    // for when the user wants the disposable tier in one explicit click.

    /// Whether the Select Safe shortcut has anything left to add.
    var hasUnselectedSafeGroups: Bool {
        result.groups.contains { $0.confidence == .safe && !selectedGroupIDs.contains($0.id) }
    }

    /// Selects every `.safe` group — ownerless, rebuildable data. Never touches
    /// `.inUse`, `.confirmed` or `.likely`; those are individual decisions.
    func selectAllSafe() {
        selectedGroupIDs.formUnion(
            result.groups.filter { $0.confidence == .safe }.map(\.id)
        )
    }

    func toggle(_ group: SWPGroup) {
        if selectedGroupIDs.contains(group.id) {
            selectedGroupIDs.remove(group.id)
        } else {
            selectedGroupIDs.insert(group.id)
        }
    }

    func toggleExpansion(_ group: SWPGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }

    /// Acts on the *visible* groups: with a filter active, "Select All" must
    /// mean what the user can see, not the whole hidden category.
    func selectAll(in category: SWPCategory) {
        selectedGroupIDs.formUnion(visibleGroups(in: category).map(\.id))
    }

    func deselectAll(in category: SWPCategory) {
        selectedGroupIDs.subtract(visibleGroups(in: category).map(\.id))
    }

    func isSelected(_ group: SWPGroup) -> Bool { selectedGroupIDs.contains(group.id) }

    // MARK: Removal

    func confirmRemoval() {
        guard !selectedItems.isEmpty else { return }
        isConfirming = true
    }

    /// Trashes the current selection, user-level first, then the authorised batch.
    ///
    /// The filesystem work and the admin password prompt run on a detached
    /// task: on the main actor they froze the window for the whole removal,
    /// and — with no suspension point between setting `.removing` and setting
    /// `.results` — the removing state could never even render.
    func performRemoval() {
        isConfirming = false
        guard phase != .removing else { return }
        // Descendants of another selected item vanish with their parent;
        // trashing them afterwards would only manufacture failures.
        let items = SWPRemovalService.prunedOfDescendants(selectedItems)
        guard !items.isEmpty else { return }

        phase = .removing
        let removal = self.removal
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> SWPRemovalOutcome in
                var outcome = removal.trash(items)
                if items.contains(where: { $0.requiresAdmin }) {
                    outcome.merge(removal.trashWithAuthorisation(items))
                }
                return outcome
            }.value

            guard let self else { return }
            self.finishRemoval(with: outcome)
        }
    }

    /// Publishes a removal's outcome and reconciles the list with the disk.
    private func finishRemoval(with outcome: SWPRemovalOutcome) {
        lastOutcome = outcome
        refreshRestorable()
        log.info("removed \(outcome.trashedCount) items, \(outcome.trashedBytes) bytes")

        // Rebuild the list from filesystem truth: keep only rows that still
        // exist. This handles every case at once — pruned descendants that
        // vanished with their parent, admin partial failures, and anything a
        // concurrent process removed — without trusting our own bookkeeping.
        func reconciled(_ groups: [SWPGroup]) -> [SWPGroup] {
            groups.compactMap { group in
                let remaining = group.items.filter {
                    FileManager.default.fileExists(atPath: $0.url.path)
                }
                guard !remaining.isEmpty else { return nil }
                return SWPGroup(id: group.id, name: group.name, category: group.category,
                                confidence: group.confidence, items: remaining)
            }
        }
        result.groups = reconciled(result.groups)
        // The accumulator must be reconciled too: a stage landing after this
        // point would otherwise republish rows that are already in the Trash.
        streamedResult.groups = reconciled(streamedResult.groups)
        selectedGroupIDs = selectedGroupIDs.filter { id in result.groups.contains { $0.id == id } }
        phase = .results

        // Re-measuring the Trash walks every file in it — seconds when it
        // holds tens of thousands — so it happens off the main actor, stamped
        // against the scan generation so a rescan's fresh number cannot be
        // overwritten by this stale one.
        let generation = scanGeneration
        Task.detached(priority: .utility) { [weak self] in
            // The engine is held weakly across the expensive Trash walk — the
            // point of the weak capture — and strongly only for the instant of
            // the main-actor hop.
            let bytes = SWPJunkScanner.trashSize()
            guard let self else { return }
            await MainActor.run {
                guard self.scanGeneration == generation else { return }
                self.result.trashBytes = bytes
            }
        }
    }

    /// Returns to the results list from the idle hero without rescanning.
    func showResults() {
        guard hasResults else { return }
        isUninstallerActive = false
        phase = .results
    }

    func reveal(_ item: SWPItem) { removal.reveal(item) }
    func revealTrash() { removal.revealTrash() }
    func clearOutcome() { lastOutcome = nil }

    // MARK: Ignore list

    /// Permanently excludes a group and drops it from the current results.
    func ignore(_ group: SWPGroup) {
        ignoreList.ignore(group.items)
        selectedGroupIDs.remove(group.id)
        result.groups.removeAll { $0.id == group.id }
        syncIgnored()
    }

    private func syncIgnored() { ignoredPathList = ignoreList.paths.sorted() }

    func clearIgnoreList() {
        ignoreList.clear()
        syncIgnored()
        scan()
    }

    /// Stops ignoring one path. The next scan can surface it again.
    func stopIgnoring(_ path: String) {
        ignoreList.stopIgnoring(path)
        syncIgnored()
    }

    var ignoredPaths: [String] { ignoredPathList }
    var ignoredCount: Int { ignoredPathList.count }

    // MARK: Startup jobs

    @Published var pendingDisable: SWPStartupEntry?

    /// Turns off a working launch agent or daemon, reversibly.
    func disableStartupJob(_ entry: SWPStartupEntry) {
        pendingDisable = nil
        let removal = self.removal
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                removal.disableStartupJobs([entry])
            }.value
            guard let self else { return }
            if outcome.adminCancelled { return }
            let message = outcome.trashedCount > 0
                ? "Disabled \(entry.label). Its configuration is in the Trash, in a dated “Sweep Disabled Startup” folder — Undo below puts it back."
                : "Couldn't disable \(entry.label)."
            self.refreshRestorable()
            self.scan()
            self.restoreMessage = message
        }
    }

    // MARK: Simulators

    /// Removes simulator devices whose runtime is no longer installed.
    ///
    /// The one place Sweep shells out to another tool to destroy something,
    /// and the one action here that is *not* recoverable from the Trash.
    /// Deleting `CoreSimulator/Devices` folders by hand corrupts the simulator
    /// database, so `simctl` has to own it — which means accepting its
    /// semantics. It is deliberately kept out of the tick-and-trash flow, has
    /// its own confirmation, and says plainly that it cannot be undone.
    @Published private(set) var isDeletingSimulators = false

    func deleteUnavailableSimulators() {
        guard !isDeletingSimulators else { return }
        isDeletingSimulators = true
        Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) {
                SWPAppInventory.shell("/usr/bin/xcrun", ["simctl", "delete", "unavailable"],
                                      timeout: 180)
            }.value
            guard let self else { return }
            self.isDeletingSimulators = false
            self.log.info("simctl delete unavailable: \(output.count) bytes of output")
            self.scan()
        }
    }

    // MARK: Restore

    /// Quarantine folders from previous authorised removals that can be undone.
    ///
    /// Cached rather than computed: reading it walks `~/.Trash`, and a computed
    /// property would do that on every SwiftUI render pass.
    @Published private(set) var restorableFolders: [URL] = []

    func refreshRestorable() {
        restorableFolders = SWPRemovalService.restorableFolders()
    }

    func restore(from folder: URL) {
        guard !isRestoring else { return }
        isRestoring = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRestoring = false }
            let removal = self.removal
            let result = await Task.detached(priority: .userInitiated) {
                removal.restore(from: folder)
            }.value
            if result.cancelled { return }
            self.refreshRestorable()
            let message = result.failed == 0
                ? "Restored \(result.restored) system item\(result.restored == 1 ? "" : "s")."
                : "Restored \(result.restored); \(result.failed) could not be put back."
            // Set AFTER the rescan is kicked off: `scan()` clears transient
            // banners in its prologue, so setting it first meant the message
            // was wiped in the same turn it appeared.
            self.scan()
            self.restoreMessage = message
        }
    }

    @Published var restoreMessage: String?
    @Published private(set) var isRestoring = false
}
