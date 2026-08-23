import Foundation

// MARK: - Diagnostics report

/// Plain-text report of the last scan, for bug reports.
///
/// Written only when the user picks Export Diagnostics, only to a file they
/// choose, and never transmitted anywhere. Paths are included because they are
/// the whole point of a report about which paths were found — the user is
/// explicitly handing this file to someone.
enum SWPDiagnostics {

    static func report(result: SWPScanResult,
                       healthyStartup: [SWPStartupEntry],
                       ignoredCount: Int,
                       lastOutcome: SWPRemovalOutcome?) -> String {
        var lines: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        lines.append("Sweep \(version) (\(build)) — diagnostics")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("generated \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("apps inventoried : \(result.appsInventoried)"
                     + (result.inventoryUnreliable ? "  (UNRELIABLE — scan degraded)" : ""))
        lines.append("total found      : \(SWPBytes.string(result.totalBytes))")
        lines.append("groups           : \(result.groups.count)")
        lines.append("ignored paths    : \(ignoredCount)")
        lines.append("trash            : \(SWPBytes.string(result.trashBytes))")

        if !result.unreadablePaths.isEmpty {
            lines.append("")
            lines.append("UNREADABLE LOCATIONS (Full Disk Access not granted?)")
            for path in result.unreadablePaths { lines.append("  \(path)") }
        }

        if let outcome = lastOutcome {
            lines.append("")
            lines.append("LAST REMOVAL")
            lines.append("  trashed: \(outcome.trashedCount) items, "
                         + SWPBytes.string(outcome.trashedBytes))
            if outcome.adminCancelled { lines.append("  admin authorisation cancelled") }
            for failure in outcome.failures { lines.append("  FAILED \(failure.path): \(failure.reason)") }
            for refused in outcome.refusedByPolicy { lines.append("  POLICY REFUSED \(refused)") }
        }

        for category in SWPCategory.allCases {
            let groups = result.groups(in: category)
            guard !groups.isEmpty else { continue }
            lines.append("")
            lines.append("== \(category.title.uppercased()) — \(groups.count) group(s), "
                         + SWPBytes.string(result.bytes(in: category)) + " ==")
            for group in groups {
                lines.append("  [\(group.confidence.label)] \(group.name) — "
                             + SWPBytes.string(group.sizeBytes))
                for item in group.items {
                    lines.append("      \(item.displayPath)  (\(SWPBytes.string(item.sizeBytes))"
                                 + (item.requiresAdmin ? ", admin" : "") + ")")
                }
            }
        }

        if !healthyStartup.isEmpty {
            lines.append("")
            lines.append("== STARTUP ITEMS LEFT ALONE (owned by installed apps) ==")
            for entry in healthyStartup {
                lines.append("  [\(entry.scopeLabel)] \(entry.label) → \(entry.program ?? "—")")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
