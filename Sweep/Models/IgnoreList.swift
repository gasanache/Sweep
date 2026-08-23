import Foundation
import os

// MARK: - Ignore list

/// Paths the user has told Sweep to stop reporting.
///
/// The alternative — per-path tick boxes inside a group — was rejected because
/// it implies a precision nobody has the information to exercise. "I have
/// looked at this and I want it left alone, permanently" is a different and
/// much more answerable question, and answering it once should hold for every
/// future scan.
///
/// Stored as absolute paths in `UserDefaults`. A path that no longer exists is
/// dropped on load, so the list cannot grow forever.
@MainActor
final class SWPIgnoreList: ObservableObject {

    private static let defaultsKey = "ignoredPaths"
    private let log = Logger(subsystem: "com.gasanache.sweep", category: "ignore")

    @Published private(set) var paths: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(paths), forKey: Self.defaultsKey) }
    }

    init() {
        let stored = (UserDefaults.standard.array(forKey: Self.defaultsKey) as? [String]) ?? []
        // Prune vanished paths on load: an ignored item the user later removed
        // by hand should not keep a dead entry alive.
        paths = Set(stored.filter { FileManager.default.fileExists(atPath: $0) })
    }

    var isEmpty: Bool { paths.isEmpty }
    var count: Int { paths.count }

    func contains(_ url: URL) -> Bool { paths.contains(url.standardizedFileURL.path) }

    /// Ignores every path in a group.
    func ignore(_ items: [SWPItem]) {
        for item in items { paths.insert(item.url.standardizedFileURL.path) }
        log.info("ignoring \(items.count) path(s)")
    }

    func stopIgnoring(_ path: String) { paths.remove(path) }

    func clear() { paths.removeAll() }

    /// Snapshot for the scanners, which run off the main actor.
    func snapshot() -> Set<String> { paths }
}
