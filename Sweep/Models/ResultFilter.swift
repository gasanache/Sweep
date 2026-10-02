import Foundation

/// Decimal thresholds match the Finder-style sizes shown throughout Sweep.
enum SWPMinimumSize: Int64, CaseIterable, Identifiable {
    case all = 0
    case tenMB = 10_000_000
    case hundredMB = 100_000_000
    case oneGB = 1_000_000_000

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .all: return "All sizes"
        case .tenMB: return "≥ 10 MB"
        case .hundredMB: return "≥ 100 MB"
        case .oneGB: return "≥ 1 GB"
        }
    }
}

/// Filters whole owner groups using only the metadata from the last scan.
/// A matching path keeps the entire group: selection is never item-level.
struct SWPResultFilter {
    var query = ""
    var minimumSize: SWPMinimumSize = .all
    var evidence: SWPConfidence?

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || minimumSize != .all || evidence != nil
    }

    func matchingGroups(in groups: [SWPGroup]) -> [SWPGroup] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || minimumSize != .all || evidence != nil else { return groups }
        return groups.filter { group in
            if let evidence, group.confidence != evidence { return false }
            if minimumSize != .all, group.sizeBytes < minimumSize.rawValue { return false }
            return text.isEmpty || group.name.localizedCaseInsensitiveContains(text)
                || group.items.contains { $0.url.path.localizedCaseInsensitiveContains(text) }
        }
    }
}
