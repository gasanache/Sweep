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
/// state, so there is nothing to isolate.
final class SWPRemovalService {

    private let log = Logger(subsystem: "com.gasanache.sweep", category: "removal")

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
    private func authorisedMove(_ validated: [SWPItem]) -> SWPRemovalOutcome {
        var outcome = SWPRemovalOutcome()

        // Folder is unique per *run* (date + time), not per day: the in-batch
        // name de-duplication below cannot see files quarantined by an earlier
        // batch, and a same-named `mv -f` across two runs into one folder
        // would silently destroy a file the app promised was recoverable.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let quarantine = "\(NSHomeDirectory())/.Trash/Sweep \(formatter.string(from: Date()))"

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

        // Trust the filesystem rather than the exit status: report only what is
        // demonstrably gone.
        for item in validated where !FileManager.default.fileExists(atPath: item.url.path) {
            outcome.trashedCount += 1
            outcome.trashedBytes += item.sizeBytes
        }
        return outcome
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
