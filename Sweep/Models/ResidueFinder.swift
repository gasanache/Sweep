import Foundation

// MARK: - Verdicts

/// What one Library entry is to the app being uninstalled.
enum SWPResidueKind: Equatable {
    /// Provably this app's alone — offered and pre-ticked.
    case exclusive
    /// Name evidence only — offered, unticked.
    case nameMatch
    /// Matches this app *and* other installed software. Never removable;
    /// shown read-only with the names of the apps that share it, because the
    /// worst mistake this feature can make is taking Office's group container
    /// down with Word.
    case shared([String])
    /// Not this app's. Not shown.
    case unrelated
}

// MARK: - Classifier

/// The matching brain, deliberately pure: strings in, verdict out, no
/// filesystem. Everything dangerous about uninstalling is decided here, which
/// is why this struct is compiled into the test bundle and exercised against
/// the scenarios that would hurt (Word-with-Office, Chrome-with-Drive,
/// foreign team containers).
struct SWPResidueClassifier {

    /// All lowercased/normalised by `make(for:others:)`.
    let bundleID: String
    let vendorPrefix: String
    let productToken: String
    let nameTokens: Set<String>
    let teamID: String?
    let otherVendorApps: [String: [String]]
    let otherTeamApps: [String: [String]]
    let otherNameTokens: Set<String>

    // MARK: Entry point

    func classify(_ rawName: String) -> SWPResidueKind {
        var name = rawName

        // Team-scoped names (Group Containers, Application Scripts).
        if let match = name.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) {
            let team = String(name[name.startIndex..<name.index(before: match.upperBound)])
            let remainder = String(name[match.upperBound...])

            guard let teamID else {
                // Unsigned target: claim a team container only when the
                // remainder is unmistakably this bundle id.
                let canonical = SWPMatch.canonicalName(remainder).name.lowercased()
                return isBundleScoped(canonical) ? .exclusive : .unrelated
            }
            guard team == teamID else { return .unrelated }   // another developer's data

            name = remainder
            if !SWPMatch.looksReverseDNS(SWPMatch.canonicalName(name).name) {
                // `UBF8T346G9.Office` — a team-wide container. Ours alone only
                // when no other installed app ships from the same team.
                if let apps = otherTeamApps[team], !apps.isEmpty { return .shared(apps) }
                let token = SWPMatch.normalise(SWPMatch.canonicalName(name).name)
                return (token == productToken || nameTokens.contains(token))
                    ? .exclusive : .nameMatch
            }
        }

        let canonical = SWPMatch.canonicalName(name).name.lowercased()
        return SWPMatch.looksReverseDNS(canonical)
            ? classifyReverseDNS(canonical)
            : classifyPlainName(canonical)
    }

    // MARK: Reverse-DNS

    private func isBundleScoped(_ identifier: String) -> Bool {
        identifier == bundleID || identifier.hasPrefix(bundleID + ".")
    }

    private func classifyReverseDNS(_ identifier: String) -> SWPResidueKind {
        if isBundleScoped(identifier) { return .exclusive }

        if !vendorPrefix.isEmpty,
           identifier == vendorPrefix || identifier.hasPrefix(vendorPrefix + ".") {
            // Same vendor, different product — AutoUpdate, shared frameworks.
            // Shared while any sibling app remains; a lone-app vendor's other
            // identifiers are plausibly this app's helpers, but only the user
            // can say, so they stay unticked.
            if let apps = otherVendorApps[vendorPrefix], !apps.isEmpty { return .shared(apps) }
            return .nameMatch
        }

        if let last = identifier.split(separator: ".").last {
            let token = SWPMatch.normalise(String(last))
            if token.count >= 3, !SWPMatch.genericWords.contains(token),
               token == productToken || nameTokens.contains(token) {
                return .nameMatch
            }
        }
        return .unrelated
    }

    // MARK: Plain names

    private func classifyPlainName(_ name: String) -> SWPResidueKind {
        let token = SWPMatch.normalise(name)
        guard token.count >= 3 else { return .unrelated }

        // Relevance to *this* app comes first. "Shared" means "this app's AND
        // someone else's" — without this gate, uninstalling Word listed every
        // installed browser's folder as shared, which is noise at best and
        // trains the user to ignore the one list that matters.
        let mineExact = nameTokens.contains(token)
        let mineByContainment = token.count >= 4 && nameTokens.contains {
            $0.count >= 4 && ($0.contains(token) || token.contains($0))
        }
        guard mineExact || mineByContainment else { return .unrelated }

        // Related to us — but if another installed app also answers to the
        // name, it stays put: "Google" survives Chrome's uninstall while
        // Drive is installed.
        if otherNameTokens.contains(token) || othersContain(token) {
            return .shared([])
        }
        return mineExact ? .exclusive : .nameMatch
    }

    private func othersContain(_ token: String) -> Bool {
        guard token.count >= 4 else { return otherNameTokens.contains(token) }
        return otherNameTokens.contains { other in
            other.count >= 4 && other != token
                && (other.contains(token) || token.contains(other))
        }
    }

    // MARK: Factory

    /// Builds a classifier for `app`, attributing shared data against every
    /// other installed application (system apps included — "does anything
    /// else answer to this name" must consider them too).
    static func make(for app: SWPInstalledApp,
                     others: [SWPInstalledApp],
                     teamID: String?) -> SWPResidueClassifier {
        let bid = app.bundleID
        let parts = bid.split(separator: ".").map(String.init)
        let vendorPrefix = parts.count >= 2 ? parts[0] + "." + parts[1] : ""
        let productToken = parts.last.map(SWPMatch.normalise) ?? ""

        var otherVendorApps: [String: [String]] = [:]
        var otherNameTokens: Set<String> = []
        for other in others where other.url != app.url {
            let otherParts = other.bundleID.split(separator: ".").map(String.init)
            if otherParts.count >= 2 {
                let prefix = otherParts[0] + "." + otherParts[1]
                otherVendorApps[prefix, default: []].append(other.name)
            }
            otherNameTokens.formUnion(SWPInstalledApps.nameTokens(of: other))
        }

        // Team attribution rides on vendor attribution: reading 400 code
        // signatures to map every team id would cost ~10 s per plan, and apps
        // sharing a bundle-id vendor overwhelmingly share a signing team. The
        // approximation errs toward `shared` — the safe direction.
        var otherTeamApps: [String: [String]] = [:]
        if let teamID, !vendorPrefix.isEmpty,
           let vendorSiblings = otherVendorApps[vendorPrefix] {
            otherTeamApps[teamID] = vendorSiblings
        }

        return SWPResidueClassifier(bundleID: bid,
                                    vendorPrefix: vendorPrefix,
                                    productToken: productToken,
                                    nameTokens: SWPInstalledApps.nameTokens(of: app),
                                    teamID: teamID,
                                    otherVendorApps: otherVendorApps,
                                    otherTeamApps: otherTeamApps,
                                    otherNameTokens: otherNameTokens)
    }
}

// MARK: - Plan

/// A shared entry, listed read-only so the user sees what was deliberately
/// left behind and why.
struct SWPSharedResidue: Identifiable {
    let url: URL
    let location: String
    let apps: [String]

    var id: String { url.path }
    var displayName: String { url.lastPathComponent }
    var sharedWithText: String {
        switch apps.count {
        case 0: return "shared with another installed app"
        case 1: return "shared with \(apps[0])"
        case 2: return "shared with \(apps[0]) and \(apps[1])"
        default: return "shared with \(apps[0]), \(apps[1]) and \(apps.count - 2) more"
        }
    }
}

struct SWPUninstallPlan {
    let app: SWPInstalledApp
    let appItem: SWPItem
    let exclusive: [SWPItem]
    let nameMatches: [SWPItem]
    let shared: [SWPSharedResidue]

    var defaultBytes: Int64 { appItem.sizeBytes + exclusive.reduce(0) { $0 + $1.sizeBytes } }
}

// MARK: - Finder

/// Walks the Library locations and applies the classifier.
struct SWPResidueFinder {

    let app: SWPInstalledApp

    private struct Location {
        let url: URL
        let label: String
        var filesOnly = false
    }

    private static var locations: [Location] {
        let library = URL(fileURLWithPath: NSHomeDirectory() + "/Library", isDirectory: true)
        func user(_ path: String, _ label: String, filesOnly: Bool = false) -> Location {
            Location(url: library.appendingPathComponent(path, isDirectory: true),
                     label: label, filesOnly: filesOnly)
        }
        func system(_ path: String, _ label: String, filesOnly: Bool = false) -> Location {
            Location(url: URL(fileURLWithPath: path, isDirectory: true),
                     label: label, filesOnly: filesOnly)
        }
        return [
            user("Application Support", "Application Support"),
            user("Caches", "Caches"),
            user("Preferences", "Preferences", filesOnly: true),
            user("Preferences/ByHost", "Preferences (ByHost)", filesOnly: true),
            user("Logs", "Logs"),
            user("Containers", "Containers"),
            user("Group Containers", "Group Containers"),
            user("Application Scripts", "App Scripts"),
            user("Saved Application State", "Saved State"),
            user("WebKit", "WebKit"),
            user("HTTPStorages", "HTTP Storage"),
            user("LaunchAgents", "Launch Agents", filesOnly: true),
            user("Internet Plug-Ins", "Internet Plug-Ins"),
            user("PreferencePanes", "Preference Panes"),
            system("/Library/Application Support", "Application Support (system)"),
            system("/Library/Caches", "Caches (system)"),
            system("/Library/Preferences", "Preferences (system)", filesOnly: true),
            system("/Library/Logs", "Logs (system)"),
            system("/Library/LaunchAgents", "Launch Agents (system)", filesOnly: true),
            system("/Library/LaunchDaemons", "Launch Daemons", filesOnly: true),
            system("/Library/PrivilegedHelperTools", "Helper Tools"),
            system("/Library/PreferencePanes", "Preference Panes (system)"),
            system("/Library/Internet Plug-Ins", "Internet Plug-Ins (system)"),
        ]
    }

    func buildPlan() -> SWPUninstallPlan {
        let classifier = SWPResidueClassifier.make(
            for: app,
            others: SWPInstalledApps.listForAttribution(),
            teamID: SWPInstalledApps.teamIdentifier(of: app.url))

        var exclusive: [(URL, String)] = []
        var nameMatches: [(URL, String)] = []
        var shared: [SWPSharedResidue] = []

        for location in Self.locations {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: location.url, includingPropertiesForKeys: [.isDirectoryKey], options: []
            )) ?? []

            for child in children {
                let rawName = child.lastPathComponent
                guard !rawName.hasPrefix(".") else { continue }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory) ?? false
                if location.filesOnly, isDirectory { continue }

                // UUID-named sandbox containers: judge the owner recorded in
                // the container metadata, never the meaningless folder name.
                var effectiveName = rawName
                if isDirectory, Self.looksLikeUUID(rawName) {
                    guard let resolved = Self.containerIdentifier(of: child) else { continue }
                    effectiveName = resolved
                }

                switch classifier.classify(effectiveName) {
                case .exclusive where SWPSafety.validate(child).isAllowed:
                    exclusive.append((child, location.label))
                case .nameMatch where SWPSafety.validate(child).isAllowed:
                    nameMatches.append((child, location.label))
                case .shared(let apps):
                    shared.append(SWPSharedResidue(url: child, location: location.label,
                                                   apps: apps))
                default:
                    break
                }
            }
        }

        // One parallel sizing pass over everything, the bundle included.
        let urls = [app.url] + exclusive.map(\.0) + nameMatches.map(\.0)
        let sizes = SWPDiskSize.sizes(of: urls)

        func item(_ url: URL, _ label: String, _ size: Int64) -> SWPItem {
            SWPItem(url: url, sizeBytes: size, modified: SWPDiskSize.modified(of: url),
                    location: label, requiresAdmin: SWPSafety.requiresAdmin(url))
        }

        let appItem = SWPItem(url: app.url, sizeBytes: sizes[0],
                              modified: SWPDiskSize.modified(of: app.url),
                              location: "Application", requiresAdmin: false)
        let exclusiveItems = exclusive.enumerated().map { index, entry in
            item(entry.0, entry.1, sizes[index + 1])
        }.sorted { $0.sizeBytes > $1.sizeBytes }
        let nameItems = nameMatches.enumerated().map { index, entry in
            item(entry.0, entry.1, sizes[index + 1 + exclusive.count])
        }.sorted { $0.sizeBytes > $1.sizeBytes }

        return SWPUninstallPlan(app: app, appItem: appItem, exclusive: exclusiveItems,
                                nameMatches: nameItems,
                                shared: shared.sorted { $0.displayName < $1.displayName })
    }

    // MARK: Containers

    private static func looksLikeUUID(_ name: String) -> Bool {
        name.count == 36
            && name.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil
    }

    private static func containerIdentifier(of url: URL) -> String? {
        let metadata = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: metadata),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }
}
