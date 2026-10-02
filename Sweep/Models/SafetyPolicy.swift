import Foundation
import Darwin

// MARK: - Verdict

enum SWPSafetyVerdict: Equatable {
    case allowed
    case rejected(String)

    var isAllowed: Bool { self == .allowed }
}

// MARK: - Safety policy

/// The gate every candidate path must pass, twice: once when a scanner
/// proposes it, and again inside `SWPRemovalService` before a descriptor-bound
/// quarantine move.
///
/// The scan and the removal are separated by however long the user spends
/// reading the list. Re-validating rejects paths whose policy has changed;
/// the removal service must also bind filesystem identity at the mutation
/// boundary, because a policy verdict alone cannot prevent a concurrent rename.
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
    /// inside an allowed root. Matched case-insensitively on every component
    /// below that root, not on unrelated ancestors such as the user's name.
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
    /// after lexical normalization so `~/Library/../Library` cannot sneak through.
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
            paths.insert(SWPLocalAIPathIdentity.lexicalURL(home.appendingPathComponent(name)).path)
        }
        return paths
    }()

    /// The developer scanner explicitly offers simulator caches, never Devices
    /// or other simulator state. This is the only protected-name exception.
    private static let simulatorCacheRoot = home.appendingPathComponent("Library/Developer/CoreSimulator/Caches")

    private static let localAIProductsByPath: [String: SWPLocalAIProduct] = {
        var paths: [String: SWPLocalAIProduct] = [:]
        for product in SWPLocalAIProduct.allCases {
            for url in SWPLocalAIScanner.homeTargets(for: product, home: home) { paths[url.path] = product }
        }
        paths["/opt/homebrew/var/log/ollama.log"] = .ollama
        paths["/usr/local/var/log/ollama.log"] = .ollama
        return paths
    }()
    private static let aiInventoryPaths = SWPAICatalog.locations(home: home, applicationRoots: [], commandRoots: [],
                                                                environment: ProcessInfo.processInfo.environment)
        .map { $0.url.path.lowercased() }
    private static let sharedModelsPath = home.appendingPathComponent(".cache/huggingface").path
    private static let brewCachePath = home.appendingPathComponent("Library/Caches/Homebrew").path

    // MARK: Validation

    /// Whether `url` may be removed.
    ///
    /// Order matters: cheap structural checks first, filesystem access last, so
    /// that validating thousands of scan candidates stays fast.
    static func validate(_ url: URL) -> SWPSafetyVerdict {
        validate(url, restoring: false)
    }

    /// Recovery may put back previously reviewed Local AI and older Homebrew
    /// batches. This does not authorize new generic removals of those paths.
    static func validateForRestore(_ url: URL) -> SWPSafetyVerdict {
        validate(url, restoring: true)
    }

    /// Dedicated-workflow objects, their descendants, and aggregating cache
    /// parents cannot be laundered through ordinary cleanup or uninstall.
    static func requiresLocalAIReview(_ url: URL) -> Bool {
        let target = SWPLocalAIPathIdentity.lexicalURL(url)
        // Conservative even on case-sensitive volumes: changing the case of
        // an app-owned name must not turn a dedicated target into generic junk.
        let path = target.path.lowercased()
        if localAIProductsByPath.keys.contains(where: { path == $0.lowercased() || path.hasPrefix($0.lowercased() + "/") }) {
            return true
        }
        let cache = URL(fileURLWithPath: brewCachePath)
        if [cache.path, cache.appendingPathComponent("downloads").path,
            cache.appendingPathComponent("Cask").path].map({ $0.lowercased() }).contains(path) { return true }
        var candidate = target
        while candidate.path.hasPrefix(brewCachePath + "/") {
            if SWPLocalAIProduct.allCases.contains(where: {
                SWPLocalAIScanner.ownsBrewCache(candidate, product: $0, home: home)
            }) { return true }
            candidate.deleteLastPathComponent()
        }
        return false
    }

    private static func validate(_ url: URL, restoring: Bool) -> SWPSafetyVerdict {
        let standardized = SWPLocalAIPathIdentity.lexicalURL(url)
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
        guard !url.path.contains("..") else { return .rejected("contains a relative traversal") }
        guard path != "/" else { return .rejected("filesystem root") }

        if protectedExactPaths.contains(path) {
            return .rejected("protected location")
        }

        if path == sharedModelsPath || path.hasPrefix(sharedModelsPath + "/") {
            return .rejected("shared model cache")
        }

        if !restoring, requiresLocalAIReview(standardized) {
            return .rejected("requires the dedicated Local AI review")
        }

        if !restoring, SWPAIInspectionProtection.shared.protects(standardized) || aiInventoryPaths.contains(where: { root in
            let candidate = path.lowercased()
            return candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/") || root.hasPrefix(candidate + "/")
        }) {
            return .rejected("AI models or sensitive assistant data: inspection only")
        }

        // These are exact objects, never roots authorising their descendants.
        // Keep this before the ordinary root rule so even a link from an
        // app-owned Library path into another allowed cache is refused.
        if let product = localAIProductsByPath[path] {
            return validateLocalAI(standardized, product: product)
        }
        if path.hasPrefix(brewCachePath + "/") {
            for product in SWPLocalAIProduct.allCases where SWPLocalAIScanner.ownsBrewCache(standardized, product: product, home: home) {
                return validateLocalAI(standardized, product: product)
            }
        }

        guard let root = enclosingRoot(of: standardized) else {
            return .rejected("outside every allowed location")
        }

        // Must be strictly *inside* a root — never the root itself. Removing
        // `~/Library/Caches` wholesale would be catastrophic and is exactly the
        // kind of off-by-one a grouping bug could produce.
        guard path != root.path else {
            return .rejected("is an allowed root itself")
        }

        var protectedBoundary = root
        if path == simulatorCacheRoot.path || path.hasPrefix(simulatorCacheRoot.path + "/") {
            protectedBoundary = simulatorCacheRoot.deletingLastPathComponent()
        }
        for component in standardized.pathComponents.dropFirst(protectedBoundary.pathComponents.count) {
            let name = component.lowercased()
            let bareName = (name as NSString).deletingPathExtension
            if protectedNames.contains(name) || protectedNames.contains(bareName) {
                return .rejected("holds user or system data")
            }
            // Apple identifiers can be wrapped in group or team prefixes.
            if name.contains("com.apple.") || protectedPrefixes.contains(where: { name.hasPrefix($0) }) {
                return .rejected("belongs to macOS")
            }
        }

        guard isUnlinkedPath(standardized) else {
            return .rejected("linked or unreadable path")
        }

        return .allowed
    }

    /// The allowed root that strictly contains `url`, if any.
    private static func enclosingRoot(of url: URL) -> URL? {
        let path = url.path
        return allowedRoots.first { root in
            let rootPath = root.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    /// A narrower gate for the dedicated Local AI workflow. Injections permit
    /// isolated fixtures; the general removal gate always uses production roots.
    static func validateLocalAI(_ url: URL, product: SWPLocalAIProduct,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                brewPrefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]) -> SWPSafetyVerdict {
        let target = SWPLocalAIPathIdentity.lexicalURL(url)
        guard target.path.rangeOfCharacter(from: .controlCharacters) == nil,
              !url.path.contains("..") else { return .rejected("invalid path") }
        if SWPLocalAIScanner.isOwnedBrewCacheAlias(target, product: product, home: home) {
            return .allowed
        }
        if SWPLocalAIScanner.homeTargets(for: product, home: home).contains(target)
            || SWPLocalAIScanner.ownsBrewCache(target, product: product, home: home) {
            return isUnlinkedLocalAIPath(target, within: home)
                ? .allowed : .rejected("linked or unreadable local AI path")
        }
        if product == .ollama, let prefix = brewPrefixes.first(where: {
            SWPLocalAIPathIdentity.lexicalURL($0.appendingPathComponent("var/log/ollama.log")) == target
        }) {
            return isUnlinkedLocalAIPath(target, within: prefix)
                ? .allowed : .rejected("linked or unreadable Ollama log")
        }
        return .rejected("not an exact owned local AI location")
    }

    /// Scope is lexical; the filesystem check must reject links in the root's
    /// own ancestry as well as links between the root and the target.
    static func isUnlinkedLocalAIPath(_ url: URL, within root: URL) -> Bool {
        let base = SWPLocalAIPathIdentity.lexicalURL(root)
        let target = SWPLocalAIPathIdentity.lexicalURL(url)
        guard target == base || target.path.hasPrefix(base.path + "/") else { return false }
        return isUnlinkedPath(target)
    }

    /// Darwin checks all components during one lookup, including a linked leaf.
    /// Missing candidates remain valid policy proposals only when the nearest
    /// existing ancestor is unlinked. Removal separately requires the object.
    private static func isUnlinkedPath(_ url: URL) -> Bool {
        var current = url
        while true {
            let descriptor = open(current.path, O_EVTONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            guard errno == ENOENT, current.path != "/" else { return false }
            current.deleteLastPathComponent()
        }
    }

    /// Whether removing `url` needs administrator rights.
    ///
    /// Anything under `/Library` is root-owned; the user's own Trash call will
    /// fail with `EACCES`, so these are routed through the authorised batch
    /// instead of being attempted and silently failing.
    static func requiresAdmin(_ url: URL) -> Bool {
        SWPLocalAIPathIdentity.lexicalURL(url).path.hasPrefix("/Library/")
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
    static func validateAppBundle(_ url: URL,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SWPSafetyVerdict {
        let standardized = SWPLocalAIPathIdentity.lexicalURL(url)
        guard url.path.rangeOfCharacter(from: .controlCharacters) == nil,
              !url.path.contains("..") else { return .rejected("invalid path") }
        guard standardized.pathExtension == "app" else {
            return .rejected("not an application bundle")
        }
        let path = standardized.path
        guard !path.hasPrefix("/System/"), !path.hasPrefix("/Library/") else {
            return .rejected("part of macOS")
        }
        if standardized == SWPLocalAIPathIdentity.lexicalURL(Bundle.main.bundleURL) {
            return .rejected("Sweep cannot uninstall itself")
        }

        // Direct child of an Applications folder, or exactly one level of
        // nesting below it — vendors like Adobe use a folder in /Applications,
        // and browsers install PWA wrappers in `~/Applications/Chrome Apps
        // .localized/`. Anything deeper is not how apps are installed and is
        // refused.
        let parent = standardized.deletingLastPathComponent().path
        let roots = ["/Applications", SWPLocalAIPathIdentity.lexicalURL(home.appendingPathComponent("Applications")).path]
        let insideApplications = roots.contains { root in
            parent == root
                || (parent.hasPrefix(root + "/")
                    && !parent.dropFirst(root.count + 1).contains("/"))
        }
        guard insideApplications else {
            return .rejected("outside the Applications folders")
        }
        guard isUnlinkedPath(standardized) else {
            return .rejected("linked or unreadable application path")
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
