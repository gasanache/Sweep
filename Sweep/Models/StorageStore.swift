import Foundation
import Combine

@MainActor
final class SWPStorageStore: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var snapshot: SWPStorageSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var isStopping = false
    @Published private(set) var scanError: String?
    @Published private(set) var currentPath: [String] = []
    @Published var selectedEntryID: String?

    private let load: @Sendable (URL, SWPStorageIdentity?) throws -> SWPStorageSnapshot
    private var worker: Task<SWPStorageSnapshot, Error>?
    private var generation = UUID()
    private var rootIdentity: SWPStorageIdentity?

    /// Synchronous backends always run in a cancellable detached task. The
    /// identity is retained for rescans: choosing a folder is the only operation
    /// that authorizes a new root after replacement.
    init(load: @escaping @Sendable (URL, SWPStorageIdentity?) throws -> SWPStorageSnapshot = {
        try SWPStorageScanner().scan(rootURL: $0, expectedIdentity: $1)
    }) {
        self.load = load
    }

    deinit { worker?.cancel() }

    var currentEntry: SWPStorageEntry? {
        guard var entry = snapshot?.root else { return nil }
        for name in currentPath {
            guard let child = entry.children.first(where: { $0.name == name && $0.canBrowse }) else { return nil }
            entry = child
        }
        return entry
    }

    func selectFolder(_ url: URL) {
        rootURL = url
        rootIdentity = nil
        startScan()
    }

    func refresh() {
        guard rootURL != nil, !isScanning else { return }
        startScan()
    }

    func cancel() {
        guard isScanning, !isStopping else { return }
        isStopping = true
        worker?.cancel()
    }

    func browse(_ entry: SWPStorageEntry) {
        guard !isScanning, entry.canBrowse,
              currentEntry?.children.contains(where: { $0.id == entry.id && $0.canBrowse }) == true else { return }
        selectedEntryID = nil
        currentPath.append(entry.name)
    }

    func goBack() {
        guard !currentPath.isEmpty else { return }
        goToAncestor(depth: currentPath.count - 1)
    }

    func goToAncestor(depth: Int) {
        guard depth >= 0, depth <= currentPath.count else { return }
        selectedEntryID = nil
        currentPath = Array(currentPath.prefix(depth))
    }

    func goToRoot() { goToAncestor(depth: 0) }

    private func startScan() {
        guard let rootURL else { return }
        worker?.cancel()
        let generation = UUID()
        self.generation = generation
        snapshot = nil
        selectedEntryID = nil
        currentPath = []
        scanError = nil
        isScanning = true
        isStopping = false
        let load = self.load
        let identity = rootIdentity
        let task = Task.detached(priority: .userInitiated) {
            try load(rootURL, identity)
        }
        worker = task
        Task { [weak self] in
            let result = await task.result
            guard let self, self.generation == generation else { return }
            self.isScanning = false
            self.isStopping = false
            self.worker = nil
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.rootURL = snapshot.root.url
                self.rootIdentity = snapshot.rootIdentity
            case .failure(let error):
                self.scanError = task.isCancelled ? "Scan stopped before a folder inventory was available." : error.localizedDescription
            }
        }
    }
}
