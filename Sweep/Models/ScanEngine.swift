import Foundation
import SwiftUI
import os

// MARK: - Phase

enum SWPPhase: Equatable {
    case idle
    case scanning(String)
    case results
    case removing
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

    @Published var selectedCategory: SWPCategory = .leftovers
    /// Whether the main pane shows the uninstaller instead of scan content.
    /// UI-navigation state, held here because the engine is the window's root
    /// store; the uninstaller's own data lives in `SWPUninstallStore`.
    @Published var isUninstallerActive = false
    @Published var selectedGroupIDs: Set<String> = []
    @Published var expandedGroupIDs: Set<String> = []
    @Published var isConfirming = false

    private let removal = SWPRemovalService()
    private var scanTask: Task<Void, Never>?
    /// Monotonic scan identity. A cancelled scan's detached work keeps
    /// running, and its progress callbacks arrive on the main actor *after*
    /// the cancellation — without this stamp, a stale callback could flip the
    /// UI back to "Scanning …" with no scan alive to ever end it. Every
    /// callback and completion checks the generation it was born with.
    private var scanGeneration = 0

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

    // MARK: Scanning

    func scan() {
        guard scanTask == nil, phase != .removing else { return }
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning("Taking inventory")
        result = SWPScanResult()
        selectedGroupIDs = []
        lastOutcome = nil

        scanTask = Task { [weak self] in
            let outcome = await Self.performScan { message in
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.phase = .scanning(message)
                }
            }

            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.result = outcome.result
            self.healthyStartupItems = outcome.healthy
            self.lastScanDate = Date()
            self.phase = .results
            self.scanTask = nil
            self.log.info("scan complete: \(outcome.result.groups.count) groups, \(outcome.result.totalBytes) bytes")
        }
    }

    func cancelScan() {
        // Bumping the generation orphans every callback of the cancelled scan;
        // its detached work finishes quietly and is discarded.
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        phase = result.groups.isEmpty ? .idle : .results
    }

    /// Runs the four scanners off the main actor.
    ///
    /// `detached` rather than a plain `Task`: the engine is `@MainActor`, so an
    /// inherited context would drag several seconds of synchronous filesystem
    /// walking onto the main thread and freeze the window mid-scan.
    private static func performScan(
        progress: @escaping (String) -> Void
    ) async -> (result: SWPScanResult, healthy: [SWPStartupEntry]) {
        await Task.detached(priority: .userInitiated) { () -> (SWPScanResult, [SWPStartupEntry]) in
            var result = SWPScanResult()

            progress("Taking inventory of installed apps")
            let inventory = SWPAppInventory.build()
            result.appsInventoried = inventory.appCount
            result.inventoryUnreliable = !inventory.isTrustworthy

            var unreadable: [String] = []
            let orphanScanner = SWPOrphanScanner(inventory: inventory)
            let orphanGroups = orphanScanner.scan(unreadable: &unreadable) { location in
                progress("Scanning \(location)")
            }

            // Claim orphan paths so the disposable sweep cannot list the same
            // folder twice under a friendlier label.
            var claimed = Set(orphanGroups.flatMap(\.items).map { $0.url.standardizedFileURL.path })

            var junkScanner = SWPJunkScanner(inventory: inventory, claimed: claimed)
            let developerGroups = junkScanner.scanDeveloper { progress("Scanning \($0)") }
            let cacheGroups = junkScanner.scanCaches { progress("Scanning \($0)") }
            let logGroups = junkScanner.scanLogs { progress("Scanning \($0)") }
            claimed.formUnion(developerGroups.flatMap(\.items).map(\.url.path))

            progress("Checking startup items")
            let startupScanner = SWPStartupScanner(inventory: inventory)
            let startup = startupScanner.scan { progress("Scanning \($0)") }

            progress("Measuring the Trash")
            result.trashBytes = SWPJunkScanner.trashSize()
            result.unreadablePaths = unreadable
            result.groups = orphanGroups + developerGroups + cacheGroups + logGroups + startup.groups

            return (result, startup.healthy)
        }.value
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

    func selectAll(in category: SWPCategory) {
        selectedGroupIDs.formUnion(result.groups(in: category).map(\.id))
    }

    func deselectAll(in category: SWPCategory) {
        selectedGroupIDs.subtract(result.groups(in: category).map(\.id))
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
        log.info("removed \(outcome.trashedCount) items, \(outcome.trashedBytes) bytes")

        // Rebuild the list from filesystem truth: keep only rows that still
        // exist. This handles every case at once — pruned descendants that
        // vanished with their parent, admin partial failures, and anything a
        // concurrent process removed — without trusting our own bookkeeping.
        result.groups = result.groups.compactMap { group in
            let remaining = group.items.filter {
                FileManager.default.fileExists(atPath: $0.url.path)
            }
            guard !remaining.isEmpty else { return nil }
            return SWPGroup(id: group.id, name: group.name, category: group.category,
                            confidence: group.confidence, items: remaining)
        }
        selectedGroupIDs = selectedGroupIDs.filter { id in result.groups.contains { $0.id == id } }
        phase = .results

        // Re-measuring the Trash walks every file in it — seconds when it
        // holds tens of thousands — so it happens off the main actor, stamped
        // against the scan generation so a rescan's fresh number cannot be
        // overwritten by this stale one.
        let generation = scanGeneration
        Task.detached(priority: .utility) { [weak self] in
            let bytes = SWPJunkScanner.trashSize()
            await MainActor.run {
                guard let self, self.scanGeneration == generation else { return }
                self.result.trashBytes = bytes
            }
        }
    }

    func reveal(_ item: SWPItem) { removal.reveal(item) }
    func revealTrash() { removal.revealTrash() }
    func clearOutcome() { lastOutcome = nil }
}
