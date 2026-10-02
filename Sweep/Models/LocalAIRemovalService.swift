import Foundation
import Darwin

struct SWPLocalAICleanupResult: Sendable {
    var messages: [String] = []
    var failures: [String] = []
    var trashedBytes: Int64 = 0
    var succeeded: Bool { failures.isEmpty }
}

/// All destructive entry points are explicit. The default initializer never executes
/// a brew discovered outside the two supported, real installation prefixes.
final class SWPLocalAIRemovalService: Sendable {
    struct CommandResult: Sendable {
        let status: Int32
        let output: String
    }

    struct Runtime: Equatable, Sendable {
        let pid: Int32
        let uid: UInt32
        let executable: String
    }

    /// Test hooks are deliberately available only with an explicit fixture root.
    /// Injected commands and removal operations cannot accidentally fall through to
    /// their production equivalents.
    struct FixtureContext: Sendable {
        let root: URL
        let home: URL
        let scan: @Sendable () -> [SWPLocalAIPlan]
        let command: @Sendable (URL, [String]) throws -> CommandResult
        let runtimes: @Sendable () throws -> [Runtime]
        let terminate: @Sendable (Runtime) throws -> Void
        let trash: @Sendable ([SWPItem], Bool) -> SWPRemovalOutcome
        let backup: @Sendable (URL, Data) throws -> URL
    }

    private let fixture: FixtureContext?
    private var home: URL { fixture?.home ?? FileManager.default.homeDirectoryForCurrentUser }

    init() { fixture = nil }
    init(fixture: FixtureContext) { self.fixture = fixture }

    func remove(_ plan: SWPLocalAIPlan) -> SWPLocalAICleanupResult {
        var result = SWPLocalAICleanupResult()
        do {
            let fresh = try revalidate(plan)
            result.messages.append(contentsOf: fresh.notes)
            // Resolve every package prerequisite before stopping anything or trashing data.
            for package in fresh.brewPackages {
                try validateBrew(package)
                if package.isCask {
                    try validateCask(package, plan: fresh)
                } else {
                    let dependents = try checked(brew(package), ["uses", "--installed", "ollama"])
                    guard dependents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw Refusal("Homebrew dependents prevent uninstalling Ollama: \(dependents)")
                    }
                }
            }
            _ = try ownedRuntimes(fresh) // Fail before service changes if ownership is uncertain.
            for package in fresh.brewPackages where !package.isCask {
                try rejectSystemService("homebrew.mxcl.ollama")
                _ = try checked(brew(package), ["services", "stop", "ollama"])
                result.messages.append("Stopped the Ollama Homebrew service at \(package.prefix.path).")
                try verifyBrewServiceStopped(package)
            }
            if fresh.product == .ollama {
                try stopLaunchAgent("homebrew.mxcl.ollama", plan: fresh)
                try stopLaunchAgent("com.ollama.ollama", plan: fresh)
            }
            try stopRuntimes(fresh)
            result.messages.append("Verified that no owned \(fresh.product.name) runtime is running.")

            // Stop commands can cause legitimate files to disappear, but must never
            // expand the user-reviewed set or replace an object behind its path.
            let stopped = try revalidate(plan)
            for package in stopped.brewPackages where !package.isCask {
                let dependents = try checked(brew(package), ["uses", "--installed", "ollama"])
                guard dependents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Refusal("Homebrew dependents changed while stopping Ollama; package and data removal were stopped.")
                }
                try verifyBrewServiceStopped(package)
                try requireStopped(stopped)
                _ = try checked(brew(package), ["uninstall", "--formula", "--force", "ollama"])
                result.messages.append("Permanently uninstalled all reviewed Ollama formula versions at \(package.prefix.path).")
            }
            for app in stopped.appURLs {
                try checkIdentity(app, plan: plan)
                try requireStopped(stopped)
                let item = SWPItem(url: app, sizeBytes: try allocatedSize(app), modified: nil,
                                   location: "Applications", requiresAdmin: false)
                try merge(trash([item], app: true, product: plan.product), into: &result)
                result.messages.append("Moved application to Trash: \(app.path)")
            }
            for package in stopped.brewPackages where package.isCask {
                // Homebrew owns its registration and exact CLI symlink. Its normal
                // uninstall is allowed only after the app has safely reached Trash.
                guard stopped.appURLs.allSatisfy({ !exists($0) }) else {
                    throw Refusal("An application remains; cask removal was not attempted.")
                }
                try validateCask(package, plan: stopped)
                try requireStopped(stopped)
                _ = try checked(brew(package), ["uninstall", "--cask", "--force", package.token])
                result.messages.append("Permanently removed Homebrew cask registration: \(package.token) (\(package.prefix.path)).")
            }
            var orderedItems = stopped.items
            // Trash a reviewed cache alias before its download, while the exact
            // destination can still pass the point-of-removal ownership check.
            _ = orderedItems.partition {
                !SWPLocalAIScanner.isOwnedBrewCacheAlias($0.url, product: plan.product, home: home)
            }
            for item in orderedItems {
                guard exists(item.url) else { continue }
                try checkIdentity(item.url, plan: plan)
                try requireStopped(stopped)
                try merge(trash([item], app: false, product: plan.product), into: &result)
                result.messages.append("Moved to Trash: \(item.url.path)")
            }
            for profile in stopped.shellProfiles {
                try editProfile(profile, plan: plan, result: &result)
            }
            try requireStopped(stopped)
            let remaining = scan().first { $0.product == plan.product }
            guard let remaining else { throw Refusal("The verification scan did not return this product.") }
            guard remaining.blockers.isEmpty else { throw Refusal(remaining.blockers.joined(separator: "\n")) }
            guard !remaining.hasWork, !remaining.isInstalled else {
                throw Refusal("Verification found remaining \(plan.product.name) data, shell configuration, or an installed package. Refresh and review the remaining paths.")
            }
            result.messages.append("Verified cleanup of the reviewed \(plan.product.name) installation. Custom model locations and shared caches were not touched.")
        } catch {
            result.failures.append(error.localizedDescription)
        }
        return result
    }

    private struct Refusal: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func scan() -> [SWPLocalAIPlan] { fixture?.scan() ?? SWPLocalAIScanner().scan() }
    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func revalidate(_ plan: SWPLocalAIPlan) throws -> SWPLocalAIPlan {
        guard plan.blockers.isEmpty else { throw Refusal(plan.blockers.joined(separator: "\n")) }
        guard let fresh = scan().first(where: { $0.product == plan.product }) else {
            throw Refusal("The verification scan did not return this product.")
        }
        guard fresh.blockers.isEmpty else { throw Refusal(fresh.blockers.joined(separator: "\n")) }
        let reviewed = Set(plan.items.map(\.url) + plan.appURLs + plan.shellProfiles)
        let current = Set(fresh.items.map(\.url) + fresh.appURLs + fresh.shellProfiles)
        guard current.isSubset(of: reviewed) else {
            throw Refusal("The installation changed since review. Refresh before removing newly discovered paths.")
        }
        // Reject forged/obsolete selections rather than silently treating them as approved.
        for url in reviewed {
            try safePath(url)
            if exists(url) {
                guard current.contains(url) else {
                    throw Refusal("A reviewed path no longer has verified product ownership: \(url.path)")
                }
                try checkIdentity(url, plan: plan)
            }
        }
        guard packageKeys(fresh).isSubset(of: packageKeys(plan)) else {
            throw Refusal("Homebrew packages changed since review. Refresh before uninstalling.")
        }
        for profile in fresh.shellProfiles {
            guard let content = plan.shellContents[profile.path],
                  try String(contentsOf: profile, encoding: .utf8) == content else {
                throw Refusal("Shell profile changed since review: \(profile.path)")
            }
        }
        return fresh
    }

    private func packageKeys(_ plan: SWPLocalAIPlan) -> Set<String> {
        Set(plan.brewPackages.map { "\($0.prefix.path)|\($0.token)|\($0.isCask)|\($0.installedVersions.sorted().joined(separator: ","))" })
    }

    private func safePath(_ url: URL) throws {
        let standardized = SWPLocalAIPathIdentity.lexicalURL(url)
        if let fixture {
            let root = SWPLocalAIPathIdentity.lexicalURL(fixture.root).path
            guard standardized.path.hasPrefix(root + "/"), home.path.hasPrefix(root + "/") else {
                throw Refusal("Fixture operation escaped its explicit root.")
            }
        }
        var component = standardized
        while component.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let reviewedCacheAlias = component == standardized && SWPLocalAIProduct.allCases.contains {
                    SWPLocalAIScanner.isOwnedBrewCacheAlias(component, product: $0, home: home)
                }
                guard reviewedCacheAlias else { throw Refusal("Refusing symbolic link path: \(component.path)") }
            }
            component.deleteLastPathComponent()
        }
    }

    private func checkIdentity(_ url: URL, plan: SWPLocalAIPlan) throws {
        try safePath(url)
        guard let reviewed = plan.pathIdentities[url.path],
              try SWPLocalAIPathIdentity.capture(url) == reviewed else {
            throw Refusal("A reviewed object was replaced or is no longer readable: \(url.path). Refresh before removing it.")
        }
    }

    private func brew(_ package: SWPLocalAIBrewPackage) -> URL {
        package.prefix.appendingPathComponent("bin/brew")
    }

    private func validateBrew(_ package: SWPLocalAIBrewPackage) throws {
        let prefix = SWPLocalAIPathIdentity.lexicalURL(package.prefix).path
        if fixture == nil {
            guard ["/opt/homebrew", "/usr/local"].contains(prefix) else {
                throw Refusal("Unsupported Homebrew prefix: \(prefix)")
            }
            // Homebrew's bin/brew is normally a symlink into its own repository.
            let resolved = SWPLocalAIPathIdentity.resolvedURL(brew(package)).path
            guard resolved.hasPrefix(prefix + "/"), FileManager.default.isExecutableFile(atPath: resolved) else {
                throw Refusal("Homebrew executable is missing or resolves outside its prefix.")
            }
        } else {
            try safePath(package.prefix)
        }
        guard (package.isCask && ["lm-studio", "ollama-app"].contains(package.token))
                || (!package.isCask && package.token == "ollama") else {
            throw Refusal("Unrecognized package in cleanup plan: \(package.token)")
        }
    }

    private func validateCask(_ package: SWPLocalAIBrewPackage, plan: SWPLocalAIPlan) throws {
        guard package.token == (plan.product == .lmStudio ? "lm-studio" : "ollama-app") else {
            throw Refusal("Cask does not belong to the reviewed product.")
        }
        let text = try checked(brew(package), ["info", "--json=v2", "--cask", package.token])
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]], casks.count == 1,
              let cask = casks.first, cask["token"] as? String == package.token else {
            throw Refusal("Cannot verify installed cask removal instructions for \(package.token).")
        }
        try validateCaskArtifacts(cask, package: package, plan: plan)
        let metadata = package.prefix.appendingPathComponent("Caskroom/\(package.token)/.metadata")
        try safePath(metadata)
        // Uninstall can load the historic installed definition, not today's tap.
        // Only declarative JSON receipts are safe to inspect without executing Ruby.
        var receiptCount = 0
        for version in package.installedVersions {
            let versionDirectory = metadata.appendingPathComponent(version)
            try safePath(versionDirectory)
            for timestamp in try FileManager.default.contentsOfDirectory(at: versionDirectory, includingPropertiesForKeys: nil) {
                try safePath(timestamp)
                let directory = timestamp.appendingPathComponent("Casks")
                guard exists(directory) else { continue }
                try safePath(directory)
                let ruby = directory.appendingPathComponent(package.token + ".rb")
                guard !exists(ruby) else {
                    throw Refusal("Legacy Ruby cask receipt cannot be safely inspected. Uninstall \(package.token) manually, then refresh.")
                }
                let receipt = directory.appendingPathComponent(package.token + ".json")
                try safePath(receipt)
                let attributes = try FileManager.default.attributesOfItem(atPath: receipt.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576,
                      var object = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any],
                      object["token"] == nil || object["token"] as? String == package.token else {
                    throw Refusal("Installed cask receipt cannot be verified.")
                }
                // Current Homebrew stores {} here and keeps the declarative
                // uninstall artifacts in INSTALL_RECEIPT.json instead.
                if object["artifacts"] == nil {
                    let tab = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
                    try safePath(tab)
                    let tabAttributes = try FileManager.default.attributesOfItem(atPath: tab.path)
                    guard (tabAttributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576,
                          let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: tab)) as? [String: Any],
                          installed["uninstall_flight_blocks"] as? Bool == false,
                          let source = installed["source"] as? [String: Any],
                          source["tap"] as? String == "homebrew/cask",
                          source["version"] as? String == version,
                          let artifacts = installed["uninstall_artifacts"] as? [[String: Any]] else {
                        throw Refusal("Installed Homebrew receipt has no verifiable declarative uninstall instructions.")
                    }
                    object["artifacts"] = artifacts
                }
                try validateCaskArtifacts(object, package: package, plan: plan)
                receiptCount += 1
            }
        }
        guard receiptCount > 0 else { throw Refusal("No inspectable installed cask receipt was found.") }
        let config = metadata.appendingPathComponent("config.json")
        try safePath(config)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config))
        try validateCaskAppDirectory(object)
    }

    private func validateCaskAppDirectory(_ value: Any) throws {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == "appdir" {
                    guard let path = child as? String,
                          ["/Applications", home.appendingPathComponent("Applications").path].contains(path) else {
                        throw Refusal("Custom Homebrew cask app directory is not a cleanup target.")
                    }
                } else { try validateCaskAppDirectory(child) }
            }
        } else if let array = value as? [Any] {
            for child in array { try validateCaskAppDirectory(child) }
        }
    }

    private func validateCaskArtifacts(_ object: [String: Any], package: SWPLocalAIBrewPackage, plan: SWPLocalAIPlan) throws {
        guard let artifacts = object["artifacts"] as? [[String: Any]], !artifacts.isEmpty else {
            throw Refusal("Cannot verify cask removal instructions.")
        }
        let expectedApp = plan.product == .lmStudio ? "LM Studio.app" : "Ollama.app"
        let roots = fixture == nil
            ? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            : [home.appendingPathComponent("Applications")]
        let knownApps = roots.map { $0.appendingPathComponent(expectedApp) }
        for app in knownApps where exists(app) {
            guard plan.appURLs.contains(app) else {
                throw Refusal("Cask would touch an application that was not reviewed: \(app.path)")
            }
        }
        for artifact in artifacts {
            for (kind, value) in artifact {
                switch kind {
                case "zap": continue // Never invoked.
                case "target":
                    guard let target = value as? String else {
                        throw Refusal("Cask target is not a verifiable path.")
                    }
                    let appTarget = artifact["app"] != nil && knownApps.contains { $0.path == target }
                    let binaryTarget = artifact["binary"] != nil && package.token == "ollama-app"
                        && target == package.prefix.appendingPathComponent("bin/ollama").path
                    guard appTarget || binaryTarget else {
                        throw Refusal("Cask target is outside the reviewed application or CLI location: \(target)")
                    }
                case "app":
                    guard let args = value as? [String], args == [expectedApp] else {
                        throw Refusal("Custom cask application target requires manual review.")
                    }
                case "binary":
                    guard package.token == "ollama-app", let args = value as? [String], args.count == 1,
                          (plan.appURLs + knownApps.filter { !exists($0) }).contains(where: {
                              args[0] == $0.appendingPathComponent("Contents/Resources/ollama").path
                          }) else {
                        throw Refusal("Unrecognized cask CLI link; refusing package removal.")
                    }
                    try validateCaskBinaryLink(package, source: args[0])
                case "uninstall":
                    guard let actions = value as? [[String: Any]] else { throw Refusal("Unrecognized cask uninstall instructions.") }
                    for action in actions {
                        for (key, raw) in action {
                            let names = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
                            let quitIDs = plan.product == .lmStudio
                                ? plan.product.bundleIDs.union(["ai.elementlabs.lmstudio.helper"]) : plan.product.bundleIDs
                            let allowed = key == "quit" ? quitIDs :
                                (key == "launchctl" && plan.product == .ollama ? Set(["com.ollama.ollama"]) : Set<String>())
                            guard !names.isEmpty, Set(names).isSubset(of: allowed) else {
                                throw Refusal("Cask has unreviewed uninstall hooks; remove it manually before retrying.")
                            }
                        }
                    }
                default: throw Refusal("Cask artifact \(kind) is not approved for automatic removal.")
                }
            }
        }
    }

    private func validateCaskBinaryLink(_ package: SWPLocalAIBrewPackage, source: String) throws {
        let target = package.prefix.appendingPathComponent("bin/ollama")
        try safePath(target.deletingLastPathComponent())
        guard exists(target) else { return }
        guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else {
            throw Refusal("The Ollama CLI location is not its cask-owned symbolic link.")
        }
        let destination = SWPLocalAIPathIdentity.lexicalURL(raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw) : target.deletingLastPathComponent().appendingPathComponent(raw))
        guard destination.path == source else {
            throw Refusal("Another installation owns the Ollama CLI link; refusing cask removal.")
        }
    }

    private func rejectSystemService(_ label: String) throws {
        let reply = try command(URL(fileURLWithPath: "/bin/launchctl"), ["print", "system/" + label])
        guard reply.status != 0 else {
            throw Refusal("A system-wide \(label) service is registered. Stop and remove that service as its administrator before retrying.")
        }
        guard reply.status == 113 else { throw Refusal("Cannot verify system service \(label): \(reply.output)") }
    }

    private func verifyBrewServiceStopped(_ package: SWPLocalAIBrewPackage) throws {
        let text = try checked(brew(package), ["services", "list", "--json"])
        guard let data = text.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Refusal("Cannot verify Homebrew service state.")
        }
        for row in rows where row["name"] as? String == "ollama" {
            guard let status = row["status"] as? String, ["none", "stopped"].contains(status) else {
                throw Refusal("Ollama Homebrew service is still active or in an uncertain state.")
            }
        }
    }

    private func stopLaunchAgent(_ label: String, plan: SWPLocalAIPlan) throws {
        try rejectSystemService(label)
        let target = "gui/\(getuid())/\(label)"
        let reply = try command(URL(fileURLWithPath: "/bin/launchctl"), ["print", target])
        if reply.status == 113 { return }
        guard reply.status == 0 else { throw Refusal("Cannot inspect launch agent \(label): \(reply.output)") }
        let programs = reply.output.split(separator: "\n").compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("program = ") ? String(value.dropFirst("program = ".count)) : nil
        }
        guard programs.count == 1, isOwnedExecutable(programs[0], plan: plan) else {
            throw Refusal("Ollama launch agent has uncertain executable ownership.")
        }
        _ = try checked(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", target])
        let after = try command(URL(fileURLWithPath: "/bin/launchctl"), ["print", target])
        guard after.status == 113 else { throw Refusal("Ollama launch agent remained registered or could not be verified after stopping.") }
    }

    private func isOwnedExecutable(_ rawPath: String, plan: SWPLocalAIPlan) -> Bool {
        let path = SWPLocalAIPathIdentity.resolvedURL(URL(fileURLWithPath: rawPath)).path
        if plan.appURLs.contains(where: { path.hasPrefix($0.path + "/Contents/") }) { return true }
        if plan.product == .ollama {
            return plan.brewPackages.filter { !$0.isCask }.contains { package in
                package.installedVersions.contains { version in
                    let root = package.prefix.appendingPathComponent("Cellar/ollama/" + version).path
                    return path == root + "/bin/ollama" || path.hasPrefix(root + "/libexec/")
                }
            }
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return [".lmstudio", ".cache/lm-studio"].contains { relative in
            let root = home.appendingPathComponent(relative).path
            return path == root + "/bin/lms" || path == root + "/bin/llmster"
                || (path.hasPrefix(root + "/llmster/") && name == "llmster")
                || (path.hasPrefix(root + "/extensions/backends/") && ["llama-server", "llama-server-metal", "llama-server-vulkan"].contains(name))
        }
    }

    private func ownedRuntimes(_ plan: SWPLocalAIPlan) throws -> [Runtime] {
        let all = try runtimes()
        var owned: [Runtime] = []
        let suspect: Set<String> = plan.product == .ollama ? ["ollama", "Ollama"] : ["lms", "llmster", "LM Studio"]
        for runtime in all {
            if isOwnedExecutable(runtime.executable, plan: plan) {
                try safePath(SWPLocalAIPathIdentity.resolvedURL(URL(fileURLWithPath: runtime.executable)))
                guard runtime.uid == getuid() else {
                    throw Refusal("A \(plan.product.name) runtime belongs to another user (PID \(runtime.pid)).")
                }
                owned.append(runtime)
            } else if suspect.contains(URL(fileURLWithPath: runtime.executable).lastPathComponent)
                        || (plan.product == .lmStudio && [".lmstudio", ".cache/lm-studio"].contains(where: {
                            runtime.executable.hasPrefix(home.appendingPathComponent($0).path + "/")
                        })) {
                throw Refusal("Cannot prove ownership of runtime PID \(runtime.pid): \(runtime.executable). Stop it manually before retrying.")
            }
        }
        return owned
    }

    private func requireStopped(_ plan: SWPLocalAIPlan) throws {
        guard try ownedRuntimes(plan).isEmpty else {
            throw Refusal("A \(plan.product.name) runtime is still running or restarted. Remaining removal operations were stopped.")
        }
        if plan.product == .ollama {
            for label in ["homebrew.mxcl.ollama", "com.ollama.ollama"] {
                try rejectSystemService(label)
                let reply = try command(URL(fileURLWithPath: "/bin/launchctl"), ["print", "gui/\(getuid())/\(label)"])
                guard reply.status == 113 else {
                    throw Refusal("Launch agent \(label) is still registered or could not be verified stopped.")
                }
            }
        }
    }

    private func stopRuntimes(_ plan: SWPLocalAIPlan) throws {
        for runtime in try ownedRuntimes(plan) {
            // Re-inspect immediately before signalling: a PID alone is not ownership.
            guard try runtimes().contains(runtime) else { continue }
            if let fixture { try fixture.terminate(runtime) }
            else {
                guard runtime.uid == getuid(), kill(runtime.pid, SIGTERM) == 0 || errno == ESRCH else {
                    throw Refusal("Could not gracefully stop PID \(runtime.pid): \(String(cString: strerror(errno)))")
                }
            }
        }
        let deadline = Date().addingTimeInterval(fixture == nil ? 10 : 0)
        repeat {
            if try ownedRuntimes(plan).isEmpty { return }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
        throw Refusal("\(plan.product.name) did not stop gracefully. Quit it and retry; no runtime was force-killed.")
    }

    private func allocatedSize(_ root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        var readError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                              errorHandler: { _, error in readError = error; return false }) else {
            throw Refusal("Cannot measure application before moving it to Trash: \(root.path)")
        }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        if let readError { throw readError }
        return size
    }

    private func runtimes() throws -> [Runtime] {
        if let fixture { return try fixture.runtimes() }
        let text = try checked(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,uid=,comm="])
        var result: [Runtime] = []
        // sys/proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN;
        // that expression macro is not imported by Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for line in text.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int32(fields[0]), let uid = Int64(fields[1]),
                  uid >= Int64(Int32.min), uid <= Int64(UInt32.max) else {
                throw Refusal("Process inspection returned an unreadable record: \(line)")
            }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let path = length > 0
                ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                : String(fields[2])
            // Darwin ps prints reserved uid_t values such as nobody as signed (-2).
            result.append(Runtime(pid: pid, uid: UInt32(truncatingIfNeeded: uid), executable: path))
        }
        return result
    }

    private func trash(_ items: [SWPItem], app: Bool, product: SWPLocalAIProduct) -> SWPRemovalOutcome {
        if let fixture { return fixture.trash(items, app) }
        return SWPRemovalService().trashLocalAI(items, product: product, application: app)
    }

    private func merge(_ outcome: SWPRemovalOutcome, into result: inout SWPLocalAICleanupResult) throws {
        result.trashedBytes += outcome.trashedBytes
        let failures = outcome.failures.map { "\($0.path): \($0.reason)" }
            + outcome.refusedByPolicy.map { "Safety policy refused: \($0)" }
            + (outcome.adminCancelled ? ["Administrator authorization was cancelled."] : [])
        guard failures.isEmpty else { throw Refusal(failures.joined(separator: "\n")) }
    }

    private func editProfile(_ profile: URL, plan: SWPLocalAIPlan, result: inout SWPLocalAICleanupResult) throws {
        try checkIdentity(profile, plan: plan)
        guard plan.product == .lmStudio,
              [".zshrc", ".bashrc", ".bash_profile", ".profile"].contains(profile.lastPathComponent),
              SWPLocalAIPathIdentity.lexicalURL(profile.deletingLastPathComponent()).path == SWPLocalAIPathIdentity.lexicalURL(home).path,
              let reviewed = plan.shellContents[profile.path],
              try String(contentsOf: profile, encoding: .utf8) == reviewed,
              let cleaned = SWPLocalAIScanner.shellBlock(in: reviewed, home: home) else {
            throw Refusal("Shell profile no longer matches its reviewed generated block: \(profile.path)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: profile.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw Refusal("Shell profile must be a singly-linked regular file owned by the current user.")
        }
        let original = Data(reviewed.utf8)
        let backup = try backupProfile(profile, data: original)
        result.messages.append("Shell profile backup in Trash: \(backup.path)")
        // Check again after backup, before replacing any bytes.
        try checkIdentity(profile, plan: plan)
        guard try Data(contentsOf: profile) == original else { throw Refusal("Shell profile changed while backing it up.") }
        try Data(cleaned.utf8).write(to: profile, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: profile.path)
        }
        result.messages.append("Removed only the generated LM Studio CLI block from \(profile.path).")
    }

    private func backupProfile(_ profile: URL, data: Data) throws -> URL {
        if let fixture { return try fixture.backup(profile, data) }
        // Write the backup directly into the user's Trash, never a persistent cache.
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                 appropriateFor: profile, create: true)
        let target = trash.appendingPathComponent("Sweep LM Studio \(profile.lastPathComponent) \(UUID().uuidString).backup")
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw Refusal("Could not create a shell-profile backup in Trash.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        return target
    }

    private func checked(_ executable: URL, _ arguments: [String]) throws -> String {
        let result = try command(executable, arguments)
        guard result.status == 0 else {
            throw Refusal("\(executable.path) \(arguments.joined(separator: " ")) failed (\(result.status)): \(result.output)")
        }
        return result.output
    }

    private func command(_ executable: URL, _ arguments: [String]) throws -> CommandResult {
        if let fixture { return try fixture.command(executable, arguments) }
        return try Self.runCommand(executable, arguments)
    }

    private static func runCommand(_ executable: URL, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(),
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
                               "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_ANALYTICS": "1"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        var output = Data()
        process.standardOutput = pipe
        process.standardError = pipe
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw Refusal("Cannot configure bounded command output.") }
        try process.run()
        try pipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(90)
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var failure: String?
        repeat {
            let finished = !process.isRunning
            // A descendant retaining stdout must not make this read block forever.
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count <= 0 {
                    if count < 0 && errno != EAGAIN && errno != EINTR {
                        failure = "Cannot read command output."
                    }
                    break
                }
                guard output.count + count <= 1_048_576 else {
                    failure = "Command output exceeded its safety limit."
                    break
                }
                output.append(contentsOf: buffer.prefix(count))
                if Date() >= deadline { failure = "Command timed out."; break }
            }
            if Date() >= deadline { failure = "Command timed out." }
            if failure != nil || finished { break }
            Thread.sleep(forTimeInterval: 0.025)
        } while true
        if let failure {
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            throw Refusal("\(failure) \(executable.path) \(arguments.joined(separator: " ")). Effects may be partial; refresh before retrying.")
        }
        return CommandResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}
