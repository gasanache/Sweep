import Foundation

// MARK: - Verdict

enum SWPSafetyVerdict: Equatable {
    case allowed
    case rejected(String)

    var isAllowed: Bool { self == .allowed }
}

// MARK: - Safety policy

/// The gate every candidate path must pass, twice: once when a scanner
/// proposes it, and again inside `SWPRemovalService` immediately before the
/// Trash call.
///
/// Checking twice is not redundancy for its own sake. The scan and the removal
/// are separated by however long the user spends reading the list, and by a
/// selection model that could, through a future bug, associate a tick with the
/// wrong row. Re-validating at the point of destruction means a scanner bug can
/// only ever produce a *visible* wrong row, never a deleted wrong file.
///
/// The design is allow-list first: a path is refused unless it lives strictly
/// inside one of `allowedRoots`. Deny-lists alone were the earlier approach and
/// they fail open — anything the list forgot to mention was fair game.
enum SWPSafety {

    // MARK: Roots

    private static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    /// The only places Sweep may ever touch. Everything else is refused.
    ///
    /// Note what is absent: `~/Documents`, `~/Desktop`, `~/Downloads`, the
    /// Photos and Mail libraries, `~/Library/Keychains`, and `/System`. Sweep
    /// removes rebuildable or abandoned support files; it is never a general
    /// file manager, so those roots stay out of reach by construction rather
    /// than by remembering to exclude them.
    static let allowedRoots: [URL] = {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let userRoots = [
            "Application Support", "Caches", "Preferences", "Logs", "Containers",
            "Group Containers", "Application Scripts", "Saved Application State",
            "WebKit", "HTTPStorages", "LaunchAgents", "Internet Plug-Ins",
            "PreferencePanes", "Developer",
        ].map { library.appendingPathComponent($0, isDirectory: true) }

        let systemRoots = [
            "/Library/Application Support", "/Library/Caches", "/Library/Logs",
            "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/Preferences",
            "/Library/PrivilegedHelperTools", "/Library/PreferencePanes",
            "/Library/Internet Plug-Ins",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        // Package-manager caches that live outside ~/Library by convention.
        // Roots, not targets: the policy refuses an allowed root itself, so
        // these must sit one level above what the scanners actually offer
        // (`.npm/_cacache`, `.gradle/caches`).
        let dotRoots = [".npm", ".cache", ".gradle"]
            .map { home.appendingPathComponent($0, isDirectory: true) }

        return userRoots + systemRoots + dotRoots
    }()

    // MARK: Deny-lists

    /// Names that hold real user data or system state even though they sit
    /// inside an allowed root. Matched case-insensitively on the last path
    /// component.
    private static let protectedNames: Set<String> = [
        // User data and system state.
        "com.apple.tcc", "mobilesync", "addressbook", "knowledge", "callhistorydb",
        "callhistorytransactions", "icloud", "clouddocs", "cloudstorage",
        "fileprovider", "dock", "sharing", "syncservices", "syncedpreferences",
        "keychains", "mail", "messages", "safari", "photos", "calendars",
        "accounts", "containermanager", "daemoncontainers", "cookies",
        "coresimulator", "user template", "systemconfiguration",
        ".globalpreferences", "globalpreferences", "loginwindow", "byhost",

        // Apple-owned folders that do not carry a `com.apple.` prefix and so
        // would otherwise read as an unknown third-party vendor. Every name
        // here was flagged as a leftover during development.
        //
        // `logic` is the cautionary one: `/Library/Application Support/Logic`
        // is Apple's sound library, shared by GarageBand and Logic Pro. With
        // only GarageBand installed nothing claims the name, so it looked like
        // 938 MB of junk from a deleted app. It is neither.
        "logic", "geoservices", "cloudkit", "animoji", "phtphenotype",
        "differentialprivacy", "askpermissiond", "appanalytics", "btserver",
        "locationaccessstored", "cctclearcutlogger", "gippseudonymousid",
        "privacypreservingmeasurement", "baseband", "windowserver", "xsan",
        "desktop pictures", "livefsd", "siri", "translation", "backupd",
        "assistant", "spotlight", "quicklook", "passkit", "coreduet",
        "corefollowup", "personalizationportrait", "networkserviceproxy",
        "screen savers", "printers", "fonts", "audio", "biome", "family",

        // Apple artefacts with ordinary-looking names. `mobilemeaccounts` is
        // the one that matters — it is the iCloud account list, and a user who
        // ticked it because it looked like junk would be signed out.
        // macOS's own crash and diagnostic stores. `~/Library/Logs/DiagnosticReports`
        // is Apple state, and tiering it `.safe` put it inside "Select Safe".
        "diagnosticreports", "crashreporter", "crashreporter_reports",
        "mobilemeaccounts", "gamekit", "contextstoreagent", "default",
        "default.store", "mcxtools", "discrecording", "vnc", "pbs",
        "ipad updater logs", "iphone updater logs", "watch updater logs",
        "swift-frontend", "swiftfrontend", "tokenbucketratelimiter",
        "sharedfilelistd", "systemmigrationd", "scopedbookmarkagent",
        "embeddedbinaryvalidationutility", "storekit", "gamed",
        "lkdc-setup", "fsck_hfs", "installation", "org.cups.printers",

        // Cross-app licensing, updater and runtime dependencies. These folders
        // belong to *many* apps at once — Paddle and FLEXnet store paid
        // licenses for whichever installed apps embed them, PACE/iLok holds
        // audio-plugin authorisations, Setapp is a whole app platform — and no
        // per-app inventory can prove that nothing still depends on them.
        // Removing one can silently de-license or break software that is very
        // much installed, and the space win is kilobytes. Refused outright;
        // false-keeps here are the correct trade.
        "paddle", "devmate", "esellerate", "flexnet", "flexnet publisher",
        "pace", "ilok", "sentinel", "safenet sentinel", "setapp", "sparkle",
        "mono", "oracle", "instabug", "appcenter", "hockeyapp",
    ]

    /// Prefix-matched equivalents, for names that carry a UUID or an account
    /// identifier and therefore never compare equal.
    private static let protectedPrefixes: [String] = [
        "com.apple.", "group.com.apple.", "aaprofilepicture", "adprivacy",
        "clouddocs", "familycircle",
    ]

    /// Paths that must never be removed regardless of anything else. Compared
    /// after standardisation so `~/Library/../Library` cannot sneak through.
    private static let protectedExactPaths: Set<String> = {
        var paths: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin",
            "/sbin", "/etc", "/var", "/private", "/opt", "/opt/homebrew", "/tmp",
        ]
        for name in ["", "Library", "Documents", "Desktop", "Downloads", "Pictures",
                     "Movies", "Music", "Applications", "Public", "Library/Keychains",
                     "Library/Mail", "Library/Messages", "Library/Safari",
                     "Library/Photos", "Library/Mobile Documents", "Library/Developer",
                     "Library/Developer/Xcode", "Library/Developer/CoreSimulator"] {
            paths.insert(home.appendingPathComponent(name).standardizedFileURL.path)
        }
        return paths
    }()

    // MARK: Validation

    /// Whether `url` may be removed.
    ///
    /// Order matters: cheap structural checks first, filesystem access last, so
    /// that validating thousands of scan candidates stays fast.
    static func validate(_ url: URL) -> SWPSafetyVerdict {
        let standardized = url.standardizedFileURL
        let path = standardized.path

        guard path.hasPrefix("/") else { return .rejected("not an absolute path") }

        // Control characters — newlines and tabs especially — are refused
        // outright. They are meaningless in a real support file, they corrupt
        // the tab-separated quarantine manifest that makes an authorised
        // removal reversible, and a newline in a name was demonstrated to
        // break out of the manifest heredoc in the script that runs as root.
        // Failing closed here is cheaper than escaping perfectly everywhere.
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
            return .rejected("path contains control characters")
        }
        guard !path.contains("..") else { return .rejected("contains a relative traversal") }
        guard path != "/" else { return .rejected("filesystem root") }

        if protectedExactPaths.contains(path) {
            return .rejected("protected location")
        }

        // Compared with and without the extension so that both `ByHost` and
        // `.GlobalPreferences.plist` are caught by one list.
        let name = standardized.lastPathComponent.lowercased()
        let bareName = standardized.deletingPathExtension().lastPathComponent.lowercased()
        if protectedNames.contains(name) || protectedNames.contains(bareName) {
            return .rejected("holds user or system data")
        }

        // Apple's own state is out of scope on purpose. Sweep only removes
        // third-party files: clearing macOS caches wins little space and is the
        // single most common way these tools break a Mac.
        // `contains` rather than `hasPrefix` alone: Apple wraps its own
        // identifiers in several prefixes — `group.`, `systemgroup.`, a team
        // id — and `systemgroup.com.apple.icloud.searchpartyd` reached the
        // results list as an orphan of a vendor called "Com" before this.
        if name.contains("com.apple.") || protectedPrefixes.contains(where: { name.hasPrefix($0) }) {
            return .rejected("belongs to macOS")
        }

        guard let root = enclosingRoot(of: standardized) else {
            return .rejected("outside every allowed location")
        }

        // Must be strictly *inside* a root — never the root itself. Removing
        // `~/Library/Caches` wholesale would be catastrophic and is exactly the
        // kind of off-by-one a grouping bug could produce.
        guard standardized.path != root.standardizedFileURL.path else {
            return .rejected("is an allowed root itself")
        }

        // A symlink is trashed as a link, but if it resolves outside the allowed
        // set we refuse it: the user's mental model is "this folder", and we do
        // not want a stray link to imply we touched its target.
        let resolved = standardized.resolvingSymlinksInPath()
        if resolved.path != standardized.path, enclosingRoot(of: resolved) == nil {
            return .rejected("symlink escapes the allowed locations")
        }

        return .allowed
    }

    /// The allowed root that strictly contains `url`, if any.
    private static func enclosingRoot(of url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return allowedRoots.first { root in
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    /// Whether removing `url` needs administrator rights.
    ///
    /// Anything under `/Library` is root-owned; the user's own Trash call will
    /// fail with `EACCES`, so these are routed through the authorised batch
    /// instead of being attempted and silently failing.
    static func requiresAdmin(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix("/Library/")
    }

    // MARK: App bundles (uninstaller only)

    /// The uninstaller's gate for the `.app` bundle itself.
    ///
    /// Deliberately a *separate* rule rather than a loosening of
    /// `validate(_:)`: `/Applications` stays outside `allowedRoots` so that no
    /// scanner can ever propose an application for removal. This gate applies
    /// only to a bundle the user explicitly picked in the uninstaller, and it
    /// still refuses anything on the system volume, anything nested deeper
    /// than one vendor folder, Safari (SIP-protected despite its location),
    /// and Sweep itself.
    static func validateAppBundle(_ url: URL) -> SWPSafetyVerdict {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension == "app" else {
            return .rejected("not an application bundle")
        }
        let path = standardized.path
        guard !path.hasPrefix("/System/"), !path.hasPrefix("/Library/") else {
            return .rejected("part of macOS")
        }
        if standardized == Bundle.main.bundleURL.standardizedFileURL {
            return .rejected("Sweep cannot uninstall itself")
        }

        // Direct child of an Applications folder, or exactly one level of
        // nesting below it — vendors like Adobe use a folder in /Applications,
        // and browsers install PWA wrappers in `~/Applications/Chrome Apps
        // .localized/`. Anything deeper is not how apps are installed and is
        // refused.
        let parent = standardized.deletingLastPathComponent().path
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        let insideApplications = roots.contains { root in
            parent == root
                || (parent.hasPrefix(root + "/")
                    && !parent.dropFirst(root.count + 1).contains("/"))
        }
        guard insideApplications else {
            return .rejected("outside the Applications folders")
        }

        if let bundleID = Bundle(url: standardized)?.bundleIdentifier?.lowercased(),
           protectedBundleIDs.contains(bundleID) {
            return .rejected("protected by macOS")
        }
        return .allowed
    }

    /// Apps that live in /Applications but belong to the OS.
    private static let protectedBundleIDs: Set<String> = ["com.apple.safari"]
}
