import Foundation

// MARK: - Category

/// The five buckets the sidebar shows.
///
/// Deliberately a small, closed set. An earlier sketch had eleven categories
/// (separate rows for containers, group containers, saved state, …) and the
/// sidebar became a filesystem tour rather than a set of decisions. Users think
/// in terms of "junk from apps I deleted" and "developer stuff", not in terms
/// of `~/Library` subdirectory names.
enum SWPCategory: String, CaseIterable, Identifiable, Hashable {
    case leftovers
    case caches
    case logs
    case developer
    case startup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftovers: return "App Leftovers"
        case .caches:    return "Caches"
        case .logs:      return "Logs & Reports"
        case .developer: return "Developer Junk"
        case .startup:   return "Startup Items"
        }
    }

    var symbolName: String {
        switch self {
        case .leftovers: return "shippingbox"
        case .caches:    return "shippingbox.and.arrow.backward"
        case .logs:      return "doc.text"
        case .developer: return "hammer"
        case .startup:   return "bolt.horizontal"
        }
    }

    var blurb: String {
        switch self {
        case .leftovers: return "Files left behind by apps that are no longer installed."
        case .caches:    return "Rebuildable cache data. Caches of apps you still have are marked In Use."
        case .logs:      return "Log files and crash reports from third-party apps."
        case .developer: return "Xcode derived data, archives, device support and package caches."
        case .startup:   return "Background agents and daemons that load at login."
        }
    }
}

// MARK: - Confidence

/// What Sweep knows about the wisdom of removing something.
///
/// This drives the badge and the sort order — and nothing else. It used to
/// also drive pre-selection, but that concept is gone: a scan now ends with
/// zero ticks, whatever the tier says. The cost of a false positive (deleting
/// a live app's data) vastly outweighs the cost of a false negative (leaving
/// megabytes on a half-terabyte disk), so every selection is the user's.
enum SWPConfidence: Int, Hashable {
    /// Rebuildable by design and no installed owner — caches with no matching
    /// app, derived data, logs. The cheapest tier to remove.
    case safe = 0
    /// Bundle-identifier evidence says the owning app is not installed.
    case confirmed = 1
    /// Name-only match. Plausible, but review before removing.
    case likely = 2
    /// The owner is still installed. Offered because clearing a live app's
    /// cache is sometimes genuinely wanted, but never suggested: the app will
    /// rebuild the data, its next launch gets slower, and some apps keep
    /// offline content in here.
    case inUse = 3

    /// Display order within a category: hard evidence first, guesses next,
    /// then the freely-disposable tier, and in-use data last — the order of
    /// how advisable removal is, which is not the order of `rawValue`.
    var sortRank: Int {
        switch self {
        case .confirmed: return 0
        case .likely:    return 1
        case .safe:      return 2
        case .inUse:     return 3
        }
    }

    var label: String {
        switch self {
        case .safe:      return "Safe"
        case .confirmed: return "Orphaned"
        case .likely:    return "Review"
        case .inUse:     return "In Use"
        }
    }
}

// MARK: - Item

/// One filesystem object Sweep is prepared to move to the Trash.
///
/// Identity is the path, not a synthesised `UUID`: scans re-run and SwiftUI
/// must keep a row's expansion and tick state across a rescan, which a fresh
/// UUID each pass would silently break.
struct SWPItem: Identifiable, Hashable {
    let url: URL
    let sizeBytes: Int64
    let modified: Date?
    /// Human-readable origin, e.g. "Application Support" — shown under the path.
    let location: String
    /// `/Library` items cannot be trashed by the user alone.
    let requiresAdmin: Bool

    var id: String { url.path }

    var displayPath: String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }
}

// MARK: - Group

/// Every item that belongs to one owner, shown as a single collapsible row.
///
/// Grouping is what makes the results legible: CleanMyMac-style tools list 90
/// loose paths, but the user's actual decision is "do I still want anything
/// from Krisp?" — one decision covering seven paths.
struct SWPGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let category: SWPCategory
    let confidence: SWPConfidence
    let items: [SWPItem]

    var sizeBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var requiresAdmin: Bool { items.contains { $0.requiresAdmin } }

    /// Most recent modification across the group, shown as "last used".
    var latestModified: Date? { items.compactMap(\.modified).max() }

    /// Distinct locations this group spans, most common first, capped at three.
    ///
    /// Shows *where* a group lives without making the user expand it — the
    /// difference between "one preferences file" and "a container, a cache and
    /// a launch agent" is most of what decides whether a row matters.
    var locationChips: [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            if counts[item.location] == nil { order.append(item.location) }
            counts[item.location, default: 0] += 1
        }
        // Most-represented location first; ties keep the order encountered so
        // the chips are stable between scans.
        let ranked = order.enumerated().sorted { lhs, rhs in
            let leftCount = counts[lhs.element] ?? 0
            let rightCount = counts[rhs.element] ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            return lhs.offset < rhs.offset
        }
        return Array(ranked.map(\.element).prefix(3))
    }

    var subtitle: String {
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        guard let date = latestModified else { return count }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return "\(count) · last used \(formatter.string(from: date))"
    }
}

// MARK: - Result set

/// The whole outcome of a scan.
struct SWPScanResult {
    var groups: [SWPGroup] = []
    /// Locations that could not be read, usually because Full Disk Access is
    /// not granted. Surfaced in the UI rather than silently under-reporting.
    var unreadablePaths: [String] = []
    var trashBytes: Int64 = 0
    var appsInventoried: Int = 0
    /// True when the installed-app index came back suspiciously small and the
    /// inferential scanners were skipped. The UI must say why the leftovers
    /// list is empty rather than let it read as "this Mac is clean".
    var inventoryUnreliable = false
    /// Carried on the result so a streaming scan can deliver it with the
    /// startup stage rather than as separate engine state.
    var healthyStartup: [SWPStartupEntry] = []

    /// Folds one stage's metadata into the running result. Groups are appended
    /// by the caller; this carries only the scalar and list fields, and never
    /// overwrites a set value with an empty default.
    mutating func merge(_ other: SWPScanResult) {
        if other.appsInventoried > 0 { appsInventoried = other.appsInventoried }
        if other.inventoryUnreliable { inventoryUnreliable = true }
        if other.trashBytes > 0 { trashBytes = other.trashBytes }
        if !other.unreadablePaths.isEmpty { unreadablePaths += other.unreadablePaths }
        if !other.healthyStartup.isEmpty { healthyStartup = other.healthyStartup }
    }

    func groups(in category: SWPCategory) -> [SWPGroup] {
        groups.filter { $0.category == category }.sorted { lhs, rhs in
            if lhs.confidence.sortRank != rhs.confidence.sortRank {
                return lhs.confidence.sortRank < rhs.confidence.sortRank
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
    }

    func bytes(in category: SWPCategory) -> Int64 {
        groups.filter { $0.category == category }.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalBytes: Int64 { groups.reduce(0) { $0 + $1.sizeBytes } }
}
