import Foundation
import os
import Darwin

// MARK: - App inventory

/// An index of everything installed on this Mac, used to decide whether a
/// leftover file still has an owner.
///
/// This is the half of the product that matters. The sweep is trivial —
/// enumerate `~/Library` — but deciding "no app owns this any more" is where a
/// cleaner either earns trust or eats someone's VPN profile. A hand audit of
/// this machine flagged Cisco AnyConnect, IHG, Versa and VSG as orphaned until
/// UUID container resolution was added, and Navicat until vendor-word matching
/// was. Both fixes live here.
struct SWPAppInventory {

    private static let log = Logger(subsystem: "com.gasanache.sweep", category: "inventory")

    /// Exact bundle identifiers, lowercased.
    private(set) var bundleIDs: Set<String> = []
    /// Second component of each bundle id — "macpaw", "microsoft", "cisco".
    private(set) var vendorWords: Set<String> = []
    /// Normalised app and executable names.
    private(set) var nameTokens: Set<String> = []
    /// Homebrew formulae, casks and anything on `PATH`, so that developer
    /// tooling with a `~/Library/Application Support` folder is not mistaken
    /// for a deleted app.
    private(set) var commandNames: Set<String> = []

    /// Reverse-DNS identifiers gathered from sources other than app bundles:
    /// installer package receipts, loaded launchd jobs, and running processes.
    ///
    /// These exist because plenty of software has no `.app` at all — kernel and
    /// system extensions, printer and audio drivers, VPN helpers, agents. On
    /// this Mac, Paragon NTFS and Razer are exactly that shape: a driver plus a
    /// daemon, no bundle in `/Applications`. Without these signals their
    /// support folders read as orphaned. Every one of them is a *keep* signal,
    /// so adding them can only ever reduce false positives.
    private(set) var liveIdentifiers: Set<String> = []

    private(set) var appCount: Int = 0

    /// Whether the index is complete enough to support "no app owns this"
    /// claims.
    ///
    /// Every Mac carries dozens of bundled Apple apps, so a tiny inventory
    /// does not mean a sparse machine — it means the build itself failed
    /// (Spotlight re-indexing, a blocked walk). An index in that state would
    /// make *everything* on disk read as orphaned, so below this floor the
    /// inferential scanners refuse to run at all. Failing closed here is the
    /// difference between "the scan found nothing" and "the scan invented
    /// 400 orphans".
    var isTrustworthy: Bool { appCount >= 40 && bundleIDs.count >= 30 }

    // MARK: Building

    /// Builds the index. Blocking and slow (~1s); always call off the main actor.
    /// - Parameter runningBundleIDs: bundle identifiers of processes running
    ///   right now, supplied by the caller. Injected rather than read here so
    ///   this type stays Foundation-only (`NSRunningApplication` would pull in
    ///   AppKit, which the test bundle and `Scripts/verify.sh` must not need).
    ///   A running process is the strongest possible proof an app is installed.
    static func build(runningBundleIDs: Set<String> = []) -> SWPAppInventory {
        var inventory = SWPAppInventory()
        var bundles = Set<String>()

        // Spotlight finds apps anywhere — including the ones users keep in
        // `~/Downloads` or a nested folder — but it misses anything on an
        // unindexed volume, so the explicit walk below backs it up.
        for path in spotlightAppPaths() { bundles.insert(path) }
        for root in searchRoots {
            walkForApps(at: root.url, depth: root.depth, into: &bundles)
        }

        inventory.appCount = bundles.count
        for path in bundles {
            inventory.absorb(appAt: URL(fileURLWithPath: path))
        }
        inventory.absorbCommandNames()
        inventory.absorbLiveIdentifiers()
        for identifier in runningBundleIDs where !identifier.isEmpty {
            inventory.liveIdentifiers.insert(identifier.lowercased())
        }

        log.info("inventory built: \(bundles.count) apps, \(inventory.bundleIDs.count) bundle ids")
        return inventory
    }

    /// Hand-assembled inventory for tests. Deliberately below the
    /// `isTrustworthy` floor unless the test raises `appCount` itself.
    static func fixture(bundleIDs: Set<String> = [], nameTokens: Set<String> = [],
                        vendorWords: Set<String> = [], commandNames: Set<String> = [],
                        liveIdentifiers: Set<String> = [],
                        appCount: Int = 0) -> SWPAppInventory {
        var inventory = SWPAppInventory()
        inventory.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        inventory.nameTokens = nameTokens
        inventory.vendorWords = vendorWords
        inventory.commandNames = commandNames
        inventory.liveIdentifiers = Set(liveIdentifiers.map { $0.lowercased() })
        inventory.appCount = appCount
        return inventory
    }

    private static let searchRoots: [(url: URL, depth: Int)] = {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            (URL(fileURLWithPath: "/Applications"), 3),
            (home.appendingPathComponent("Applications"), 3),
            (URL(fileURLWithPath: "/System/Applications"), 2),
            (URL(fileURLWithPath: "/System/Library/CoreServices"), 2),
            (URL(fileURLWithPath: "/Library/Application Support"), 2),
            (home.appendingPathComponent("Library/Application Support"), 2),
            (URL(fileURLWithPath: "/opt/homebrew/Caskroom"), 3),
            (URL(fileURLWithPath: "/usr/local/Caskroom"), 3),
        ]
    }()

    /// `mdfind` rather than `NSMetadataQuery` because this runs synchronously on
    /// a background task and a run-loop-driven query would need to be pumped.
    private static func spotlightAppPaths() -> [String] {
        let output = shell("/usr/bin/mdfind",
                           ["kMDItemContentType == 'com.apple.application-bundle'"])
        return output.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasSuffix(".app") }
    }

    private static func walkForApps(at root: URL, depth: Int, into bundles: inout Set<String>) {
        guard depth >= 0 else { return }
        let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in contents ?? [] {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if child.pathExtension == "app" {
                bundles.insert(child.path)
            } else {
                walkForApps(at: child, depth: depth - 1, into: &bundles)
            }
        }
    }

    /// Pulls every identifying string out of one app bundle.
    private mutating func absorb(appAt url: URL) {
        nameTokens.insert(SWPMatch.normalise(url.deletingPathExtension().lastPathComponent))

        // Handles iOS-on-Mac bundles too, which keep their plist under
        // `Wrapper/<inner>.app/` and would otherwise contribute no identity at
        // all — letting a live app's container read as orphaned.
        guard let plist = SWPInstalledApps.infoPlist(in: url) else { return }

        if let bundleID = (plist["CFBundleIdentifier"] as? String)?.lowercased(), !bundleID.isEmpty {
            bundleIDs.insert(bundleID)
            let parts = bundleID.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                let vendor = SWPMatch.normalise(parts[1])
                if vendor.count >= 3, !SWPMatch.genericWords.contains(vendor) {
                    vendorWords.insert(vendor)
                }
            }
            if parts.count >= 3, let last = parts.last {
                let token = SWPMatch.normalise(last)
                if token.count >= 3, !SWPMatch.genericWords.contains(token) {
                    nameTokens.insert(token)
                }
            }
        }

        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            guard let value = plist[key] as? String else { continue }
            let token = SWPMatch.normalise(value)
            if token.count >= 3, !SWPMatch.genericWords.contains(token) {
                nameTokens.insert(token)
            }
        }

        // The copyright line is the only place an app reliably states the name
        // of the *company* behind it, and vendors name their support folders
        // after themselves, not after the product. Navicat ships
        // `~/Library/Application Support/PremiumSoft CyberTech`, which nothing
        // in the bundle id or the app name can be matched against; the
        // copyright string "PremiumSoft CyberTech Ltd" closes that gap.
        if let copyright = plist["NSHumanReadableCopyright"] as? String {
            for word in copyright.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let token = SWPMatch.normalise(String(word))
                guard token.count >= 4,
                      !SWPMatch.genericWords.contains(token),
                      !SWPMatch.corporateWords.contains(token) else { continue }
                vendorWords.insert(token)
            }
        }
    }

    /// Homebrew packages and `PATH` entries.
    ///
    /// Without this, `~/Library/Application Support/staticcheck` and friends
    /// look like leftovers of a deleted GUI app. `brew ls` is shelled out to
    /// rather than parsing the Cellar so that casks and taps are covered too.
    private mutating func absorbCommandNames() {
        let binDirectories = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
            NSHomeDirectory() + "/.cargo/bin", NSHomeDirectory() + "/go/bin",
            NSHomeDirectory() + "/.local/bin",
        ]
        for directory in binDirectories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names { commandNames.insert(SWPMatch.normalise(name)) }
        }

        // Apple Silicon and Intel prefixes both checked; missing brew simply
        // contributes nothing.
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let brew {
            for arguments in [["ls", "--formula"], ["ls", "--cask"]] {
                let output = Self.shell(brew, arguments)
                for name in output.split(whereSeparator: { $0 == "\n" || $0 == " " }) {
                    commandNames.insert(SWPMatch.normalise(String(name)))
                }
            }
        }
    }

    /// Identifiers from installer receipts and loaded launchd jobs.
    ///
    /// Both are read with the tools that own them rather than by parsing files
    /// under `/var/db`, and both are cheap. Running processes are deliberately
    /// *not* a separate source: a running GUI app is already in the bundle
    /// inventory, and `launchctl list` covers agents — adding `NSRunningApplication`
    /// would drag AppKit into a type that must stay Foundation-only so it
    /// compiles into the test bundle and the headless harness.
    private mutating func absorbLiveIdentifiers() {
        // Installer receipts: software installed by a `.pkg` that never shipped
        // an app bundle — drivers, VPN clients, audio plug-ins.
        for line in Self.shell("/usr/sbin/pkgutil", ["--pkgs"]).split(separator: "\n") {
            let identifier = line.trimmingCharacters(in: .whitespaces).lowercased()
            if !identifier.isEmpty { liveIdentifiers.insert(identifier) }
        }

        // Loaded launchd jobs. A job loaded right now is by definition not a
        // leftover. Output is "PID\tStatus\tLabel"; GUI apps appear as
        // `application.<bundle id>.<numbers>`, so that wrapper is unwrapped.
        for line in Self.shell("/bin/launchctl", ["list"]).split(separator: "\n").dropFirst() {
            guard let field = line.split(separator: "\t").last else { continue }
            var label = field.trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty else { continue }
            liveIdentifiers.insert(label)

            if label.hasPrefix("application.") {
                label = String(label.dropFirst("application.".count))
                let trimmed = label.split(separator: ".")
                    .prefix { Int($0) == nil }
                    .joined(separator: ".")
                if !trimmed.isEmpty { liveIdentifiers.insert(trimmed) }
            }
        }

        let identifierCount = liveIdentifiers.count
        Self.log.info("live identifiers: \(identifierCount)")
    }

    // MARK: Matching

    /// Whether any installed app plausibly owns `name`.
    ///
    /// `name` is the raw directory or file name already stripped of suffixes by
    /// `SWPMatch.canonicalName`.
    func owns(_ name: String) -> Bool {
        SWPMatch.looksReverseDNS(name) ? ownsReverseDNS(name) : ownsPlainName(name)
    }

    private func ownsReverseDNS(_ identifier: String) -> Bool {
        let lower = identifier.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if bundleIDs.contains(lower) { return true }
        if liveIdentifiers.contains(lower) { return true }

        let parts = lower.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            // A receipt or loaded job under the same vendor prefix keeps the
            // whole vendor alive: `com.paragon-software.ntfs` proves the
            // Paragon driver is installed even with no Paragon app present.
            //
            // The same two-component prefix also covers helpers: a bundle id
            // like `com.acme.tool.updater` belongs to `com.acme.tool`.
            let prefix = parts[0] + "." + parts[1]
            let claimsPrefix: (String) -> Bool = { $0 == prefix || $0.hasPrefix(prefix + ".") }
            if liveIdentifiers.contains(where: claimsPrefix) { return true }
            if bundleIDs.contains(where: claimsPrefix) { return true }
            let vendor = SWPMatch.normalise(parts[1])
            if !SWPMatch.genericWords.contains(vendor), matchesToken(vendor) { return true }
        }

        if let last = parts.last {
            let token = SWPMatch.normalise(last)
            if !SWPMatch.genericWords.contains(token), matchesToken(token) { return true }
        }
        return false
    }

    private func ownsPlainName(_ name: String) -> Bool {
        matchesToken(SWPMatch.normalise(name))
    }

    /// Token match with a substring fallback.
    ///
    /// The fallback is what rescues "PremiumSoft CyberTech" (Navicat's vendor
    /// folder) and "Google Chrome Helper". It is deliberately limited to tokens
    /// of four characters or more — below that, substring matching pairs almost
    /// anything with almost anything.
    private func matchesToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return true }
        if nameTokens.contains(token) || vendorWords.contains(token) { return true }
        if commandNames.contains(token) { return true }
        guard token.count >= 4 else { return false }
        for candidate in nameTokens where candidate.count >= 4 {
            if token.contains(candidate) || candidate.contains(token) { return true }
        }
        for candidate in vendorWords where candidate.count >= 4 {
            if token.contains(candidate) || candidate.contains(token) { return true }
        }
        return false
    }

    // MARK: Shell

    struct CommandResult: Sendable {
        let status: Int32?
        var output: String = ""
        var failure: String?
        var succeeded: Bool { status == 0 && failure == nil }
    }

    /// Bounded child lifetime and output capture. Never waits for EOF from a
    /// descendant that inherited stdout, and never relies on SIGTERM alone.
    static func command(_ launchPath: String, _ arguments: [String],
                        timeout: TimeInterval = 20, maximumOutput: Int = 1_048_576) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return CommandResult(status: nil, failure: "Could not configure bounded output capture.")
        }
        guard !Task.isCancelled else { return CommandResult(status: nil, failure: "Command cancelled before launch.") }
        do { try process.run() }
        catch { return CommandResult(status: nil, failure: error.localizedDescription) }
        try? pipe.fileHandleForWriting.close()
        var data = Data()
        var failure: String?
        var buffer = [UInt8](repeating: 0, count: 4_096)
        func drain() {
            for _ in 0..<16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count <= 0 {
                    if count < 0, errno != EAGAIN, errno != EINTR { failure = "Command output could not be read." }
                    break
                }
                let remaining = max(0, maximumOutput - data.count)
                data.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining { failure = "Command output exceeded its limit."; break }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while process.isRunning {
            drain()
            if Task.isCancelled { failure = "Command cancelled; effects may be partial." }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = "Command timed out; effects may be partial." }
            if failure != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if failure != nil, process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                drain()
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            let exitDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < exitDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        drain()
        let status = process.isRunning ? nil : process.terminationStatus
        if !process.isRunning, process.terminationReason != .exit, failure == nil {
            failure = "Command terminated by a signal."
        }
        return CommandResult(status: status, output: String(decoding: data, as: UTF8.self), failure: failure)
    }

    /// Incomplete or failed inventory output is never positive ownership evidence.
    @discardableResult
    static func shell(_ launchPath: String, _ arguments: [String],
                      timeout: TimeInterval = 20) -> String {
        let result = command(launchPath, arguments, timeout: timeout)
        return result.succeeded ? result.output : ""
    }
}

// MARK: - Name canonicalisation

/// Pure string helpers shared by the inventory and the scanners.
enum SWPMatch {

    /// Words too generic to identify an app. Matching on these would tie
    /// unrelated vendors together through their shared "helper" or "updater".
    static let genericWords: Set<String> = [
        "app", "apps", "mac", "osx", "macos", "pro", "lite", "helper", "helpers",
        "agent", "daemon", "launcher", "update", "updater", "install", "installer",
        "uninstaller", "service", "services", "client", "desktop", "beta", "free",
        "plus", "mobile", "web", "sync", "cloud", "menu", "bar", "tool", "tools",
        "kit", "core", "engine", "host", "plugin", "plugins", "extension", "ui", "gui",
    ]

    /// Legal boilerplate stripped out of copyright lines. Without this, every
    /// app on the Mac would contribute "rights" and "reserved" as vendor words
    /// and vouch for any folder containing them.
    static let corporateWords: Set<String> = [
        "copyright", "rights", "reserved", "inc", "ltd", "llc", "gmbh", "corp",
        "corporation", "company", "limited", "software", "technologies",
        "technology", "systems", "labs", "group", "holdings", "international",
        "worldwide", "team", "project", "foundation", "contributors", "authors",
        "portions", "used", "under", "license", "licence", "with", "permission",
        "from", "and", "the", "all", "other", "trademarks", "property", "their",
        "respective", "owners", "version", "build", "www", "http", "https", "com",
    ]

    /// Names that belong to toolchains and infrastructure rather than to an
    /// installed app.
    ///
    /// These are skipped by the leftovers sweep so they fall through to the
    /// Developer and Caches categories, which describe them accurately. Left in
    /// the leftovers list they were both wrong and alarming — a 4.9 GB Go build
    /// cache presented as "junk from a deleted app" is a bug report waiting to
    /// happen.
    static let toolchainNames: Set<String> = [
        "gobuild", "pip", "npm", "nodegyp", "node", "yarn", "pnpm", "corepack",
        "staticcheck", "msplaywright", "playwright", "puppeteer", "cypress",
        "typescript", "homebrew", "swiftpm", "orgswiftswiftpm", "cocoapods",
        "carthage", "gradle", "maven", "sbt", "deno", "bun", "uv", "poetry",
        "pypoetry", "virtualenv", "venv", "conda", "huggingface", "torch",
        "tensorflow", "matplotlib", "jedi", "ruff", "mypy", "black", "pylint",
        "pytest", "precommit", "ccache", "composer", "electron", "rustup",
        "cargo", "golang", "go", "swift", "crashreporter", "diagnosticreports",
    ]

    /// Common top-level domains, so that a two-part name like `io.sentry` is
    /// still recognised as reverse-DNS rather than treated as a plain name.
    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "co", "de", "se", "fr", "app", "dev", "sh", "me",
        "us", "uk", "ru", "ca", "ch", "nl", "jp", "cn", "pl", "eu", "tv", "fm", "ai",
        "it", "is", "no", "fi", "dk", "at", "be", "br", "in", "kr", "tw", "hk", "sg",
        "nz", "au", "cz", "es", "pt", "gr", "hu", "ro", "ua", "xyz", "info", "cc",
    ]

    /// Team identifiers that prefix group containers, mapped to the vendor they
    /// stand for. Unmapped team ids are simply stripped.
    private static let knownTeamIDs: [String: String] = [
        "UBF8T346G9": "com.microsoft",
        "EQHXZ8M8AV": "com.google",
    ]

    /// Lowercased, stripped of everything but letters and digits.
    static func normalise(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    static func looksReverseDNS(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.filter({ $0 == "." }).count >= 2 { return true }
        guard let first = lower.split(separator: ".").first, lower.contains(".") else { return false }
        return topLevelDomains.contains(String(first))
    }

    /// Strips the noise macOS wraps around an owner's identifier.
    ///
    /// Four transformations, each learned from a real false positive:
    /// preference extensions (`com.foo.plist`), per-host UUID suffixes
    /// (`com.foo.<UUID>.plist`), `group.` prefixes, and team-id prefixes
    /// (`UBF8T346G9.com.microsoft.oneauth`). Returns the bare identifier plus
    /// whether a team id was dropped, which downgrades confidence because an
    /// unmapped team id leaves us guessing at the vendor.
    static func canonicalName(_ rawName: String) -> (name: String, teamIDStripped: Bool) {
        var name = rawName

        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }

        // `com.foo.ABCDEF01-2345-...` — ByHost preferences.
        if let range = name.range(of: #"\.[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27,}$"#,
                                  options: .regularExpression) {
            name = String(name[name.startIndex..<range.lowerBound])
        }

        var teamIDStripped = false
        if let match = name.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) {
            let teamID = String(name[name.startIndex..<name.index(before: match.upperBound)])
            let rest = String(name[match.upperBound...])
            if let vendor = knownTeamIDs[teamID] {
                name = rest.hasPrefix(vendor) ? rest : vendor + "." + rest
            } else {
                name = rest
                teamIDStripped = true
            }
        }

        if name.lowercased().hasPrefix("group.") {
            name = String(name.dropFirst("group.".count))
        }

        return (name, teamIDStripped)
    }
}
