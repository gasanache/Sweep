import Foundation
import AppKit
import os
import Darwin

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

/// Moves reviewed files into recoverable quarantine folders inside the Trash.
///
/// User moves hold no-follow source/destination directory descriptors through
/// an exclusive rename. The recovery manifest is written before moving a file.
/// Finder's Put Back metadata is not created; Sweep restores supported entries
/// from the manifest, and files remain available for manual recovery.
/// Policy is rechecked here, not just when scanners propose a path.
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
    private let startupCommand: @Sendable (String, [String]) -> SWPAppInventory.CommandResult

    init(startupCommand: @escaping @Sendable (String, [String]) -> SWPAppInventory.CommandResult = {
        SWPAppInventory.command($0, $1)
    }) {
        self.startupCommand = startupCommand
    }
    /// Same channel, reachable from the static manifest parser.
    private static let staticLog = Logger(subsystem: "com.gasanache.sweep", category: "removal")

    /// File name of the manifest written into every quarantine folder.
    static let manifestName = "sweep-manifest.tsv"

    /// The UUID, not the human-readable timestamp, separates concurrent batches.
    static func quarantinePath(prefix: String = "Sweep") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(NSHomeDirectory())/.Trash/\(prefix) \(formatter.string(from: Date())) \(UUID().uuidString)"
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
        var used: Set<String> = [manifestName.lowercased()]
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

    /// Moves user-owned items using the same bound quarantine path as uninstall.
    func trash(_ items: [SWPItem]) -> SWPRemovalOutcome {
        quarantineUserItems(items).outcome
    }

    /// Only the dedicated workflow calls this after checking its frozen plan,
    /// runtime and package state. Generic entry points never authorize these paths.
    func trashLocalAI(_ items: [SWPItem], product: SWPLocalAIProduct,
                      application: Bool = false) -> SWPRemovalOutcome {
        var outcome = SWPRemovalOutcome()
        var validated: [SWPItem] = []
        for item in items {
            let allowed = application
                ? items.count == 1 && Self.localAIProduct(at: item.url) == product
                    && SWPSafety.validateAppBundle(item.url).isAllowed
                : SWPSafety.validateLocalAI(item.url, product: product).isAllowed
            if allowed { validated.append(item) }
            else { outcome.refusedByPolicy.append(item.displayPath) }
        }
        let user = quarantineUserItems(validated, application: application ? validated.first?.url : nil,
                                       localAIProduct: product)
        outcome.merge(user.outcome)
        let admin = user.admin + (application ? [] : validated.filter(\.requiresAdmin))
        if !admin.isEmpty { outcome.merge(authorisedMove(admin)) }
        return outcome
    }

    private static func localAIProduct(at url: URL) -> SWPLocalAIProduct? {
        guard let identifier = SWPInstalledApps.infoPlist(in: url)?["CFBundleIdentifier"] as? String else { return nil }
        return SWPLocalAIScanner.product(forAppBundleID: identifier)
    }

    private func quarantineUserItems(_ items: [SWPItem], application: URL? = nil,
                                     prefix: String = "Sweep", localAIProduct: SWPLocalAIProduct? = nil)
        -> (outcome: SWPRemovalOutcome, admin: [SWPItem]) {
        var outcome = SWPRemovalOutcome()
        var admin: [SWPItem] = []
        let names = Self.quarantineNames(for: items)
        var quarantine: UserQuarantine?
        for (index, item) in items.enumerated() where !item.requiresAdmin || item.url == application {
            let isApplication = item.url == application
            let verdict = isApplication ? SWPSafety.validateAppBundle(item.url)
                : localAIProduct.map { SWPSafety.validateLocalAI(item.url, product: $0) } ?? SWPSafety.validate(item.url)
            guard verdict.isAllowed else {
                outcome.refusedByPolicy.append(item.displayPath)
                continue
            }
            do {
                // Opening with O_NOFOLLOW_ANY rejects an ancestor swapped after
                // validation. A later swap cannot redirect this held parent.
                // Policy permits only narrowly verified Local AI cache aliases;
                // rename moves a permitted link itself, never its target.
                let source = try BoundSource(item.url, allowSymbolicLink: true)
                let batch: UserQuarantine
                if let existing = quarantine {
                    batch = existing
                } else {
                    batch = try UserQuarantine(at: URL(fileURLWithPath: Self.quarantinePath(prefix: prefix)))
                    try Self.registerQuarantine(batch.url)
                    quarantine = batch
                }
                try stopStartupJob(at: item.url)
                try batch.move(source, name: names[index])
                outcome.trashedCount += 1
                outcome.trashedBytes += item.sizeBytes
            } catch {
                // Only a failed native rename may request administrator help.
                // Verification/manifest failures may follow a completed move
                // and must never retry the original pathname with more rights.
                let error = error as NSError
                if isApplication, error.domain == NSPOSIXErrorDomain,
                   error.code == Int(EACCES) || error.code == Int(EPERM) {
                    // The authorised batch requires every ancestor above the
                    // final parent to be root-owned and not group/world
                    // writable. `/Applications` itself is admin-writable, so
                    // only its direct children can pass; anything nested would
                    // always fail with a misleading "path substitution" error.
                    if item.url.deletingLastPathComponent().path == "/Applications" {
                        admin.append(item)
                    } else {
                        outcome.failures.append((item.displayPath,
                            "This app needs administrator rights to move, and Sweep only does that for apps directly inside /Applications. Remove it with its vendor's uninstaller or in Finder."))
                    }
                } else {
                    outcome.failures.append((item.displayPath, error.localizedDescription))
                }
            }
        }
        return (outcome, admin)
    }

    // MARK: Uninstall

    /// Removes an application bundle together with its ticked residue.
    ///
    /// The bundle passes `validateAppBundle`; residues pass the ordinary gate.
    /// User-accessible bundles and residues share one recoverable quarantine.
    /// A native permission denial can route the bundle to the authorised batch.
    func uninstall(bundle: SWPItem, residues: [SWPItem]) -> SWPRemovalOutcome {
        var outcome = SWPRemovalOutcome()

        guard case .allowed = SWPSafety.validateAppBundle(bundle.url),
              Self.localAIProduct(at: bundle.url) == nil else {
            log.fault("app bundle refused: \(bundle.url.path, privacy: .public)")
            outcome.refusedByPolicy.append(bundle.displayPath)
            return outcome
        }

        var userItems: [SWPItem] = [bundle]
        var adminItems: [SWPItem] = []
        for item in residues {
            guard case .allowed = SWPSafety.validate(item.url) else {
                log.fault("policy refused at uninstall: \(item.url.path, privacy: .public)")
                outcome.refusedByPolicy.append(item.displayPath)
                continue
            }
            if item.requiresAdmin { adminItems.append(item) } else { userItems.append(item) }
        }

        let user = quarantineUserItems(userItems, application: bundle.url)
        outcome.merge(user.outcome)
        adminItems.append(contentsOf: user.admin)
        if !adminItems.isEmpty {
            outcome.merge(authorisedMove(adminItems))
        }
        return outcome
    }

    /// launchd identifies jobs by their plist Label, not the filename. System
    /// LaunchAgents run in the current GUI domain, not the system daemon domain.
    static func startupTarget(for plist: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String? {
        guard let domain = startupDomain(for: plist, home: home) else { return nil }
        guard let label = SWPStartupScanner.jobLabel(in: plist),
              !label.lowercased().hasPrefix("com.apple.") else {
            throw boundaryError("Cannot verify this startup item's Label; manage it in System Settings.")
        }
        return domain + "/" + label
    }

    static func startupDomain(for plist: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let parent = plist.deletingLastPathComponent().path
        if parent == "/Library/LaunchDaemons" { return "system" }
        if parent == "/Library/LaunchAgents" || parent == home.appendingPathComponent("Library/LaunchAgents").path {
            return "gui/\(getuid())"
        }
        return nil
    }

    func stopStartupJob(at plist: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let target = try Self.startupTarget(for: plist, home: home) else { return }
        let before = startupCommand("/bin/launchctl", ["print", target])
        if before.status == 113, before.failure == nil { return }
        guard before.succeeded, before.output.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "path = " + plist.path
        }) else { throw Self.boundaryError("The loaded startup job could not be verified against its configuration. No file was moved.") }
        let stopped = startupCommand("/bin/launchctl", ["bootout", target])
        guard stopped.succeeded else {
            throw Self.boundaryError("Could not unload \(target): \(stopped.failure ?? stopped.output)")
        }
        let after = startupCommand("/bin/launchctl", ["print", target])
        guard after.status == 113, after.failure == nil else {
            throw Self.boundaryError("The startup job remained loaded or its stopped state could not be verified. No file was moved.")
        }
    }

    // MARK: Admin-level

    /// Moves root-owned `/Library` items into a dated folder inside the Trash,
    /// in one authorised batch.
    ///
    /// An authorised move into a quarantine under `~/.Trash` preserves the
    /// files and records their original paths for supported or manual recovery.
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
        let trash = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
        let quarantine = URL(fileURLWithPath: Self.quarantinePath())
        let names = Self.quarantineNames(for: validated)
        var prepared: [(index: Int, item: SWPItem, binding: MoveBinding, startup: String?)] = []
        for (index, item) in validated.enumerated() {
            do {
                prepared.append((index, item, try Self.bindMoveSource(item.url), try Self.startupTarget(for: item.url)))
            } catch {
                outcome.failures.append((item.displayPath, error.localizedDescription))
            }
        }
        guard !prepared.isEmpty else { return outcome }

        let trashIdentity: String
        do {
            // Inspect the Trash entry through its no-follow home descriptor;
            // listing/opening the Trash root itself can require Full Disk Access.
            let boundTrash = try BoundSource(trash)
            trashIdentity = boundTrash.fileIdentity
            try Self.registerQuarantine(quarantine)
        } catch {
            outcome.failures.append(("Trash", error.localizedDescription))
            return outcome
        }
        defer {
            var metadata = stat()
            if lstat(quarantine.path, &metadata) != 0, errno == ENOENT {
                Self.forgetQuarantine(quarantine)
            }
        }
        let q = Self.shellQuote
        var lines = [Self.commandPrelude, """
        cd -P \(q(trash.path)) || exit 1
        swp_identity . \(q(trashIdentity)) || { echo 'SWPBATCHFAIL:Trash changed after review'; exit 1; }
        [ "$(/usr/bin/stat -f %u .)" = \(getuid()) ] || { echo 'SWPBATCHFAIL:Trash is not owned by this user'; exit 1; }
        /bin/mkdir -m 700 \(q("./" + quarantine.lastPathComponent)) || { echo 'SWPBATCHFAIL:Quarantine already exists or cannot be created'; exit 1; }
        cd -P \(q("./" + quarantine.lastPathComponent)) || exit 1
        swp_protected . && [ "$(/usr/bin/stat -f %Lp .)" = 700 ] || { echo 'SWPBATCHFAIL:Quarantine is not private'; exit 1; }
        for entry in ./* ./.[!.]* ./..?*; do
            if [ -e "$entry" ] || [ -L "$entry" ]; then echo 'SWPBATCHFAIL:Quarantine is not empty'; exit 1; fi
        done
        set -C
        /usr/bin/printf '%s\\n' '# Sweep quarantine — quarantined name\toriginal path' > \(q("./" + Self.manifestName)) || exit 1
        """]
        for entry in prepared {
            let source = entry.item.url
            let checks = Self.directoryChecks(entry.binding.parents, protectFinal: false)
            let beforeMove = entry.startup.map { "swp_stop_job \(q($0)) \(q(source.path))" } ?? ":"
            let move = Self.moveCommand(
                source: source.path, destination: "./" + names[entry.index],
                identity: entry.binding.identity, index: entry.index,
                manifestRow: names[entry.index] + "\t" + source.path + "\t" + entry.binding.identity,
                beforeMove: beforeMove)
            lines.append("""
            if \(checks); then
            \(move)
            else
                echo 'SWPFAIL:\(entry.index):Source ancestors changed or permit path substitution'
            fi
            """)
        }
        // All operations remain relative to this held directory. Never chown
        // selected contents, recursively or otherwise. Root ownership also
        // makes a later privileged restore safe to read from a held cwd.
        lines.append("""
        /bin/chmod 644 \(q("./" + Self.manifestName)) || echo 'SWPBATCHFAIL:Manifest could not be made readable'
        /bin/chmod 755 . || echo 'SWPBATCHFAIL:Quarantine could not be made readable'
        """)
        let result = runOsascript(Self.authorisationScript(lines.joined(separator: "\n")))
        if let errorText = result.errorText {
            if errorText.contains("(-128)") {
                outcome.adminCancelled = true
                return outcome
            }
            outcome.failures.append(("Administrator removal", errorText))
        }
        let completed = Self.completedIndices(in: result.output)
        let failures = Self.commandFailures(in: result.output)
        for entry in prepared {
            if completed.contains(entry.index) {
                outcome.trashedCount += 1
                outcome.trashedBytes += entry.item.sizeBytes
            } else {
                outcome.failures.append((entry.item.displayPath,
                    failures[entry.index] ?? "No verified move was reported; the item may need manual recovery."))
            }
        }
        for line in Self.outputLines(result.output) where line.hasPrefix("SWPBATCHFAIL:") {
            outcome.failures.append(("Administrator removal", String(line.dropFirst(13))))
        }
        return outcome
    }

    struct DirectoryBinding {
        let path: String
        let identity: String
    }

    struct MoveBinding {
        let identity: String
        let parents: [DirectoryBinding]
    }

    private static func boundaryError(_ message: String) -> NSError {
        NSError(domain: "Sweep.Removal", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func fileIdentity(_ url: URL) throws -> String {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT != S_IFLNK else {
            throw boundaryError("The selected item is missing, linked, or inaccessible.")
        }
        return "\(metadata.st_dev):\(metadata.st_ino)"
    }

    private static func directoryIdentity(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else {
            throw boundaryError("A directory is missing, linked, or inaccessible: \(url.path)")
        }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            throw boundaryError("Could not identify directory: \(url.path)")
        }
        return "\(metadata.st_dev):\(metadata.st_ino)"
    }

    private static func bindParents(of url: URL) throws -> [DirectoryBinding] {
        var parent = url.deletingLastPathComponent()
        var parents: [DirectoryBinding] = []
        while true {
            parents.append(DirectoryBinding(path: parent.path,
                                            identity: try directoryIdentity(parent)))
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }
        return parents.reversed()
    }

    private static func bindMoveSource(_ url: URL) throws -> MoveBinding {
        let parents = try bindParents(of: url)
        return MoveBinding(identity: try fileIdentity(url), parents: parents)
    }

    /// Ancestors that name the final parent must not be mutable by non-root
    /// users. The removal's final parent may be writable: mv renames its leaf
    /// without traversing the leaf. Restore destinations require it protected
    /// too, because BSD mv -n is not an atomic no-replace rename.
    private static func directoryChecks(_ parents: [DirectoryBinding],
                                        protectFinal: Bool) -> String {
        parents.enumerated().map { index, parent in
            let quoted = shellQuote(parent.path)
            let identity = "swp_directory \(quoted) \(shellQuote(parent.identity))"
            return index == parents.count - 1 && !protectFinal
                ? identity : identity + " && swp_protected " + quoted
        }.joined(separator: " && ")
    }

    static let commandPrelude = """
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    LC_ALL=C
    export LC_ALL
    umask 077
    swp_identity() {
        [ ! -L "$1" ] && [ "$(/usr/bin/stat -f '%d:%i' "$1" 2>/dev/null)" = "$2" ]
    }
    swp_directory() {
        [ -d "$1" ] && swp_identity "$1" "$2"
    }
    swp_stop_job() {
        swp_job=$(/bin/launchctl print "$1" 2>&1)
        swp_status=$?
        [ "$swp_status" = 113 ] && return 0
        [ "$swp_status" = 0 ] || return 1
        # Fixed complete-line comparisons; path text never becomes a regex.
        /usr/bin/printf '%s\\n' "$swp_job" | /usr/bin/grep -F -x -e "\tpath = $2" -e "    path = $2" -e "path = $2" >/dev/null || return 1
        /bin/launchctl bootout "$1" >/dev/null 2>&1 || return 1
        /bin/launchctl print "$1" >/dev/null 2>&1
        [ "$?" = 113 ]
    }
    swp_no_acl() {
        swp_acl=$(/bin/ls -lde "$1") || return 1
        case "$swp_acl" in *'
    '*) return 1 ;; esac
    }
    swp_protected() {
        [ -d "$1" ] && [ ! -L "$1" ] || return 1
        [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || return 1
        swp_mode=$(/usr/bin/stat -f %Lp "$1") || return 1
        [ "$((0$swp_mode & 022))" = 0 ] || return 1
        swp_no_acl "$1"
    }
    """

    /// Used only with a held, protected destination and stable source parents
    /// (or the inverse on restore). Same-device checks avoid mv's recursive
    /// copy/delete fallback. Success means the expected inode reached the
    /// intended name and the old name is absent, not merely that mv exited 0.
    static func moveCommand(source: String, destination: String, identity: String,
                            index: Int, manifestRow: String? = nil,
                            beforeMove: String = "") -> String {
        let s = shellQuote(source), d = shellQuote(destination)
        let parent = shellQuote((destination as NSString).deletingLastPathComponent)
        let manifest = manifestRow.map {
            let file = shellQuote("./" + manifestName)
            let rowBytes = $0.utf8.count + 1
            return "[ -f \(file) ] && [ ! -L \(file) ] && [ $(( $(/usr/bin/stat -f '%z' \(file)) + \(rowBytes) )) -le 1048576 ] && /usr/bin/printf '%s\\n' \(shellQuote($0)) >> \(file) && /bin/sync"
        } ?? ":"
        let prepare = beforeMove.isEmpty ? ":" : beforeMove
        return """
        if ! swp_identity \(s) \(shellQuote(identity)); then
            echo 'SWPFAIL:\(index):Source changed after review'
        elif [ -e \(d) ] || [ -L \(d) ]; then
            echo 'SWPFAIL:\(index):Destination already exists'
        elif [ "$(/usr/bin/stat -f %d \(s))" != "$(/usr/bin/stat -f %d \(parent))" ]; then
            echo 'SWPFAIL:\(index):Cross-volume moves require manual recovery'
        elif ! ( \(manifest) ); then
            echo 'SWPFAIL:\(index):Recovery intent could not be saved; no file was moved'
        elif ! ( \(prepare) ); then
            echo 'SWPFAIL:\(index):Startup job could not be verified stopped; no file was moved'
        else
            swp_identity \(s) \(shellQuote(identity)) && /bin/mv -n -h \(s) \(d)
            if [ ! -e \(s) ] && [ ! -L \(s) ] && swp_identity \(d) \(shellQuote(identity)); then
                echo 'SWPOK:\(index)'
            else
                echo 'SWPFAIL:\(index):The intended move could not be verified'
            fi
        fi
        """
    }

    /// `do shell script` rewrites `\n` to `\r` unless told not to. The script
    /// asks it not to, and the parsers still accept any line ending so a
    /// multi-item batch can never collapse into one unparseable line.
    static func outputLines(_ output: String) -> [Substring] {
        output.split(whereSeparator: \.isNewline)
    }

    static func completedIndices(in output: String) -> Set<Int> {
        Set(outputLines(output).compactMap { line in
            guard line.hasPrefix("SWPOK:") else { return nil }
            return Int(line.dropFirst(6))
        })
    }

    private static func commandFailures(in output: String) -> [Int: String] {
        var failures: [Int: String] = [:]
        for line in outputLines(output) where line.hasPrefix("SWPFAIL:") {
            let fields = line.dropFirst(8).split(separator: ":", maxSplits: 1)
            if fields.count == 2, let index = Int(fields[0]) {
                failures[index] = String(fields[1])
            }
        }
        return failures
    }

    private static func authorisationScript(_ command: String) -> String {
        "do shell script \"\(appleScriptEscape(command))\" with administrator privileges without altering line endings"
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

        let userEntries = validated.filter { !$0.isSystemWide }
        let systemEntries = validated.filter(\.isSystemWide)

        if !userEntries.isEmpty {
            let items = userEntries.map {
                SWPItem(url: $0.url, sizeBytes: 0, modified: nil,
                        location: "Startup", requiresAdmin: false)
            }
            outcome.merge(quarantineUserItems(items, prefix: "Sweep Disabled Startup").outcome)
        }

        if !systemEntries.isEmpty {
            let items = systemEntries.map {
                SWPItem(url: $0.url, sizeBytes: 0, modified: nil,
                        location: "Startup", requiresAdmin: true)
            }
            outcome.merge(authorisedMove(items))
        }
        return outcome
    }

    // MARK: Restore

    /// One restorable entry read back from a quarantine manifest.
    struct QuarantineEntry {
        let quarantined: URL
        let original: URL
    }

    // macOS can permit access to a known Trash child while denying enumeration
    // of .Trash itself. Keep only our generated batch names, not file contents,
    // so recovery also works after relaunch without new privacy permissions.
    private static let quarantineIndexPrefix = "sweep.quarantine."

    private static func registerQuarantine(_ folder: URL) throws {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: quarantineIndexPrefix + folder.lastPathComponent)
        guard defaults.synchronize() else {
            throw boundaryError("The recovery index could not be saved; no files were moved.")
        }
    }

    private static func forgetQuarantine(_ folder: URL) {
        guard folder.deletingLastPathComponent().path == NSHomeDirectory() + "/.Trash" else { return }
        UserDefaults.standard.removeObject(forKey: quarantineIndexPrefix + folder.lastPathComponent)
    }

    /// Quarantine folders inside the Trash that still have a manifest and at
    /// least one file left to restore.
    static func restorableFolders() -> [URL] {
        let trash = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        var paths = Set(children.map(\.path))
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation()
            where key.hasPrefix(quarantineIndexPrefix) && (value as? Bool) == true {
            let name = String(key.dropFirst(quarantineIndexPrefix.count))
            guard name.hasPrefix("Sweep "), !name.contains("/"),
                  name.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
            let folder = trash.appendingPathComponent(name, isDirectory: true)
            var metadata = stat()
            if lstat(folder.path, &metadata) != 0, errno == ENOENT {
                defaults.removeObject(forKey: key)
                continue
            }
            paths.insert(folder.path)
        }
        return paths.compactMap { path -> (url: URL, date: Date)? in
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            guard folder.lastPathComponent.hasPrefix("Sweep "),
                  !entries(in: folder).isEmpty else { return nil }
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (folder, date)
        }.sorted { left, right in
            left.date == right.date ? left.url.lastPathComponent > right.url.lastPathComponent : left.date > right.date
        }.map(\.url)
    }

    /// Parses a manifest into entries whose quarantined file still exists.
    static func entries(in folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [QuarantineEntry] {
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { return [] }
        defer { close(directory) }
        let manifestFD = openat(directory, manifestName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard manifestFD >= 0 else { return [] }
        let manifest = FileHandle(fileDescriptor: manifestFD, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(manifestFD, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= 1_048_576,
              let data = try? manifest.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var entries: [QuarantineEntry] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            // Old two-column manifests remain readable for existing Trash
            // batches. New records bind the quarantined inode as well.
            guard parts.count == 2 || parts.count == 3 else { continue }

            // The first column is a single quarantined FILE NAME, never a
            // path. Validating only the destination made this a
            // write-anywhere-as-root primitive: a manifest naming
            // `../../../../etc/sudoers` as its source would have had the
            // authorised `mv` move that file out of `/etc`. `appendingPathComponent`
            // does not sanitise `..`, so the check has to be explicit.
            let name = parts[0]
            guard !name.isEmpty, !name.contains("/"), name != "..", name != ".",
                  name.lowercased() != manifestName.lowercased(),
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  parts[1].hasPrefix("/"),
                  parts[1].rangeOfCharacter(from: .controlCharacters) == nil,
                  !parts[1].split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                Self.staticLog.fault("manifest source rejected: \(name, privacy: .public)")
                continue
            }
            let quarantined = folder.appendingPathComponent(name)
            var source = stat()
            guard fstatat(directory, name, &source, AT_SYMLINK_NOFOLLOW) == 0,
                  parts.count == 2 || parts[2] == "\(source.st_dev):\(source.st_ino)" else { continue }
            let original = URL(fileURLWithPath: parts[1])
            if source.st_mode & S_IFMT == S_IFLNK {
                guard parts.count == 3,
                      SWPLocalAIScanner.isOwnedBrewCacheAlias(original, product: .ollama,
                          home: home, storedAt: quarantined) else { continue }
            }
            guard seen.insert(name.lowercased()).inserted else { continue }
            entries.append(QuarantineEntry(quarantined: quarantined, original: original))
        }
        return entries
    }

    /// Moves quarantined files back where they came from.
    ///
    /// Restores only to paths the policy still accepts, so a tampered manifest
    /// cannot turn this into a "write anywhere as root" primitive — the same
    /// gate that authorised the removal authorises the reversal.
    func restore(from folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> (restored: Int, failed: Int, cancelled: Bool, failures: [String]) {
        let entries = Self.entries(in: folder, home: home)
        guard !entries.isEmpty else { return (0, 0, false, []) }
        var restored = 0
        var failures: [String] = []
        var admin: [(index: Int, entry: QuarantineEntry, binding: MoveBinding)] = []
        for (index, entry) in entries.enumerated() {
            let cacheAlias = SWPLocalAIScanner.isOwnedBrewCacheAlias(entry.original, product: .ollama,
                home: home, storedAt: entry.quarantined)
            let allowed = cacheAlias || SWPSafety.validateForRestore(entry.original).isAllowed
                || SWPSafety.validateAppBundle(entry.original).isAllowed
            guard allowed else {
                failures.append("\(entry.original.path): Restore refused by safety policy.")
                continue
            }
            do {
                try Self.moveExclusively(from: entry.quarantined, to: entry.original, allowSymbolicLink: cacheAlias)
                restored += 1
            } catch {
                // User restores never escalate. In particular, a replaced
                // home-directory ancestor must not become a root write.
                guard entry.original.path.hasPrefix("/Library/")
                        || entry.original.path.hasPrefix("/Applications/") else {
                    failures.append("\(entry.original.path): \(error.localizedDescription)")
                    continue
                }
                do {
                    let parents = try Self.bindParents(of: entry.original)
                    admin.append((index, entry, MoveBinding(
                        identity: try Self.fileIdentity(entry.quarantined), parents: parents)))
                } catch {
                    failures.append("\(entry.original.path): \(error.localizedDescription)")
                }
            }
        }
        guard !admin.isEmpty else {
            if restored == entries.count { Self.forgetQuarantine(folder) }
            return (restored, entries.count - restored, false, failures)
        }

        let folderIdentity: String
        do {
            guard folder.deletingLastPathComponent().path == NSHomeDirectory() + "/.Trash" else {
                throw Self.boundaryError("Privileged restore requires a direct quarantine folder in your Trash.")
            }
            folderIdentity = try Self.directoryIdentity(folder)
        } catch {
            failures.append(error.localizedDescription)
            return (restored, entries.count - restored, false, failures)
        }
        let q = Self.shellQuote
        var lines = [Self.commandPrelude, """
        cd -P \(q(folder.path)) || exit 1
        swp_identity . \(q(folderIdentity)) || { echo 'SWPBATCHFAIL:Quarantine changed after review'; exit 1; }
        swp_no_acl . || { echo 'SWPBATCHFAIL:Quarantine has an unverifiable access-control list'; exit 1; }
        swp_owner=$(/usr/bin/stat -f %u .) || exit 1
        if [ "$swp_owner" = \(getuid()) ]; then
            swp_original_mode=$(/usr/bin/stat -f %Lp .) || exit 1
            trap '/bin/chmod "$swp_original_mode" .; /usr/sbin/chown \(getuid()) .' EXIT
            /usr/sbin/chown 0 . && /bin/chmod 700 . || exit 1
        elif [ "$swp_owner" != 0 ]; then
            echo 'SWPBATCHFAIL:Quarantine has an unexpected owner'; exit 1
        fi
        swp_protected . || { echo 'SWPBATCHFAIL:Quarantine permits concurrent entry replacement'; exit 1; }
        """]
        for item in admin {
            lines.append("""
            if \(Self.directoryChecks(item.binding.parents, protectFinal: true)); then
            \(Self.moveCommand(source: "./" + item.entry.quarantined.lastPathComponent,
                               destination: item.entry.original.path,
                               identity: item.binding.identity, index: item.index))
            else
                echo 'SWPFAIL:\(item.index):Restore requires existing root-owned destination ancestors without group/world write access or ACLs; restore this item manually'
            fi
            """)
        }
        let result = runOsascript(Self.authorisationScript(lines.joined(separator: "\n")))
        if let errorText = result.errorText, errorText.contains("(-128)") {
            return (restored, failures.count, true, failures)
        }
        let completed = Self.completedIndices(in: result.output)
        let commandFailures = Self.commandFailures(in: result.output)
        for item in admin {
            if completed.contains(item.index) {
                restored += 1
            } else {
                failures.append("\(item.entry.original.path): "
                    + (commandFailures[item.index] ?? result.errorText ?? "No verified restore was reported."))
            }
        }
        for line in Self.outputLines(result.output) where line.hasPrefix("SWPBATCHFAIL:") {
            failures.append(String(line.dropFirst(13)))
        }
        if restored == entries.count { Self.forgetQuarantine(folder) }
        return (restored, entries.count - restored, false, failures)
    }

    private static func createUserQuarantine(at url: URL) throws -> Int32 {
        // Creating one unpredictable empty child does not require listing the
        // protected Trash root. It cannot overwrite anything. Before any data
        // moves, open that exact child with no-follow checks on every ancestor.
        guard mkdir(url.path, 0o700) == 0 else {
            throw boundaryError("The quarantine already exists or cannot be created.")
        }
        let directory = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { throw boundaryError("The quarantine could not be opened safely.") }
        return directory
    }

    /// User-level moves use Darwin's atomic no-replace rename and held parent
    /// descriptors. No Foundation move fallback can copy/delete across volumes.
    static func moveExclusively(from source: URL, to destination: URL, allowSymbolicLink: Bool = false) throws {
        let directory = open(destination.deletingLastPathComponent().path,
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else {
            throw boundaryError("The destination parent is missing, linked, or inaccessible.")
        }
        defer { close(directory) }
        var metadata = stat()
        guard fstat(directory, &metadata) == 0 else {
            throw boundaryError("The destination parent could not be identified.")
        }
        let bound = try BoundSource(source, allowSymbolicLink: allowSymbolicLink)
        try bound.move(into: directory, name: destination.lastPathComponent)
        guard try directoryIdentity(destination.deletingLastPathComponent()) == "\(metadata.st_dev):\(metadata.st_ino)" else {
            throw boundaryError("The destination folder moved during restore; inspect the destination before retrying.")
        }
    }


    /// A noncopyable descriptor owner: the validated name cannot be redirected
    /// through a replaced ancestor while bootout, manifest I/O, or a move runs.
    struct BoundSource: ~Copyable {
        let url: URL
        private let parent: Int32
        private let device: dev_t
        private let inode: ino_t
        var fileIdentity: String { "\(device):\(inode)" }

        init(_ url: URL, allowSymbolicLink: Bool = false) throws {
            let parent = open(url.deletingLastPathComponent().path,
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard parent >= 0 else {
                throw SWPRemovalService.boundaryError("The source parent is missing, linked, or inaccessible.")
            }
            var identity = stat()
            guard fstatat(parent, url.lastPathComponent, &identity, AT_SYMLINK_NOFOLLOW) == 0,
                  allowSymbolicLink || identity.st_mode & S_IFMT != S_IFLNK else {
                close(parent)
                throw SWPRemovalService.boundaryError("The source is missing, linked, or inaccessible.")
            }
            self.url = url
            self.parent = parent
            self.device = identity.st_dev
            self.inode = identity.st_ino
        }

        deinit { close(parent) }

        func move(into destination: Int32, name: String) throws {
            var current = stat()
            guard fstatat(parent, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == device, current.st_ino == inode else {
                throw SWPRemovalService.boundaryError("The selected item changed before it could be moved.")
            }
            guard renameatx_np(parent, url.lastPathComponent, destination, name, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey:
                                "The destination already exists, the move crosses volumes, or permissions prevent moving this item."])
            }
            var after = stat(), remaining = stat()
            guard fstatat(destination, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  after.st_dev == device, after.st_ino == inode,
                  fstatat(parent, url.lastPathComponent, &remaining, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else {
                throw SWPRemovalService.boundaryError("The intended move could not be verified; inspect the quarantine before retrying.")
            }
        }
    }

    /// One private batch, with its destination and manifest held open. Intent
    /// records are durable before rename; only matching moved inodes restore.
    final class UserQuarantine {
        let url: URL
        private let directory: Int32
        private let identity: String
        private let manifest: FileHandle
        private var manifestBytes: Int
        private var manifestUsable = true

        init(at url: URL) throws {
            let directory = try SWPRemovalService.createUserQuarantine(at: url)
            do {
                var metadata = stat()
                guard fstat(directory, &metadata) == 0, metadata.st_uid == getuid() else {
                    throw SWPRemovalService.boundaryError("The quarantine has an unexpected owner.")
                }
                let descriptor = openat(directory, SWPRemovalService.manifestName,
                                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else {
                    throw SWPRemovalService.boundaryError("The recovery manifest could not be exclusively created.")
                }
                let manifest = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                let header = Data("# Sweep quarantine — quarantined name\toriginal path\n".utf8)
                try manifest.write(contentsOf: header)
                self.url = url
                self.directory = directory
                self.identity = "\(metadata.st_dev):\(metadata.st_ino)"
                self.manifest = manifest
                self.manifestBytes = header.count
            } catch {
                close(directory)
                throw error
            }
        }

        deinit { close(directory) }

        func move(_ source: borrowing BoundSource, name: String) throws {
            guard try SWPRemovalService.directoryIdentity(url) == identity else {
                throw SWPRemovalService.boundaryError("The quarantine moved or changed; no further files will be moved.")
            }
            let row = Data("\(name)\t\(source.url.path)\t\(source.fileIdentity)\n".utf8)
            guard manifestUsable, manifestBytes + row.count <= 1_048_576 else {
                throw SWPRemovalService.boundaryError("The recovery manifest is unavailable or full; this item was left in place.")
            }
            do {
                try manifest.write(contentsOf: row)
                try manifest.synchronize()
                manifestBytes += row.count
            } catch {
                manifestUsable = false
                throw SWPRemovalService.boundaryError("The recovery record could not be saved; this item was left in place.")
            }
            try source.move(into: directory, name: name)
            guard try SWPRemovalService.directoryIdentity(url) == identity else {
                throw SWPRemovalService.boundaryError("The quarantine moved during removal; find the batch before retrying.")
            }
        }
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

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a shell script for embedding in an AppleScript string literal.
    private static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
