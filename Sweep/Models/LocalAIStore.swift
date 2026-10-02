import Foundation
import Combine

@MainActor
final class SWPLocalAIStore: ObservableObject {
    @Published private(set) var plans: [SWPLocalAIPlan] = []
    @Published private(set) var inventory: SWPAIInventory?
    @Published private(set) var additionalFolders: [URL] = []
    @Published var inventoryQuery = ""
    @Published var inventoryModelsOnly = false
    @Published var inventorySortOrder = [KeyPathComparator(\SWPAIFinding.sortBytes, order: .reverse)]
    @Published var showsCleanup = false
    @Published var selectedFindingID: String?
    @Published var isConfirming = false
    private var hasLoadedPlans = false
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var scanError: String?
    @Published private(set) var result: SWPLocalAICleanupResult?
    @Published private(set) var resultProduct: SWPLocalAIProduct?
    @Published private(set) var removingProduct: SWPLocalAIProduct?

    var visiblePlans: [SWPLocalAIPlan] {
        plans.filter { $0.hasWork || $0.isInstalled || !$0.blockers.isEmpty }
    }

    /// Shared discovery notes appear once, not as duplicate product warnings.
    /// Notes from empty products remain inspectable in coverage as well.
    var discoveryNotes: [String] {
        let common = plans.first?.notes.filter { note in
            plans.count > 1 && plans.dropFirst().allSatisfy { $0.notes.contains(note) }
        } ?? []
        let hiddenNotes = plans.filter { plan in !visiblePlans.contains { $0.id == plan.id } }.flatMap(\.notes)
        return Array(Set(common + hiddenNotes)).sorted()
    }

    var visibleFindings: [SWPAIFinding] {
        let query = inventoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return (inventory?.findings ?? []).filter {
            (!inventoryModelsOnly || $0.kind.isModel) &&
            (query.isEmpty || "\($0.product) \($0.url.path) \($0.kind.rawValue)".localizedCaseInsensitiveContains(query))
        }.sorted(using: inventorySortOrder)
    }

    private let loadInventory: @Sendable ([URL]) -> SWPAIInventory
    private let load: @Sendable () throws -> [SWPLocalAIPlan]
    private let performRemoval: @Sendable (SWPLocalAIPlan) -> SWPLocalAICleanupResult

    /// Synchronous backends always run off the main actor, including injected fixtures.
    init(
        load: @escaping @Sendable () throws -> [SWPLocalAIPlan] = {
            SWPLocalAIScanner().scan()
        },
        loadInventory: @escaping @Sendable ([URL]) -> SWPAIInventory = { folders in
            SWPAIInventoryScanner(additionalFolders: folders).scan()
        },
        remove: @escaping @Sendable (SWPLocalAIPlan) -> SWPLocalAICleanupResult = {
            SWPLocalAIRemovalService().remove($0)
        }
    ) {
        self.load = load
        self.loadInventory = loadInventory
        self.performRemoval = remove
    }

    func refresh() async {
        guard !isScanning, !isRemoving, !isConfirming else { return }
        if showsCleanup { await loadPlans(includeInventory: false) }
        else { await refreshInventory() }
    }

    func refreshIfNeeded() async {
        guard !isScanning, !isRemoving, !isConfirming else { return }
        if showsCleanup {
            if !hasLoadedPlans { await loadPlans(includeInventory: false) }
        } else if inventory == nil {
            await refreshInventory()
        }
    }

    private func refreshInventory() async {
        isScanning = true
        defer { isScanning = false }
        await loadInventorySnapshot()
    }

    func acceptInventory(_ snapshot: SWPAIInventory) {
        // A slow older refresh must not overwrite newer main-scan evidence.
        guard !isRemoving, snapshot.additionalFolderPaths == Set(additionalFolders.map(\.path)),
              inventory == nil || snapshot.scannedAt >= inventory!.scannedAt else { return }
        inventory = snapshot
        if let selectedFindingID, !snapshot.findings.contains(where: { $0.id == selectedFindingID }) {
            self.selectedFindingID = nil
        }
    }

    func addFolder(_ url: URL) async {
        guard !isScanning, !isRemoving, !isConfirming, additionalFolders.count < 32,
              !additionalFolders.contains(where: { $0.path == url.path }) else { return }
        SWPAIInspectionProtection.shared.reserve([url])
        additionalFolders.append(url)
        await refresh()
    }

    func removeFolder(_ url: URL) async {
        guard !isScanning, !isRemoving, !isConfirming else { return }
        additionalFolders.removeAll { $0.path == url.path }
        await refresh()
    }

    /// The caller passes the immutable plan reviewed in the confirmation sheet.
    /// The removal service revalidates ownership and refuses unreviewed additions.
    func remove(_ plan: SWPLocalAIPlan) async {
        guard !isScanning, !isRemoving, plan.blockers.isEmpty, plan.hasWork else { return }
        isRemoving = true
        removingProduct = plan.product
        defer {
            isRemoving = false
            removingProduct = nil
        }

        let performRemoval = self.performRemoval
        let outcome = await Task.detached(priority: .userInitiated) {
            performRemoval(plan)
        }.value
        resultProduct = plan.product
        result = outcome
        // Keep the mutation lock through the rescan, and preserve the outcome even
        // if loading fails. Navigation or refresh must not hide a partial cleanup.
        await loadPlans(includeInventory: true)
    }

    func clearResult() {
        guard !isRemoving else { return }
        result = nil
        resultProduct = nil
    }

    private func loadPlans(includeInventory: Bool) async {
        isScanning = true
        defer { isScanning = false; hasLoadedPlans = true }
        let load = self.load
        do {
            plans = try await Task.detached(priority: .userInitiated) {
                try load()
            }.value
            scanError = nil
        } catch {
            // A failed scan must not leave an old plan actionable.
            plans = []
            scanError = error.localizedDescription
        }
        if includeInventory { await loadInventorySnapshot() }
    }

    private func loadInventorySnapshot() async {
        let discover = loadInventory
        let folders = additionalFolders
        let snapshot = await Task.detached(priority: .userInitiated) { discover(folders) }.value
        // A post-cleanup refresh owns the mutation lock and must update the
        // inventory too. External main-scan updates remain barred by it.
        if isRemoving { inventory = snapshot }
        else { acceptInventory(snapshot) }
    }
}
