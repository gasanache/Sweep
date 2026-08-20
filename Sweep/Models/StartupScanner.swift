import Foundation

// MARK: - Startup entry

/// A third-party launch agent or daemon, healthy or not.
struct SWPStartupEntry: Identifiable, Hashable {
    let url: URL
    let label: String
    /// Executable the job launches, if the plist names one.
    let program: String?
    let isSystemWide: Bool

    var id: String { url.path }

    var scopeLabel: String { isSystemWide ? "System" : "User" }
}

// MARK: - Startup scanner

/// Enumerates what loads at login.
///
/// This is the only category that touches performance rather than disk space,
/// and it is the one most worth reading: a forgotten daemon costs CPU and RAM
/// every second the Mac is awake, while a stale cache costs nothing but bytes.
///
/// Two failure modes are treated as removable — a job whose executable no
/// longer exists (broken), and a job whose owning app is not installed
/// (orphaned). Everything else is reported read-only. Sweep will not offer to
/// disable a working background agent; that is a preference, not cleaning, and
/// the user is better served by System Settings.
struct SWPStartupScanner {

    private let inventory: SWPAppInventory
    private let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    init(inventory: SWPAppInventory) {
        self.inventory = inventory
    }

    private var directories: [(url: URL, systemWide: Bool)] {
        [
            (home.appendingPathComponent("Library/LaunchAgents", isDirectory: true), false),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), true),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), true),
        ]
    }

    /// Returns removable groups plus the healthy entries, which the Startup
    /// view lists underneath so the user can see the whole picture.
    func scan(progress: (String) -> Void) -> (groups: [SWPGroup], healthy: [SWPStartupEntry]) {
        var groups: [SWPGroup] = []
        var healthy: [SWPStartupEntry] = []

        for directory in directories {
            progress(directory.url.lastPathComponent)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []

            for url in children where url.pathExtension == "plist" {
                let label = url.deletingPathExtension().lastPathComponent
                guard !label.lowercased().hasPrefix("com.apple.") else { continue }

                let program = executablePath(in: url)
                let entry = SWPStartupEntry(url: url, label: label, program: program,
                                            isSystemWide: directory.systemWide)

                guard let reason = problem(with: entry) else {
                    healthy.append(entry)
                    continue
                }
                guard SWPSafety.validate(url).isAllowed else {
                    healthy.append(entry)
                    continue
                }

                let item = SWPItem(url: url,
                                   sizeBytes: max(SWPDiskSize.size(of: url), 1),
                                   modified: SWPDiskSize.modified(of: url),
                                   location: reason.location,
                                   requiresAdmin: SWPSafety.requiresAdmin(url))

                groups.append(SWPGroup(id: "startup.\(label)",
                                       name: label,
                                       category: .startup,
                                       confidence: reason.confidence,
                                       items: [item]))
            }
        }

        return (groups, healthy.sorted { $0.label < $1.label })
    }

    /// Why this job should be removed, or `nil` if it is fine.
    private func problem(with entry: SWPStartupEntry) -> (location: String,
                                                          confidence: SWPConfidence)? {
        // A job pointing at a missing binary is unambiguous: launchd retries it
        // at every login and it can never succeed. This check is filesystem
        // evidence, so it stands regardless of inventory health.
        if let program = entry.program, program.hasPrefix("/"),
           !FileManager.default.fileExists(atPath: program) {
            return ("Broken — target missing", .confirmed)
        }

        // Orphan verdicts below lean entirely on the inventory; without a
        // trustworthy one, report nothing rather than everything.
        guard inventory.isTrustworthy else { return nil }

        let canonical = SWPMatch.canonicalName(entry.label)
        if inventory.owns(canonical.name) { return nil }

        // The label says no installed app owns this, but the binary is still
        // there — often a shared updater. Worth reviewing, not asserting.
        if entry.program != nil { return ("Orphaned — no owning app", .likely) }
        return ("Orphaned — no owning app", .confirmed)
    }

    /// `Program`, else the first element of `ProgramArguments`.
    private func executablePath(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }

        if let program = plist["Program"] as? String { return program }
        if let arguments = plist["ProgramArguments"] as? [String] { return arguments.first }
        return nil
    }
}
