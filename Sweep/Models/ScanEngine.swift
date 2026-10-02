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

/// The stages a scan moves through, in order.
///
/// Named rather than a bare percentage because "Scanning Caches" tells the
/// user something a spinner cannot: which part of their disk is being read,
/// and therefore why it is taking as long as it is.
enum SWPScanStage: Int, CaseIterable, Identifiable {
    case inventory, leftovers, developer, disposable, startup, ai

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .inventory:  return "Inventory"
        case .leftovers:  return "Leftovers"
        case .developer:  return "Developer"
        case .disposable: return "Caches & Logs"
        case .startup:    return "Startup"
        case .ai:         return "AI & Models"
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

/// Owns the main scan and the cleaner's selection/removal workflow. Independent
/// tools retain their own operational stores. Read-only AI evidence travels with
/// the scan result, but never becomes part of the cleaner's removal selection.
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
    @Published private(set) var isRemoving = false

    var stageProgress: Double {
        Double(completedStages.count) / Double(SWPScanStage.allCases.count)
    }

    /// One active destination; independent tools keep their own operational stores.
    @Published var destination: SWPDestination = .cleanup(.leftovers)
    var selectedCategory: SWPCategory {
        if case .cleanup(let category) = destination { return category }
        return .leftovers
    }
    /// Name/path, minimum-size and evidence filters compose without rescanning.
    @Published var filter = SWPResultFilter()
    /// Session-only user-added model locations, shared with the AI browser.
    var additionalAIFolders: [URL] = []
    @Published var sortOrder: SWPSortOrder = .evidence
    @Published var selectedGroupIDs: Set<String> = []
    @Published var expandedGroupIDs: Set<String> = []
    @Published var isConfirming = false {
        didSet {
            if !isConfirming { reviewedGroups = [] }
        }
    }
    /// Frozen when the confirmation opens, so streamed results cannot change
    /// what the user is authorizing while they review the paths.
    @Published private(set) var reviewedGroups: [SWPGroup] = []

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
    /// would be mutated from separate stage contexts while the scan task read
    /// it — a real race that let `healthyStartup` come back empty on a fast
    /// scan, not merely a compiler complaint.
    private var streamedResult = SWPScanResult()

    typealias ProgressHandler = @Sendable (String) -> Void
    typealias StageHandler = @Sendable (SWPScanStage, [SWPGroup], SWPScanResult) async -> Void
    typealias ScanWork = @Sendable (Set<String>, Set<String>, [URL], @escaping ProgressHandler, @escaping StageHandler) async -> Void
    private let scanWork: ScanWork
    private let removeItems: @Sendable ([SWPItem]) -> SWPRemovalOutcome

    init(scanWork: ScanWork? = nil,
         removeItems: (@Sendable ([SWPItem]) -> SWPRemovalOutcome)? = nil) {
        self.scanWork = scanWork ?? { ignored, running, folders, progress, stage in
            await Self.performScan(ignored: ignored, runningBundleIDs: running, additionalAIFolders: folders,
                                   progress: progress, stage: stage)
        }
        self.removeItems = removeItems ?? { items in
            let removal = SWPRemovalService()
            var outcome = removal.trash(items)
            outcome.merge(removal.trashWithAuthorisation(items))
            return outcome
        }
        ignoredPathList = ignoreList.paths.sorted()
    }

    // MARK: Derived

    var selectedGroups: [SWPGroup] {
        result.groups.filter { selectedGroupIDs.contains($0.id) }
    }

    var hasResults: Bool { !result.groups.isEmpty }

    var isMutating: Bool {
        isRemoving || isDeletingSimulators || isRestoring || isDisablingStartup
    }

    /// Everything the action bar shows, derived in one pass. The bar is built
    /// twice per render (`ViewThatFits`), and reading the individual computed
    /// properties re-filtered and re-sorted the results about ten times per
    /// keystroke in the filter field.
    struct SelectionSummary {
        var itemCount = 0
        var bytes: Int64 = 0
        var needsAdmin = false
        var hiddenGroupCount = 0
        var hasUnselectedSafeShown = false
    }

    var selectionSummary: SelectionSummary {
        let shown = shownGroupsIgnoringOrder
        var summary = SelectionSummary()
        summary.hasUnselectedSafeShown = shown.contains {
            $0.confidence == .safe && !selectedGroupIDs.contains($0.id)
        }
        guard !selectedGroupIDs.isEmpty else { return summary }
        let shownIDs = Set(shown.lazy.map(\.id))
        for group in result.groups where selectedGroupIDs.contains(group.id) {
            summary.itemCount += group.items.count
            for item in group.items {
                summary.bytes += item.sizeBytes
                if item.requiresAdmin { summary.needsAdmin = true }
            }
            if !shownIDs.contains(group.id) { summary.hiddenGroupCount += 1 }
        }
        return summary
    }

    /// Groups of the current category that pass the filters. Visibility only;
    /// ordering is irrelevant, so this skips `visibleGroups`' sorts.
    private var shownGroupsIgnoringOrder: [SWPGroup] {
        filter.matchingGroups(in: result.groups.filter { $0.category == selectedCategory })
    }

    /// Selected live groups outside the current category and all active filters.
    /// Hidden selections remain part of the confirmation until explicitly cleared.
    private var hiddenSelectedGroupIDs: Set<String> {
        guard !selectedGroupIDs.isEmpty else { return [] }
        let shown = Set(shownGroupsIgnoringOrder.lazy.map(\.id))
        return Set(result.groups.lazy.filter {
            self.selectedGroupIDs.contains($0.id) && !shown.contains($0.id)
        }.map(\.id))
    }

    func clearFilters() {
        filter = SWPResultFilter()
    }

    /// Keeps the visible selection; never changes the findings or the filters.
    func deselectHidden() {
        selectedGroupIDs.subtract(hiddenSelectedGroupIDs)
    }

    /// Groups for a category after filtering and sorting.
    ///
    /// `.evidence` keeps the default order defined by `SWPScanResult` (hard
    /// evidence first, then size) — the ordering the tiers exist to express.
    func visibleGroups(in category: SWPCategory) -> [SWPGroup] {
        let groups = filter.matchingGroups(in: result.groups(in: category))

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
        guard !isRemoving else { return }
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

        let scanWork = self.scanWork
        let folders = additionalAIFolders
        scanTask = Task { [weak self] in
            await scanWork(
                ignored,
                running,
                folders,
                // The weak capture is read on each closure's own frame rather
                // than from inside a nested concurrent closure.
                { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.scanGeneration == generation, self.scanTask != nil, !self.isRemoving else { return }
                        if !self.isRescanning { self.phase = .scanning(message) }
                    }
                },
                // `async` so each stage is *awaited* by the scanner before the
                // next one starts. One main-actor hop per stage, and in
                // exchange every stage is guaranteed applied before the
                // completion block reads the accumulated result (3.5).
                { [weak self] stage, groups, partial in
                    await MainActor.run {
                        guard let self, self.scanGeneration == generation, !self.isRemoving else { return }
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
                        if let next = SWPScanStage(rawValue: stage.rawValue + 1) {
                            self.currentStage = next
                        }
                    }
                })

            guard let self, !Task.isCancelled, self.scanGeneration == generation, !self.isRemoving else { return }
            self.result = self.streamedResult
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
        guard !isRemoving else { return }
        rescanPending = false
        // Bumping the generation orphans every callback of the cancelled scan;
        // the handler in `performScan` cancels the detached work for real.
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        isRescanning = false
        phase = result.groups.isEmpty ? .idle : .results
    }

    /// Runs filesystem scanning off the main actor.
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
        additionalAIFolders: [URL],
        progress: @escaping @Sendable (String) -> Void,
        stage: @escaping @Sendable (SWPScanStage, [SWPGroup], SWPScanResult) async -> Void
    ) async {
        let work = Task.detached(priority: .userInitiated) {
            SWPAIInspectionProtection.shared.reserve(additionalAIFolders)
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
            let claimed = Set(orphanGroups.flatMap(\.items).map { $0.url.standardizedFileURL.path })

            var junkScanner = SWPJunkScanner(inventory: inventory, claimed: claimed,
                                             ignored: ignored)
            let developerGroups = junkScanner.scanDeveloper(
                emitGroups: SWPSettings.scansDeveloper) { progress("Scanning \($0)") }
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
            if Task.isCancelled { return }

            progress("Discovering AI tools and model locations (read-only)")
            var ai = SWPScanResult()
            ai.aiInventory = SWPAIInventoryScanner(additionalFolders: additionalAIFolders).scan()
            if !Task.isCancelled { await stage(.ai, [], ai) }
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

    /// Adds only visible `.safe` groups. Hidden groups and other evidence tiers
    /// keep their explicit selections unchanged.
    func selectAllSafe() {
        selectedGroupIDs.formUnion(
            visibleGroups(in: selectedCategory).lazy.filter { $0.confidence == .safe }.map(\.id)
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

    /// Acts only on visible groups; hidden selections remain unchanged.
    func selectAll(in category: SWPCategory) {
        selectedGroupIDs.formUnion(visibleGroups(in: category).map(\.id))
    }

    func deselectAll(in category: SWPCategory) {
        selectedGroupIDs.subtract(visibleGroups(in: category).map(\.id))
    }

    func isSelected(_ group: SWPGroup) -> Bool { selectedGroupIDs.contains(group.id) }

    // MARK: Removal

    func confirmRemoval() {
        guard !isMutating, !isConfirming else { return }
        let selected = selectedGroups
        var remaining = Set(SWPRemovalService.prunedOfDescendants(selected.flatMap(\.items)).map(\.id))
        guard !remaining.isEmpty else { return }
        reviewedGroups = selected.compactMap { group in
            let items = group.items.filter { remaining.remove($0.id) != nil }
            guard !items.isEmpty else { return nil }
            return SWPGroup(id: group.id, name: group.name, category: group.category,
                            confidence: group.confidence, items: items)
        }
        isConfirming = true
    }

    /// Trashes only the reviewed snapshot, user-level first, then the authorised batch.
    ///
    /// The filesystem work and the admin password prompt run on a detached
    /// task: on the main actor they froze the window for the whole removal,
    /// and — with no suspension point between setting `.removing` and setting
    /// `.results` — the removing state could never even render.
    func performRemoval() {
        guard !isMutating, isConfirming, !reviewedGroups.isEmpty else { return }
        let groups = reviewedGroups
        isConfirming = false
        // The review already removed duplicate and descendant paths. This is
        // exactly the list displayed and totaled in the confirmation.
        let items = groups.flatMap(\.items)
        guard !items.isEmpty else { return }

        // The reviewed snapshot survives cancellation. Every pending scanner
        // callback loses its generation before the independent mutation lock is set.
        cancelScan()
        isRemoving = true
        phase = .removing
        let removeItems = self.removeItems
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                removeItems(items)
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
        let live = Set(result.groups.lazy.map(\.id))
        selectedGroupIDs.formIntersection(live)
        phase = .results
        isRemoving = false

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
        guard hasResults, !isMutating else { return }
        if !destination.isCleanup { destination = .cleanup(.leftovers) }
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
    @Published private(set) var isDisablingStartup = false

    /// Stops a working launch agent or daemon and moves its configuration to Trash.
    func disableStartupJob(_ entry: SWPStartupEntry) {
        guard !isMutating, !isConfirming else { return }
        isDisablingStartup = true
        pendingDisable = nil
        let removal = self.removal
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                removal.disableStartupJobs([entry])
            }.value
            guard let self else { return }
            defer { self.isDisablingStartup = false }
            if outcome.adminCancelled { return }
            let message = outcome.trashedCount > 0
                ? "Disabled \(entry.label). Its configuration is in the Trash. Undo attempts a safe restore; some system locations require manual administrator handling."
                : "Couldn't disable \(entry.label)."
            self.refreshRestorable()
            self.scan()
            self.restoreFailures = outcome.failures.map { "\($0.path): \($0.reason)" }
                + outcome.refusedByPolicy.map { "Safety policy refused: \($0)" }
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
        guard !isMutating, !isConfirming else { return }
        isDeletingSimulators = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                SWPAppInventory.command("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 180)
            }.value
            guard let self else { return }
            self.isDeletingSimulators = false
            self.scan()
            self.restoreFailures = result.succeeded ? [] : [result.failure ?? result.output]
            self.restoreMessage = result.succeeded ? "Unavailable simulator deletion completed."
                : "Simulator deletion did not complete successfully. Some devices may already have been deleted; review Xcode before retrying."
        }
    }

    // MARK: Restore

    /// Nonempty quarantine batches from previous removals, newest first.
    ///
    /// Cached rather than computed: reading it walks `~/.Trash`, and a computed
    /// property would do that on every SwiftUI render pass.
    @Published private(set) var restorableFolders: [URL] = []

    private var restorableGeneration = 0

    /// Lists `~/.Trash` and parses every Sweep manifest, so it runs off the
    /// main actor; the newest request wins.
    func refreshRestorable() {
        restorableGeneration += 1
        let generation = restorableGeneration
        Task.detached(priority: .utility) { [weak self] in
            let folders = SWPRemovalService.restorableFolders()
            guard let self else { return }
            await MainActor.run {
                guard self.restorableGeneration == generation else { return }
                self.restorableFolders = folders
            }
        }
    }

    func restore(from folder: URL) {
        guard !isMutating, !isConfirming else { return }
        isRestoring = true
        restoreFailures = []
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRestoring = false }
            let removal = self.removal
            let result = await Task.detached(priority: .userInitiated) {
                removal.restore(from: folder)
            }.value
            // Hide a fully restored batch at once, so the bar cannot offer it
            // again while the refresh below is still reading the Trash.
            if !result.cancelled, result.failed == 0 {
                self.restorableFolders.removeAll { $0 == folder }
            }
            self.refreshRestorable()
            let message: String
            if result.cancelled {
                message = "Restored \(result.restored); administrator restore was cancelled. Remaining items stay in the Trash."
            } else if result.failed == 0 {
                message = "Restored \(result.restored) item\(result.restored == 1 ? "" : "s")."
            } else {
                message = "Restored \(result.restored); \(result.failed) could not be put back."
            }
            // Set AFTER the rescan is kicked off: `scan()` clears transient
            // banners in its prologue, so setting it first meant the message
            // was wiped in the same turn it appeared.
            self.scan()
            self.restoreFailures = result.failures
            self.restoreMessage = message
        }
    }

    @Published var restoreMessage: String?
    @Published private(set) var restoreFailures: [String] = []
    @Published private(set) var isRestoring = false
}
