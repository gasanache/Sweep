import Foundation
import Darwin

enum SWPLocalAIProduct: String, CaseIterable, Identifiable, Sendable {
    case lmStudio, ollama

    var id: String { rawValue }
    var name: String { self == .lmStudio ? "LM Studio" : "Ollama" }

    // Homebrew's official casks, including LM Studio's original 0.2.x cask.
    var bundleIDs: Set<String> {
        self == .lmStudio ? ["ai.elementlabs.lmstudio"] : ["com.electron.ollama"]
    }
}

struct SWPLocalAIBrewPackage: Equatable, Sendable {
    let prefix: URL
    let token: String
    let isCask: Bool
    let installedVersions: [String]
}

struct SWPLocalAIPathIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64

    static func capture(_ url: URL) throws -> Self {
        let value = try metadata(url)
        return Self(device: value.st_dev, inode: value.st_ino)
    }

    /// Keep lexical scope checks separate from physical resolution. Foundation
    /// standardization rewrites existing /private/var paths to the /var symlink.
    static func lexicalURL(_ url: URL) -> URL {
        var parts: [String] = []
        for part in url.pathComponents {
            switch part {
            case "/", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"),
                   isDirectory: url.hasDirectoryPath)
    }

    static func resolvedURL(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return lexicalURL(url) }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: url.hasDirectoryPath)
    }

    fileprivate static func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return value
    }
}

struct SWPLocalAIPlan: Identifiable, Sendable {
    let product: SWPLocalAIProduct
    let items: [SWPItem]
    let appURLs: [URL]
    let brewExecutable: URL?
    let hasBrewPackage: Bool
    let shellProfiles: [URL]
    let blockers: [String]
    let notes: [String]
    var brewPackages: [SWPLocalAIBrewPackage] = []
    var pathIdentities: [String: SWPLocalAIPathIdentity] = [:]
    var shellContents: [String: String] = [:]
    var hasCLI: Bool = false

    var id: String { product.id }
    var isInstalled: Bool { !appURLs.isEmpty || hasBrewPackage || hasCLI }
    var sizeBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var hasWork: Bool { !items.isEmpty || !appURLs.isEmpty || hasBrewPackage || !shellProfiles.isEmpty }
}

/// Read-only discovery: neither a custom model setting nor a home pointer grants
/// permission to remove its destination. Only these fixed owned locations do.
struct SWPLocalAIScanner: Sendable {
    let home: URL
    let applicationRoots: [URL]
    let brewPrefixes: [URL]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         applicationRoots: [URL]? = nil,
         brewPrefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]) {
        self.home = SWPLocalAIPathIdentity.lexicalURL(home)
        self.applicationRoots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.brewPrefixes = brewPrefixes.map(SWPLocalAIPathIdentity.lexicalURL)
    }

    static func product(forAppBundleID identifier: String) -> SWPLocalAIProduct? {
        SWPLocalAIProduct.allCases.first { $0.bundleIDs.contains(identifier.lowercased()) }
    }

    static func homeTargets(for product: SWPLocalAIProduct, home: URL) -> [URL] {
        let paths: [String]
        switch product {
        case .lmStudio:
            paths = [".lmstudio", ".lmstudio-home-pointer", ".cache/lm-studio",
                     "Library/Application Support/LM Studio", "Library/Logs/LM Studio",
                     "Library/Caches/ai.elementlabs.lmstudio", "Library/Caches/ai.elementlabs.lmstudio.ShipIt",
                     "Library/HTTPStorages/ai.elementlabs.lmstudio", "Library/HTTPStorages/ai.elementlabs.lmstudio.binarycookies",
                     "Library/Preferences/ai.elementlabs.lmstudio.plist",
                     "Library/Saved Application State/ai.elementlabs.lmstudio.savedState",
                     "Library/WebKit/ai.elementlabs.lmstudio"]
        case .ollama:
            paths = [".ollama", "Library/Application Support/Ollama", "Library/Caches/ollama",
                     "Library/Caches/com.electron.ollama", "Library/Caches/com.electron.ollama.ShipIt",
                     "Library/HTTPStorages/com.electron.ollama", "Library/HTTPStorages/com.electron.ollama.binarycookies",
                     "Library/Preferences/com.electron.ollama.plist",
                     "Library/Saved Application State/com.electron.ollama.savedState", "Library/WebKit/com.electron.ollama",
                     "Library/LaunchAgents/homebrew.mxcl.ollama.plist", "Library/LaunchAgents/com.ollama.ollama.plist"]
        }
        return paths.map { SWPLocalAIPathIdentity.lexicalURL(home.appendingPathComponent($0)) }
    }

    /// Removes only the exact generated three-line block, including its own
    /// final newline when present. Unrelated whitespace and line endings survive.
    /// Edited, partial, duplicated-marker or custom-path blocks fail closed.
    static func shellBlock(in content: String, home: URL) -> String? {
        let start = "# Added by LM Studio CLI (lms)"
        let end = "# End of LM Studio CLI section"
        let path = home.appendingPathComponent(".lmstudio/bin").path
        guard path.rangeOfCharacter(from: CharacterSet(charactersIn: "\"$`\\\n\r")) == nil else { return nil }
        let command = "export PATH=\"$PATH:\(path)\""
        var output = content
        for newline in ["\n", "\r\n"] {
            let body = [start, command, end].map(NSRegularExpression.escapedPattern(for:)).joined(separator: newline)
            output = output.replacingOccurrences(of: "(?m)^" + body + "(?:" + newline + "|\\z)",
                                                 with: "", options: .regularExpression)
        }
        guard output != content,
              !output.contains("# Added by LM Studio CLI"),
              !output.contains(end) else { return nil }
        return output
    }

    /// Homebrew downloads use a SHA-256 URL hash, never a fuzzy product match.
    static func ownsBrewCache(_ url: URL, product: SWPLocalAIProduct, home: URL) -> Bool {
        let cache = SWPLocalAIPathIdentity.lexicalURL(home.appendingPathComponent("Library/Caches/Homebrew"))
        let parent = SWPLocalAIPathIdentity.lexicalURL(url.deletingLastPathComponent())
        let name = url.lastPathComponent
        let download = parent == cache.appendingPathComponent("downloads")
        guard download || parent == cache || parent == cache.appendingPathComponent("Cask") else { return false }
        let prefix = download ? "[0-9a-f]{64}--" : ""
        let version = "[0-9]+(?:\\.[0-9]+)+(?:[_-][0-9]+)?"
        if product == .ollama, parent == cache,
           name.range(of: "\\Aollama(?:_bottle_manifest)?--" + version + "\\z", options: .regularExpression) != nil {
            return true
        }
        let pattern: String
        switch product {
        case .lmStudio:
            pattern = prefix + "(?:LM-Studio-" + version + "-(?:arm64|x64)\\.dmg|LM(?:[+ -]|%20)Studio-darwin-(?:arm64|x64)-" + version + "\\.zip|lm-studio--?" + version + "\\.(?:dmg|zip))"
        case .ollama:
            pattern = prefix + "(?:Ollama-darwin\\.zip|ollama\\.dmg|ollama--?" + version + "(?:\\.(?:arm64_)?[a-z][a-z0-9_]*\\.bottle(?:\\.[0-9]+)?\\.tar\\.gz|\\.bottle_manifest\\.json|\\.tar\\.gz)|ollama-app--?" + version + "\\.zip)"
        }
        return name.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    /// The sole link exception: Homebrew's exact version aliases point to an
    /// owned download in the same cache. Inspect the link text, never its data.
    static func isOwnedBrewCacheAlias(_ url: URL, product: SWPLocalAIProduct, home: URL,
                                     storedAt: URL? = nil) -> Bool {
        let cache = SWPLocalAIPathIdentity.lexicalURL(home.appendingPathComponent("Library/Caches/Homebrew"))
        let alias = SWPLocalAIPathIdentity.lexicalURL(url)
        let source = storedAt ?? alias
        guard product == .ollama, alias.deletingLastPathComponent() == cache,
              alias.lastPathComponent.range(of: "\\Aollama(?:_bottle_manifest)?--[0-9]+(?:\\.[0-9]+)+(?:[_-][0-9]+)?\\z", options: .regularExpression) != nil,
              SWPSafety.isUnlinkedLocalAIPath(cache, within: home),
              let metadata = try? SWPLocalAIPathIdentity.metadata(source),
              metadata.st_mode & S_IFMT == S_IFLNK,
              let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path),
              raw.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let destination = SWPLocalAIPathIdentity.lexicalURL(raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : cache.appendingPathComponent(raw))
        guard destination.deletingLastPathComponent() == cache.appendingPathComponent("downloads"),
              ownsBrewCache(destination, product: product, home: home),
              SWPSafety.isUnlinkedLocalAIPath(destination, within: home) else { return false }
        do {
            return try SWPLocalAIPathIdentity.metadata(destination).st_mode & S_IFMT == S_IFREG
        } catch {
            let error = error as NSError
            // The real download may already have been trashed earlier in this
            // same operation; the strictly owned dangling alias is still safe.
            return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
        }
    }

    func scan() -> [SWPLocalAIPlan] {
        var apps: [SWPLocalAIProduct: [URL]] = [:]
        var appBlockers: [String] = []
        var appNotes: [String] = []
        for root in applicationRoots {
            collectApps(in: root, depth: 1, apps: &apps, blockers: &appBlockers, notes: &appNotes)
        }
        return SWPLocalAIProduct.allCases.map { product in
            var blockers = appBlockers
            var notes = ["Shared Hugging Face caches, projects and custom model locations are not removed."] + appNotes
            var identities: [String: SWPLocalAIPathIdentity] = [:]
            var candidates = Self.homeTargets(for: product, home: home)
            if product == .ollama {
                candidates += brewPrefixes.map { $0.appendingPathComponent("var/log/ollama.log") }
            }
            let packages = brewPackages(for: product, blockers: &blockers)
            candidates += cacheFiles(for: product, blockers: &blockers, notes: &notes)
            let customLocations = inspectCustomLocations(for: product, notes: &notes, blockers: &blockers)
            var items: [SWPItem] = []
            for url in candidates {
                do {
                    guard try exists(url) else { continue }
                    if customLocations.contains(where: { $0 == url.path || $0.hasPrefix(url.path + "/") }) {
                        notes.append("Preserving \(url.path) because it contains a custom data location.")
                        continue
                    }
                    let verdict = SWPSafety.validateLocalAI(url, product: product, home: home, brewPrefixes: brewPrefixes)
                    guard verdict.isAllowed else {
                        blockers.append("Refusing unsafe or linked path: \(url.path)")
                        continue
                    }
                    if product == .ollama, url.deletingLastPathComponent().lastPathComponent == "LaunchAgents" {
                        try requireOwnedLaunchAgent(url, appURLs: apps[.ollama] ?? [], packages: packages)
                    }
                    let alias = Self.isOwnedBrewCacheAlias(url, product: product, home: home)
                    let size: Int64
                    if alias { size = 0 }
                    else { size = try measuredSize(url) }
                    let metadata = try SWPLocalAIPathIdentity.metadata(url)
                    identities[url.path] = SWPLocalAIPathIdentity(device: metadata.st_dev, inode: metadata.st_ino)
                    let modified = Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
                    items.append(SWPItem(url: url, sizeBytes: size, modified: modified,
                                         location: "Local AI · \(product.name)", requiresAdmin: SWPSafety.requiresAdmin(url)))
                } catch { blockers.append("Cannot inspect \(url.path): \(error.localizedDescription)") }
            }
            let appURLs = (apps[product] ?? []).sorted { $0.path < $1.path }
            for url in appURLs {
                do { identities[url.path] = try SWPLocalAIPathIdentity.capture(url) }
                catch { blockers.append("Cannot identify \(url.path): \(error.localizedDescription)") }
            }
            var shellContents: [String: String] = [:]
            if product == .lmStudio {
                for name in [".zshrc", ".bash_profile", ".profile", ".bashrc"] {
                    let url = home.appendingPathComponent(name)
                    do {
                        guard try exists(url) else { continue }
                        try requireUnlinked(url, within: home)
                        let content = try String(contentsOf: url, encoding: .utf8)
                        if Self.shellBlock(in: content, home: home) != nil {
                            shellContents[url.path] = content
                            identities[url.path] = try SWPLocalAIPathIdentity.capture(url)
                        } else if content.contains("# Added by LM Studio CLI") || content.contains("# End of LM Studio CLI section") {
                            notes.append("Edited or unrecognized LM Studio shell setup is preserved: \(url.path)")
                        }
                    } catch { blockers.append("Cannot inspect shell profile \(url.path): \(error.localizedDescription)") }
                }
            }
            let cli = hasCLI(for: product, blockers: &blockers)
            let brew = packages.first.map { $0.prefix.appendingPathComponent("bin/brew") }
            return SWPLocalAIPlan(product: product, items: items.sorted { $0.url.path < $1.url.path },
                                  appURLs: appURLs, brewExecutable: brew, hasBrewPackage: !packages.isEmpty,
                                  shellProfiles: shellContents.keys.sorted().map { URL(fileURLWithPath: $0) },
                                  blockers: Array(Set(blockers)).sorted(), notes: notes,
                                  brewPackages: packages, pathIdentities: identities, shellContents: shellContents, hasCLI: cli)
        }
    }

    private func exists(_ url: URL) throws -> Bool {
        do { _ = try SWPLocalAIPathIdentity.metadata(url); return true }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return false }
    }

    private func requireUnlinked(_ url: URL, within root: URL) throws {
        guard SWPSafety.isUnlinkedLocalAIPath(url, within: root) else {
            throw NSError(domain: "Sweep.LocalAI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Linked or unreadable path is not safe to inspect"])
        }
    }

    private func children(_ root: URL) throws -> [URL] {
        guard try exists(root) else { return [] }
        try requireUnlinked(root, within: root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    }

    private func collectApps(in root: URL, depth: Int, apps: inout [SWPLocalAIProduct: [URL]], blockers: inout [String], notes: inout [String]) {
        do {
            for url in try children(root) {
                let knownName = ["LM Studio.app", "Ollama.app"].contains(url.lastPathComponent)
                do {
                    let metadata = try SWPLocalAIPathIdentity.metadata(url)
                    if metadata.st_mode & S_IFMT == S_IFLNK {
                        if knownName { throw CocoaError(.fileReadInvalidFileName) }
                        continue
                    }
                    guard metadata.st_mode & S_IFMT == S_IFDIR else { continue }
                    if url.pathExtension.lowercased() == "app" {
                        let plist = url.appendingPathComponent("Contents/Info.plist")
                        guard try exists(plist) else {
                            if knownName { throw CocoaError(.fileNoSuchFile) }
                            continue
                        }
                        try requireUnlinked(plist, within: root)
                        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
                              let identifier = info["CFBundleIdentifier"] as? String else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        if let product = Self.product(forAppBundleID: identifier) {
                            apps[product, default: []].append(url)
                        }
                    } else if depth > 0 {
                        collectApps(in: url, depth: depth - 1, apps: &apps, blockers: &blockers, notes: &notes)
                    }
                } catch {
                    let message = "Cannot identify application at \(url.path): \(error.localizedDescription)"
                    if knownName { blockers.append(message) }
                    else { notes.append(message + " This unrelated application was not included.") }
                }
            }
        } catch {
            let message = "Cannot inspect applications in \(root.path): \(error.localizedDescription)"
            if depth > 0 { blockers.append(message) }
            else { notes.append(message) }
        }
    }

    private func brewPackages(for product: SWPLocalAIProduct, blockers: inout [String]) -> [SWPLocalAIBrewPackage] {
        var result: [SWPLocalAIBrewPackage] = []
        let registrations: [(String, Bool)] = product == .ollama ? [("ollama", false), ("ollama-app", true)] : [("lm-studio", true)]
        for prefix in brewPrefixes {
            for (token, isCask) in registrations {
                let folder = prefix.appendingPathComponent(isCask ? "Caskroom/\(token)" : "Cellar/\(token)")
                do {
                    guard try exists(folder) else { continue }
                    try requireUnlinked(folder, within: prefix)
                    var versions = Set<String>()
                    let roots = isCask ? [folder, folder.appendingPathComponent(".metadata")] : [folder]
                    for root in roots {
                        guard try exists(root) else { continue }
                        try requireUnlinked(root, within: prefix)
                        for version in try children(root) where !version.lastPathComponent.hasPrefix(".") {
                            try requireUnlinked(version, within: prefix)
                            if try SWPLocalAIPathIdentity.metadata(version).st_mode & S_IFMT == S_IFDIR {
                                versions.insert(version.lastPathComponent)
                            }
                        }
                    }
                    guard !versions.isEmpty else { continue }
                    result.append(SWPLocalAIBrewPackage(prefix: prefix, token: token, isCask: isCask, installedVersions: versions.sorted()))
                    if !FileManager.default.isExecutableFile(atPath: prefix.appendingPathComponent("bin/brew").path) {
                        blockers.append("Homebrew package is registered but its brew executable is unavailable: \(folder.path)")
                    }
                } catch { blockers.append("Cannot inspect Homebrew registration \(folder.path): \(error.localizedDescription)") }
            }
        }
        return result
    }

    private func cacheFiles(for product: SWPLocalAIProduct, blockers: inout [String], notes: inout [String]) -> [URL] {
        let cache = home.appendingPathComponent("Library/Caches/Homebrew")
        var result: [URL] = []
        for folder in [cache, cache.appendingPathComponent("downloads"), cache.appendingPathComponent("Cask")] {
            do {
                guard try exists(folder) else { continue }
                try requireUnlinked(folder, within: home)
                for url in try children(folder) where Self.ownsBrewCache(url, product: product, home: home) {
                    if try SWPLocalAIPathIdentity.metadata(url).st_mode & S_IFMT == S_IFLNK,
                       !Self.isOwnedBrewCacheAlias(url, product: product, home: home) {
                        notes.append("Homebrew cache link is preserved; its destination is not followed: \(url.path)")
                    } else {
                        result.append(url)
                    }
                }
            } catch { blockers.append("Cannot inspect Homebrew cache \(folder.path): \(error.localizedDescription)") }
        }
        return result
    }

    private func hasCLI(for product: SWPLocalAIProduct, blockers: inout [String]) -> Bool {
        let urls = product == .lmStudio
            ? [home.appendingPathComponent(".lmstudio/bin/lms"), home.appendingPathComponent(".cache/lm-studio/bin/lms")]
            : brewPrefixes.map { $0.appendingPathComponent("bin/ollama") }
        var found = false
        for url in urls {
            do {
                if try exists(url), FileManager.default.isExecutableFile(atPath: url.path) { found = true }
            } catch { blockers.append("Cannot inspect command-line installation \(url.path): \(error.localizedDescription)") }
        }
        return found
    }

    private func requireOwnedLaunchAgent(_ url: URL, appURLs: [URL], packages: [SWPLocalAIBrewPackage]) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              let label = plist["Label"] as? String, label + ".plist" == url.lastPathComponent else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        guard let program = plist["Program"] as? String ?? arguments.first else { throw CocoaError(.fileReadCorruptFile) }
        let executable = SWPLocalAIPathIdentity.lexicalURL(URL(fileURLWithPath: program))
        var known: [URL] = []
        if label == "homebrew.mxcl.ollama" {
            for prefix in brewPrefixes {
                known += ["bin/ollama", "opt/ollama/bin/ollama"].map { prefix.appendingPathComponent($0) }
                for package in packages where package.prefix == prefix && !package.isCask {
                    known += package.installedVersions.map { prefix.appendingPathComponent("Cellar/ollama/\($0)/bin/ollama") }
                }
            }
        } else if label == "com.ollama.ollama" {
            let conventional = applicationRoots.map { $0.appendingPathComponent("Ollama.app") }
            for app in Set(appURLs + conventional) {
                known += ["Contents/Resources/ollama", "Contents/MacOS/Ollama", "Contents/MacOS/ollama"].map { app.appendingPathComponent($0) }
            }
        }
        guard program.hasPrefix("/"), known.contains(executable),
              arguments.isEmpty || arguments.first == program else {
            throw NSError(domain: "Sweep.LocalAI", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Launch agent ownership is uncertain; its program is not a known Ollama executable"])
        }
    }

    private func inspectCustomLocations(for product: SWPLocalAIProduct, notes: inout [String], blockers: inout [String]) -> [String] {
        var protected: [String] = []
        func warn(_ value: String, defaults: [URL], source: URL) {
            let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            if !defaults.contains(where: { $0.path == path }) {
                notes.append("Custom data location is preserved, not followed: \(path) (from \(source.path)).")
                if path.hasPrefix("/") {
                    protected.append(SWPLocalAIPathIdentity.lexicalURL(URL(fileURLWithPath: path)).path)
                } else {
                    blockers.append("Cannot safely interpret custom data location in \(source.path): \(path)")
                }
            }
        }
        let lmRoots = [home.appendingPathComponent(".lmstudio"), home.appendingPathComponent(".cache/lm-studio")]
        if product == .lmStudio {
            let pointer = home.appendingPathComponent(".lmstudio-home-pointer")
            do {
                if try exists(pointer) {
                    try requireUnlinked(pointer, within: home)
                    warn(try String(contentsOf: pointer, encoding: .utf8), defaults: lmRoots, source: pointer)
                }
            } catch { blockers.append("Cannot read LM Studio home pointer: \(error.localizedDescription)") }
            let settings = (lmRoots + [home.appendingPathComponent("Library/Application Support/LM Studio")]).map { $0.appendingPathComponent("settings.json") }
            for url in settings {
                do {
                    guard try exists(url) else { continue }
                    try requireUnlinked(url, within: home)
                    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    if let value = object["downloadsFolder"] {
                        guard let path = value as? String else { throw CocoaError(.fileReadCorruptFile) }
                        warn(path, defaults: lmRoots.map { $0.appendingPathComponent("models") }, source: url)
                    }
                } catch { blockers.append("Cannot inspect LM Studio settings \(url.path): \(error.localizedDescription)") }
            }
        } else {
            let paths = ["Library/LaunchAgents/homebrew.mxcl.ollama.plist", "Library/LaunchAgents/com.ollama.ollama.plist"]
            for url in paths.map({ home.appendingPathComponent($0) }) {
                do {
                    guard try exists(url) else { continue }
                    try requireUnlinked(url, within: home)
                    guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    if let environment = plist["EnvironmentVariables"] as? [String: Any], let value = environment["OLLAMA_MODELS"] {
                        guard let path = value as? String else { throw CocoaError(.fileReadCorruptFile) }
                        warn(path, defaults: [home.appendingPathComponent(".ollama/models")], source: url)
                    }
                } catch { blockers.append("Cannot inspect Ollama launch settings \(url.path): \(error.localizedDescription)") }
            }
            notes.append("Runtime OLLAMA_MODELS overrides are not cleanup targets; custom model data remains untouched.")
        }
        return protected
    }

    /// Matches the existing allocated-size convention, but does not silently
    /// hide unreadable subtrees in this destructive per-product review.
    private func measuredSize(_ url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileResourceIdentifierKey]
        let root = try url.resourceValues(forKeys: keys)
        if root.isDirectory != true { return Int64(root.totalFileAllocatedSize ?? root.fileAllocatedSize ?? 0) }
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
            failure = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var total: Int64 = 0
        var seen = Set<NSObject>()
        while let child = enumerator.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            let value = try child.resourceValues(forKeys: keys)
            if value.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if value.isDirectory == true { continue }
            if let identifier = value.fileResourceIdentifier as? NSObject, !seen.insert(identifier).inserted { continue }
            total += Int64(value.totalFileAllocatedSize ?? value.fileAllocatedSize ?? 0)
        }
        if let failure { throw failure }
        return total
    }
}
