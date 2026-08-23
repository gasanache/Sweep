import Foundation

// MARK: - Junk scanner

/// Caches, logs and developer artefacts belonging to apps that *are* still
/// installed — everything that is rebuildable rather than abandoned.
///
/// Kept apart from `SWPOrphanScanner` because the two answer different
/// questions. This one never has to guess whether a file's *purpose* is
/// disposable — by location it always is. Ownership still matters, though: a
/// cache whose app is installed gets `.inUse`, because clearing it has a real
/// cost (slower next launch, re-downloaded offline content) even when losing
/// it is technically harmless. Only ownerless entries earn `.safe`.
struct SWPJunkScanner {

    private let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    private let inventory: SWPAppInventory

    /// Paths already claimed by an earlier scanner, so a Homebrew cache cannot
    /// appear under both Developer Junk and Caches.
    private var claimed: Set<String>
    /// Paths the user has permanently excluded; treated exactly like claimed
    /// paths so they never reach a group.
    private let ignored: Set<String>

    init(inventory: SWPAppInventory, claimed: Set<String>, ignored: Set<String> = []) {
        self.inventory = inventory
        self.claimed = claimed
        self.ignored = ignored
    }

    /// `.inUse` when an installed app owns this entry, `.safe` otherwise.
    ///
    /// "Otherwise" is narrower than it looks: orphaned entries were already
    /// claimed by the leftovers scan, and Apple's own names never validate, so
    /// what reaches `.safe` is toolchain residue and the genuinely unowned.
    private func ownership(of url: URL) -> SWPConfidence {
        let canonical = SWPMatch.canonicalName(url.lastPathComponent).name
        return inventory.owns(canonical) ? .inUse : .safe
    }

    /// Groups smaller than this are rolled into a single summary row.
    /// Sixty rows of 40 KB caches is noise that buries the 3 GB one.
    ///
    /// Follows the same preference as the leftovers fold, scaled up: the
    /// caches sweep produces far more rows, so its default sits higher. Zero
    /// means the user chose "Never fold", and then nothing is summarised
    /// anywhere — the setting said never, not "never in one category".
    private static var individualRowThreshold: Int64 {
        let base = SWPSettings.foldThresholdBytes
        return base == 0 ? 0 : max(base, 1_048_576)
    }

    // MARK: Developer

    /// Xcode and package-manager artefacts.
    ///
    /// Ordered before the cache sweep so these claim their paths first: derived
    /// data is developer junk, not a generic cache, and the label matters when
    /// someone is deciding whether 24 GB is safe to drop.
    /// - Parameter emitGroups: when false the sources are still walked and
    ///   their paths still claimed, but nothing is reported. Skipping the walk
    ///   entirely let 6+ GB of toolchain caches fall through to the Caches
    ///   sweep and come back tiered `.safe` — the opposite of what turning the
    ///   category off should mean.
    mutating func scanDeveloper(emitGroups: Bool = true,
                                progress: (String) -> Void) -> [SWPGroup] {
        let xcode = home.appendingPathComponent("Library/Developer/Xcode", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)

        let sources: [(name: String, url: URL, childrenAsItems: Bool)] = [
            ("Xcode Derived Data", xcode.appendingPathComponent("DerivedData"), true),
            ("Xcode Archives", xcode.appendingPathComponent("Archives"), true),
            ("iOS Device Support", xcode.appendingPathComponent("iOS DeviceSupport"), true),
            ("watchOS Device Support", xcode.appendingPathComponent("watchOS DeviceSupport"), true),
            ("tvOS Device Support", xcode.appendingPathComponent("tvOS DeviceSupport"), true),
            ("Simulator Caches",
             home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"), true),
            ("Swift Package Manager", caches.appendingPathComponent("org.swift.swiftpm"), false),
            ("Homebrew Downloads", caches.appendingPathComponent("Homebrew"), false),
            ("Go Build Cache", caches.appendingPathComponent("go-build"), false),
            ("pip", caches.appendingPathComponent("pip"), false),
            ("npm", home.appendingPathComponent(".npm/_cacache"), false),
            ("node-gyp", caches.appendingPathComponent("node-gyp"), false),
            ("Playwright Browsers", caches.appendingPathComponent("ms-playwright"), false),
            ("staticcheck", caches.appendingPathComponent("staticcheck"), false),
            ("TypeScript", caches.appendingPathComponent("typescript"), false),
            ("Yarn", caches.appendingPathComponent("Yarn"), false),
            ("CocoaPods", caches.appendingPathComponent("CocoaPods"), false),
            ("Deno", caches.appendingPathComponent("deno"), false),
            ("Gradle", home.appendingPathComponent(".gradle/caches"), false),
            ("Xcode Previews",
             home.appendingPathComponent("Library/Developer/Xcode/UserData/Previews"), false),
        ]

        // Collect every candidate URL first, then measure them all in ONE
        // parallel pass.
        //
        // Sizing used to run per source, and a source like Homebrew or
        // go-build is a single URL — so `sizes(of:)` got a one-element batch
        // and walked a multi-gigabyte tree on one thread while every other
        // core idled. Profiling put this stage at 3.0s of a 6s scan for that
        // reason alone. Batching lets the big single-tree sources overlap with
        // each other and with DerivedData's children.
        var pending: [(source: String, url: URL)] = []
        for source in sources {
            if Task.isCancelled { return [] }
            progress(source.name)
            guard FileManager.default.fileExists(atPath: source.url.path) else { continue }

            let urls: [URL] = source.childrenAsItems
                ? (try? FileManager.default.contentsOfDirectory(
                    at: source.url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                : [source.url]

            for url in urls {
                let path = url.standardizedFileURL.path
                guard !claimed.contains(path), !ignored.contains(path),
                      SWPSafety.validate(url).isAllowed else { continue }
                claimed.insert(path)
                pending.append((source.name, url))
            }
        }
        guard !pending.isEmpty, emitGroups else { return [] }

        let sizes = SWPDiskSize.sizes(of: pending.map(\.url))
        var itemsBySource: [String: [SWPItem]] = [:]
        for (index, entry) in pending.enumerated() where sizes[index] > 0 {
            itemsBySource[entry.source, default: []].append(
                SWPItem(url: entry.url,
                        sizeBytes: sizes[index],
                        modified: SWPDiskSize.modified(of: entry.url),
                        location: "Developer",
                        requiresAdmin: SWPSafety.requiresAdmin(entry.url)))
        }

        var groups: [SWPGroup] = []
        for source in sources {
            guard let items = itemsBySource[source.name], !items.isEmpty else { continue }
            groups.append(SWPGroup(id: "developer.\(source.name)",
                                   name: source.name,
                                   category: .developer,
                                   confidence: Self.notDisposable.contains(source.name)
                                       ? .likely : .safe,
                                   items: items.sorted { $0.sizeBytes > $1.sizeBytes }))
        }
        return groups
    }

    /// Developer artefacts that are *not* rebuildable, despite living among
    /// things that are.
    ///
    /// An Xcode archive is a shipped build plus its dSYMs — the only way to
    /// symbolicate a crash report from a release already in users' hands. It
    /// cannot be regenerated once the source has moved on. Grouping it with
    /// derived data and letting it inherit `.safe` would have pre-ticked it.
    private static let notDisposable: Set<String> = ["Xcode Archives"]

    // MARK: Caches and logs

    mutating func scanCaches(progress: (String) -> Void) -> [SWPGroup] {
        if Task.isCancelled { return [] }
        progress("Caches")
        let root = home.appendingPathComponent("Library/Caches", isDirectory: true)
        return sweepDisposable(root, category: .caches, location: "Caches",
                               summaryName: "Minor caches")
    }

    mutating func scanLogs(progress: (String) -> Void) -> [SWPGroup] {
        progress("Logs")
        var groups: [SWPGroup] = []
        let roots = [
            (home.appendingPathComponent("Library/Logs", isDirectory: true), "Logs"),
            (home.appendingPathComponent("Library/Application Support/CrashReporter",
                                         isDirectory: true), "Crash Reports"),
        ]
        for (url, label) in roots {
            if Task.isCancelled { return groups }
            groups += sweepDisposable(url, category: .logs, location: label,
                                      summaryName: "Minor \(label.lowercased())")
        }
        return groups
    }

    /// Shared shape for "everything in this folder is disposable by location".
    ///
    /// Each entry is classified by ownership, and the small-item aggregates are
    /// split along the same line — folding an installed app's cache into a
    /// `.safe` "minor caches" row would launder its status through the group
    /// label, which is exactly the kind of quiet mislabelling this pass exists
    /// to prevent.
    private mutating func sweepDisposable(_ root: URL, category: SWPCategory,
                                          location: String, summaryName: String) -> [SWPGroup] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        if Task.isCancelled { return [] }
        let items = makeItems(children, location: location)
        guard !items.isEmpty else { return [] }

        var groups: [SWPGroup] = []
        var smallSafe: [SWPItem] = []
        var smallInUse: [SWPItem] = []

        let threshold = Self.individualRowThreshold
        for item in items {
            let confidence = ownership(of: item.url)
            if threshold == 0 || item.sizeBytes >= threshold {
                groups.append(SWPGroup(id: "\(category.rawValue).\(item.id)",
                                       name: prettyName(item.url.lastPathComponent),
                                       category: category,
                                       confidence: confidence,
                                       items: [item]))
            } else if confidence == .inUse {
                smallInUse.append(item)
            } else {
                smallSafe.append(item)
            }
        }

        if !smallSafe.isEmpty {
            groups.append(SWPGroup(id: "\(category.rawValue).\(summaryName)",
                                   name: summaryName,
                                   category: category,
                                   confidence: .safe,
                                   items: smallSafe))
        }
        if !smallInUse.isEmpty {
            groups.append(SWPGroup(id: "\(category.rawValue).\(summaryName).inuse",
                                   name: summaryName + " · installed apps",
                                   category: category,
                                   confidence: .inUse,
                                   items: smallInUse))
        }
        return groups
    }

    // MARK: Helpers

    /// Validates, de-duplicates and measures a batch of URLs.
    private mutating func makeItems(_ urls: [URL], location: String) -> [SWPItem] {
        let usable = urls.filter { url in
            let path = url.standardizedFileURL.path
            return !claimed.contains(path) && !ignored.contains(path)
                && SWPSafety.validate(url).isAllowed
        }
        guard !usable.isEmpty else { return [] }

        let sizes = SWPDiskSize.sizes(of: usable)
        var items: [SWPItem] = []
        for (index, url) in usable.enumerated() {
            claimed.insert(url.standardizedFileURL.path)
            // Zero-byte entries are real (macOS leaves empty cache shells
            // behind) but listing them wastes a row and offers no benefit.
            guard sizes[index] > 0 else { continue }
            items.append(SWPItem(url: url,
                                 sizeBytes: sizes[index],
                                 modified: SWPDiskSize.modified(of: url),
                                 location: location,
                                 requiresAdmin: SWPSafety.requiresAdmin(url)))
        }
        return items
    }

    /// Turns `com.operasoftware.Opera` into `Operasoftware` for a row title.
    private func prettyName(_ raw: String) -> String {
        let name = SWPMatch.canonicalName(raw).name
        guard SWPMatch.looksReverseDNS(name) else { return name }
        let parts = name.split(separator: ".").map(String.init)
        return parts.count >= 2 ? parts[1].capitalized : name
    }

    // MARK: Trash

    /// Current Trash size, shown as a footer stat rather than a category —
    /// emptying the Trash is a different kind of action from moving things into
    /// it, and mixing the two in one list invites a very bad mis-click.
    static func trashSize() -> Int64 {
        let trash = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
        return SWPDiskSize.size(of: trash)
    }
}
