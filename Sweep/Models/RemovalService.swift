import Foundation
import AppKit
import os

// MARK: - Removal outcome

struct SWPRemovalOutcome {
    var trashedCount: Int = 0
    var trashedBytes: Int64 = 0
    var failures: [(path: String, reason: String)] = []
    var refusedByPolicy: [String] = []
    var adminCancelled: Bool = false

    mutating func merge(_ other: SWPRemovalOutcome) {
        trashedCount += other.trashedCount
        trashedBytes += other.trashedBytes
        failures += other.failures
        refusedByPolicy += other.refusedByPolicy
        adminCancelled = adminCancelled || other.adminCancelled
    }
}

// MARK: - Removal service

/// Everything that actually destroys something lives here, and it is the only
/// file in the project allowed to.
///
/// Two rules hold throughout:
///
/// 1. **Nothing is ever deleted, only trashed.** `FileManager.trashItem` keeps
///    Finder's "Put Back" metadata intact, so any mistake this app makes is
///    one right-click away from being undone. There is no code path that calls
///    `removeItem`.
/// 2. **`SWPSafety.validate` runs again here**, immediately before the trash
///    call, even though every scanner already validated. See the note on
///    `SWPSafety` for why the second check is not redundant.
///
/// Deliberately *not* `@MainActor`: trashing gigabytes and waiting on the
/// admin password prompt are blocking work, and running them on the main
/// actor froze the window for their whole duration (and meant the `.removing`
/// phase could never render — no suspension point existed between setting it
/// and clearing it). The stores call these methods from detached tasks and
/// publish the outcome back on the main actor. The class holds no mutable
/// state, so there is nothing to isolate — and the `Sendable` conformance now
/// makes the compiler check that claim rather than take the comment's word for
/// it (the only stored property is a `Logger`, which is itself Sendable).
final class SWPRemovalService: Sendable {

    private let log = Logger(subsystem: "com.gasanache.sweep", category: "removal")
    /// Same channel, reachable from the static manifest parser.
    private static let staticLog = Logger(subsystem: "com.gasanache.sweep", category: "removal")

    /// File name of the manifest written into every quarantine folder.
    static let manifestName = "sweep-manifest.tsv"

    /// A quarantine folder unique to this run. Date *and* time, because the
    /// in-batch name de-duplication cannot see files a previous batch already
    /// put there.
    static func quarantinePath(prefix: String = "Sweep") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(NSHomeDirectory())/.Trash/\(prefix) \(formatter.string(from: Date()))"
    }

    // MARK: Planning

    /// Collision-free file names for the admin quarantine folder.
    ///
    /// Two admin items can share a last path component — the same
    /// `com.vendor.service.plist` exists in both `/Library/LaunchAgents` and
    /// `/Library/LaunchDaemons` — and `mv -f` into a flat folder would let the
    /// second silently overwrite the first, destroying a file that was
    /// promised to be recoverable. Duplicates get a numbered suffix before
    /// the extension: `name.plist`, `name 2.plist`, `name 3.plist`.
    static func quarantineNames(for items: [SWPItem]) -> [String] {
        var used = Set<String>()
        return items.map { item in
            let base = item.url.lastPathComponent
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            var candidate = base
            var counter = 2
            while used.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    /// Drops every item that sits inside another selected item.
    ///
    /// Trashing the parent takes its descendants with it; attempting the child
    /// afterwards can only manufacture spurious failures (or, worse, hit an
    /// unrelated path that reappeared at the same name in between). The
    /// trailing "/" in the prefix test is load-bearing: without it,
    /// `/tmp/ab` would count as a descendant of `/tmp/a`.
    static func prunedOfDescendants(_ items: [SWPItem]) -> [SWPItem] {
        let sorted = items.sorted { $0.url.path < $1.url.path }
        var kept: [SWPItem] = []
        for item in sorted {
            let path = item.url.standardizedFileURL.path
            if kept.contains(where: { path.hasPrefix($0.url.standardizedFileURL.path + "/") }) {
                continue
            }
            kept.append(item)
        }
        return kept
    }

    // MARK: User-level

    /// Moves user-owned items to the Trash.
    func trash(_ items: [SWPItem]) -> SWPRemovalOutcome {
        var outcome = SWPRemovalOutcome()

        for item in items where !item.requiresAdmin {
            guard case .allowed = SWPSafety.validate(item.url) else {
                // Reaching here means a scanner proposed something the policy
                // forbids. Loud, because it is a bug rather than a user error.
                log.fault("policy refused at removal: \(item.url.path, privacy: .public)")
                outcome.refusedByPolicy.append(item.displayPath)
                continue
            }

            // A launch agent's job keeps running (and can respawn files) if
            // only its plist is removed — unload it from the user's launchd
            // domain first. Best-effort: an unloaded or never-loaded job just
            // returns an error we ignore.
            if item.url.path.hasPrefix(NSHomeDirectory() + "/Library/LaunchAgents/") {
                bootoutUserAgent(item.url)
            }

            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                outcome.trashedCount += 1
                outcome.trashedBytes += item.sizeBytes
            } catch {
                log.error("trash failed: \(item.url.path, privacy: .public)")
                outcome.failures.append((item.displayPath, error.localizedDescription))
            }
        }

        return outcome
    }

    // MARK: Uninstall

    /// Removes an application bundle together with its ticked residue.
    ///
    /// The bundle passes `validateAppBundle` — the uninstaller-only gate —
    /// while every residue re-passes the ordinary `validate`, exactly like the
    /// scan flow. The bundle is tried with `trashItem` first (Put Back
    /// intact); installer-laid apps owned by root fail that call and are
    /// routed into the same authorised batch as the `/Library` residue, so
    /// the user sees at most one password prompt.
    func uninstall(bundle: SWPItem, residues: [SWPItem]) -> SWPRemovalOutcome {
        var outcome = SWPRemovalOutcome()

        guard case .allowed = SWPSafety.validateAppBundle(bundle.url) else {
            log.fault("app bundle refused: \(bundle.url.path, privacy: .public)")
            outcome.refusedByPolicy.append(bundle.displayPath)
            return outcome
        }

        var userItems: [SWPItem] = []
        var adminItems: [SWPItem] = []
        for item in residues {
            guard case .allowed = SWPSafety.validate(item.url) else {
                log.fault("policy refused at uninstall: \(item.url.path, privacy: .public)")
                outcome.refusedByPolicy.append(item.displayPath)
                continue
            }
            if item.requiresAdmin { adminItems.append(item) } else { userItems.append(item) }
        }

        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: bundle.url, resultingItemURL: &resulting)
            outcome.trashedCount += 1
            outcome.trashedBytes += bundle.sizeBytes
        } catch {
            log.info("bundle needs authorisation: \(bundle.url.path, privacy: .public)")
            adminItems.insert(bundle, at: 0)
        }

        outcome.merge(trash(userItems))
        if !adminItems.isEmpty {
            outcome.merge(authorisedMove(adminItems))
        }
        return outcome
    }

    /// Unloads one job from the user's launchd domain. No authorisation
    /// needed — `gui/<uid>` belongs to the user.
    private func bootoutUserAgent(_ plist: URL) {
        let label = plist.deletingPathExtension().lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: Admin-level

    /// Moves root-owned `/Library` items into a dated folder inside the Trash,
    /// in one authorised batch.
    ///
    /// `trashItem` cannot touch these — the user is not root — so the work is
    /// done by an authorised `mv` into `~/.Trash/Sweep <date>/`. That preserves
    /// the "nothing is deleted" guarantee: the files are still there, still
    /// restorable by hand, just no longer loaded at boot.
    ///
    /// One prompt covers the whole batch. Asking per item would train the user
    /// to click through authorisation dialogs without reading them, which is a
    /// worse security outcome than a single reviewed prompt.
    func trashWithAuthorisation(_ items: [SWPItem]) -> SWPRemovalOutcome {
        var outcome = SWPRemovalOutcome()
        let admin = items.filter(\.requiresAdmin)
        guard !admin.isEmpty else { return outcome }

        var validated: [SWPItem] = []
        for item in admin {
            guard case .allowed = SWPSafety.validate(item.url) else {
                log.fault("policy refused at admin removal: \(item.url.path, privacy: .public)")
                outcome.refusedByPolicy.append(item.displayPath)
                continue
            }
            validated.append(item)
        }
        guard !validated.isEmpty else { return outcome }

        outcome.merge(authorisedMove(validated))
        return outcome
    }

    /// The authorised batch itself. Callers have already validated: scan-flow
    /// items via `SWPSafety.validate`, an uninstall's bundle via
    /// `validateAppBundle` — this method never receives an unvetted path.
    private func authorisedMove(_ validated: [SWPItem],
                                into folder: String? = nil) -> SWPRemovalOutcome {
        var outcome = SWPRemovalOutcome()
        let quarantine = folder ?? Self.quarantinePath()

        // No `set -e`: one stubborn file must not abandon the rest of the
        // batch mid-flight. Each mv reports its own failure on stdout instead,
        // and the script's exit status stays clean so partial success is not
        // misread as total failure.
        //
        // EVERY interpolation into this script is shellQuote'd, no exceptions.
        // This script runs as root; an unquoted filename is a command-
        // injection sink, and the first audit found exactly one — the
        // launchctl label below. Filenames are attacker-ish input even here.
        var lines = ["mkdir -p \(shellQuote(quarantine)) || echo SWPFAIL:mkdir"]
        let destinationNames = Self.quarantineNames(for: validated)
        for (index, item) in validated.enumerated() {
            // Unloading first matters for daemons: moving the plist alone leaves
            // the job running until the next reboot.
            if item.url.path.hasPrefix("/Library/LaunchDaemons/") {
                let label = item.url.deletingPathExtension().lastPathComponent
                lines.append("launchctl bootout \(shellQuote("system/\(label)")) 2>/dev/null || true")
            }
            let destination = quarantine + "/" + destinationNames[index]
            lines.append("mv -f \(shellQuote(item.url.path)) \(shellQuote(destination))"
                         + " || echo SWPFAIL:\(shellQuote(item.url.path))")
        }
        lines.append("chown -R \(shellQuote(NSUserName())) \(shellQuote(quarantine)) || true")

        let script = "do shell script \"\(appleScriptEscape(lines.joined(separator: "\n")))\""
            + " with administrator privileges"

        // `osascript` as a subprocess rather than `NSAppleScript`: the latter
        // is documented main-thread-only, and this method now runs on a
        // background thread precisely so the password prompt cannot freeze
        // the window. A child process may block its thread all it likes.
        let result = runOsascript(script)

        if let errorText = result.errorText {
            // -128 is the user clicking Cancel on the authorisation dialog —
            // nothing ran, so return without counting.
            if errorText.contains("(-128)") {
                outcome.adminCancelled = true
                return outcome
            }
            log.error("authorised removal failed: \(errorText, privacy: .public)")
            outcome.failures.append(("Administrator removal", errorText))
            // Fall through: some items may have moved before the failure, and
            // the filesystem check below is the only honest count.
        }

        for line in result.output.split(separator: "\n")
        where line.hasPrefix("SWPFAIL:") {
            outcome.failures.append((String(line.dropFirst("SWPFAIL:".count)),
                                     "could not be moved"))
        }

        // The manifest is written from Swift, AFTER the privileged script has
        // run and chowned the folder to the user.
        //
        // It used to be splice d into a `cat <<'SWPMANIFEST'` heredoc inside
        // that script — the one interpolation that was not shell-quoted. A file
        // name containing a newline terminated the heredoc early and the rest
        // of the name executed as root, and `/Library/Caches` is world-writable,
        // so planting such a name needed no privileges at all. Control
        // characters are now refused by `SWPSafety.validate` as well; this
        // removes the sink itself rather than relying on that one check.
        writeManifest(for: validated, names: destinationNames, in: quarantine)

        // Trust the filesystem rather than the exit status: report only what is
        // demonstrably gone.
        for item in validated where !FileManager.default.fileExists(atPath: item.url.path) {
            outcome.trashedCount += 1
            outcome.trashedBytes += item.sizeBytes
        }
        return outcome
    }

    /// Records quarantined name → original path, appending if the folder is
    /// shared with an earlier batch in the same run.
    private func writeManifest(for items: [SWPItem], names: [String], in folder: String) {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(Self.manifestName)
        var text = (try? String(contentsOf: url, encoding: .utf8))
            ?? "# Sweep quarantine — quarantined name\toriginal path\n"
        for (item, name) in zip(items, names)
        where !FileManager.default.fileExists(atPath: item.url.path) {
            text += "\(name)\t\(item.url.path)\n"
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Trash

    /// Opens the Trash in Finder.
    ///
    /// Sweep deliberately does not empty the Trash itself. Emptying is the one
    /// irreversible action in this whole workflow, and it belongs to Finder,
    /// where the user can see exactly what they are destroying.
    func revealTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    func reveal(_ item: SWPItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Startup jobs

    /// Unloads launch agents/daemons and moves their plists into a dated
    /// quarantine folder inside the Trash, with a manifest, so the action can
    /// be undone from inside the app.
    ///
    /// Disabling is *not* removal, which is why it has its own path: the job is
    /// working and its app is installed. The user is turning something off, so
    /// the mechanism has to be reversible by design rather than by accident.
    /// User-owned agents move without a password; only `/Library` jobs need one.
    func disableStartupJobs(_ entries: [SWPStartupEntry]) -> SWPRemovalOutcome {
        var outcome = SWPRemovalOutcome()
        guard !entries.isEmpty else { return outcome }

        var validated: [SWPStartupEntry] = []
        for entry in entries {
            guard case .allowed = SWPSafety.validate(entry.url) else {
                log.fault("policy refused startup disable: \(entry.url.path, privacy: .public)")
                outcome.refusedByPolicy.append(entry.url.lastPathComponent)
                continue
            }
            validated.append(entry)
        }
        guard !validated.isEmpty else { return outcome }

        let quarantine = URL(fileURLWithPath: Self.quarantinePath(prefix: "Sweep Disabled Startup"))
        let userEntries = validated.filter { !$0.isSystemWide }
        let systemEntries = validated.filter(\.isSystemWide)

        if !userEntries.isEmpty {
            try? FileManager.default.createDirectory(at: quarantine,
                                                     withIntermediateDirectories: true)
            var manifest = "# Sweep quarantine — quarantined name\toriginal path\n"
            let names = Self.quarantineNames(for: userEntries.map {
                SWPItem(url: $0.url, sizeBytes: 0, modified: nil, location: "", requiresAdmin: false)
            })
            for (index, entry) in userEntries.enumerated() {
                bootoutUserAgent(entry.url)
                let destination = quarantine.appendingPathComponent(names[index])
                do {
                    try FileManager.default.moveItem(at: entry.url, to: destination)
                    manifest += "\(names[index])\t\(entry.url.path)\n"
                    outcome.trashedCount += 1
                } catch {
                    outcome.failures.append((entry.url.lastPathComponent,
                                             error.localizedDescription))
                }
            }
            let manifestURL = quarantine.appendingPathComponent(Self.manifestName)
            let existing = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
            try? (existing + manifest).write(to: manifestURL, atomically: true, encoding: .utf8)
        }

        if !systemEntries.isEmpty {
            let items = systemEntries.map {
                SWPItem(url: $0.url, sizeBytes: 0, modified: nil,
                        location: "Startup", requiresAdmin: true)
            }
            outcome.merge(authorisedMove(items, into: quarantine.path))
        }
        return outcome
    }

    // MARK: Restore

    /// One restorable entry read back from a quarantine manifest.
    struct QuarantineEntry {
        let quarantined: URL
        let original: URL
    }

    /// Quarantine folders inside the Trash that still have a manifest and at
    /// least one file left to restore.
    static func restorableFolders() -> [URL] {
        let trash = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return children
            .filter { $0.lastPathComponent.hasPrefix("Sweep ") }
            .filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(manifestName).path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Parses a manifest into entries whose quarantined file still exists.
    static func entries(in folder: URL) -> [QuarantineEntry] {
        let manifest = folder.appendingPathComponent(manifestName)
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return [] }
        var entries: [QuarantineEntry] = []
        let folderPath = folder.standardizedFileURL.path
        for line in text.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            // The first column is a single quarantined FILE NAME, never a
            // path. Validating only the destination made this a
            // write-anywhere-as-root primitive: a manifest naming
            // `../../../../etc/sudoers` as its source would have had the
            // authorised `mv` move that file out of `/etc`. `appendingPathComponent`
            // does not sanitise `..`, so the check has to be explicit.
            let name = parts[0]
            guard !name.isEmpty, !name.contains("/"), name != "..", name != ".",
                  name.rangeOfCharacter(from: .controlCharacters) == nil else {
                Self.staticLog.fault("manifest source rejected: \(name, privacy: .public)")
                continue
            }
            let quarantined = folder.appendingPathComponent(name)
            // Belt and braces: after standardisation it must still be exactly
            // one component inside the quarantine folder.
            let quarantinedPath = quarantined.standardizedFileURL.path
            guard quarantinedPath.hasPrefix(folderPath + "/"),
                  !quarantinedPath.dropFirst(folderPath.count + 1).contains("/"),
                  FileManager.default.fileExists(atPath: quarantinedPath) else { continue }

            entries.append(QuarantineEntry(quarantined: quarantined,
                                           original: URL(fileURLWithPath: parts[1])))
        }
        return entries
    }

    /// Moves quarantined system files back where they came from.
    ///
    /// Restores only to paths the policy still accepts, so a tampered manifest
    /// cannot turn this into a "write anywhere as root" primitive — the same
    /// gate that authorised the removal authorises the reversal.
    func restore(from folder: URL) -> (restored: Int, failed: Int, cancelled: Bool) {
        let entries = Self.entries(in: folder)
        guard !entries.isEmpty else { return (0, 0, false) }

        var lines: [String] = []
        var attempted: [QuarantineEntry] = []
        for entry in entries {
            // Restore is gated by the same rules that authorised the removal —
            // including the app-bundle gate. Without that second clause an
            // application escalated into the authorised batch could never be
            // put back, because `/Applications` is deliberately outside
            // `allowedRoots`.
            let allowed = SWPSafety.validate(entry.original).isAllowed
                || SWPSafety.validateAppBundle(entry.original).isAllowed
            guard allowed else {
                log.fault("restore refused by policy: \(entry.original.path, privacy: .public)")
                continue
            }
            let parent = entry.original.deletingLastPathComponent().path
            lines.append("mkdir -p \(shellQuote(parent)) || true")
            lines.append("mv -n \(shellQuote(entry.quarantined.path)) "
                         + "\(shellQuote(entry.original.path)) || echo SWPFAIL")
            attempted.append(entry)
        }
        guard !lines.isEmpty else { return (0, entries.count, false) }

        let script = "do shell script \"\(appleScriptEscape(lines.joined(separator: "\n")))\""
            + " with administrator privileges"
        let result = runOsascript(script)
        if let errorText = result.errorText, errorText.contains("(-128)") {
            return (0, 0, true)
        }

        var restored = 0
        for entry in attempted where FileManager.default.fileExists(atPath: entry.original.path) {
            restored += 1
        }
        return (restored, attempted.count - restored, false)
    }

    // MARK: Subprocess

    /// Runs one AppleScript source via `/usr/bin/osascript` and captures the
    /// script's stdout plus, on failure, its stderr text.
    private func runOsascript(_ source: String) -> (output: String, errorText: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return ("", error.localizedDescription)
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus != 0 else { return (output, nil) }
        let errorText = (String(data: errorData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, errorText.isEmpty ? "authorisation failed" : errorText)
    }

    // MARK: Escaping

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a shell script for embedding in an AppleScript string literal.
    private func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
