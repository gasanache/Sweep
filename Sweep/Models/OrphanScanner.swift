import Foundation
import os

// MARK: - Orphan scanner

/// Finds files left behind by apps that are no longer installed.
///
/// The sweep itself is a shallow directory listing of the places macOS lets
/// apps write to. All of the difficulty is in `SWPAppInventory.owns(_:)` and in
/// `resolveContainerIdentifier(_:)` below.
struct SWPOrphanScanner {

    private static let log = Logger(subsystem: "com.gasanache.sweep", category: "orphans")

    private let inventory: SWPAppInventory
    private let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    init(inventory: SWPAppInventory) {
        self.inventory = inventory
    }

    // MARK: Sweep locations

    /// Where to look, and what to call it in the UI.
    ///
    /// `filesOnly` covers `Preferences`, where directories are Apple's own
    /// machinery (`ByHost`) rather than app leftovers.
    private struct Location {
        let url: URL
        let label: String
        var filesOnly: Bool = false
        var directoriesOnly: Bool = false
    }

    private var locations: [Location] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        func user(_ path: String, _ label: String, filesOnly: Bool = false,
                  directoriesOnly: Bool = false) -> Location {
            Location(url: library.appendingPathComponent(path, isDirectory: true),
                     label: label, filesOnly: filesOnly, directoriesOnly: directoriesOnly)
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
            user("Containers", "Containers", directoriesOnly: true),
            user("Group Containers", "Group Containers", directoriesOnly: true),
            user("Application Scripts", "App Scripts", directoriesOnly: true),
            user("Saved Application State", "Saved State", directoriesOnly: true),
            user("WebKit", "WebKit"),
            user("HTTPStorages", "HTTP Storage"),
            user("Internet Plug-Ins", "Internet Plug-Ins"),
            user("PreferencePanes", "Preference Panes"),
            system("/Library/Application Support", "Application Support (system)"),
            system("/Library/Caches", "Caches (system)"),
            system("/Library/Logs", "Logs (system)"),
            system("/Library/Preferences", "Preferences (system)", filesOnly: true),
            system("/Library/PrivilegedHelperTools", "Helper Tools"),
            system("/Library/PreferencePanes", "Preference Panes (system)"),
            system("/Library/Internet Plug-Ins", "Internet Plug-Ins (system)"),
        ]
    }

    // MARK: Scanning

    /// One candidate before grouping.
    private struct Candidate {
        let url: URL
        let owner: String
        let label: String
        let confidence: SWPConfidence
        /// The owner identifier this candidate was judged under. For a
        /// UUID-named sandbox container that is the resolved
        /// `MCMMetadataIdentifier`, not the meaningless folder name — which is
        /// what the row should be titled with.
        let resolvedName: String
        /// A loose file rather than a folder, matched on name alone. These are
        /// the least app-like findings — `aws_credentials_cache.json` is not
        /// anyone's leftover app data — so they are gathered separately rather
        /// than presented as if an app owned them.
        let isStrayFile: Bool
    }

    func scan(unreadable: inout [String], ignored: Set<String> = [],
              progress: (String) -> Void) -> [SWPGroup] {
        // An unreliable inventory would make every third-party file on the
        // disk read as orphaned. Fail closed: no inferences at all, and the
        // engine surfaces why the category came back empty.
        guard inventory.isTrustworthy else {
            Self.log.error("inventory below trust floor — leftovers scan skipped")
            return []
        }

        var candidates: [Candidate] = []

        for location in locations {
            if Task.isCancelled { return [] }
            progress(location.label)
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: location.url, includingPropertiesForKeys: keys, options: []
            ) else {
                if FileManager.default.fileExists(atPath: location.url.path) {
                    unreadable.append(location.url.path)
                }
                continue
            }

            for child in children {
                if ignored.contains(child.standardizedFileURL.path) { continue }
                guard let candidate = evaluate(child, in: location) else { continue }
                candidates.append(candidate)
            }
        }

        return group(candidates)
    }

    /// Decides whether one directory entry is a leftover.
    private func evaluate(_ url: URL, in location: Location) -> Candidate? {
        let rawName = url.lastPathComponent
        guard !rawName.hasPrefix(".") else { return nil }

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if location.filesOnly, isDirectory { return nil }
        if location.directoriesOnly, !isDirectory { return nil }
        if location.filesOnly, url.pathExtension != "plist" { return nil }

        // A sandboxed app's container is named by UUID, not by bundle id. The
        // real owner is recorded in the container's own metadata plist — read it
        // before concluding anything, because without this step every sandboxed
        // app with a UUID container reads as orphaned.
        var name = rawName
        var uuidResolved = false
        if isDirectory, looksLikeUUID(rawName),
           let identifier = resolveContainerIdentifier(url) {
            name = identifier
            uuidResolved = true
        }

        let canonical = SWPMatch.canonicalName(name)
        if inventory.owns(canonical.name) { return nil }

        // Toolchain and infrastructure directories are not app leftovers even
        // when no `.app` claims them. Skipping here lets the Developer and
        // Caches sweeps pick them up with an accurate label instead.
        let normalised = SWPMatch.normalise(canonical.name)
        if SWPMatch.toolchainNames.contains(normalised) { return nil }
        if let last = canonical.name.split(separator: ".").last,
           SWPMatch.toolchainNames.contains(SWPMatch.normalise(String(last))) { return nil }

        // A UUID container whose metadata we could not read is unknowable, not
        // orphaned. Reporting these caused the worst near-miss of the audit.
        if isDirectory, looksLikeUUID(rawName), !uuidResolved { return nil }

        guard SWPSafety.validate(url).isAllowed else { return nil }

        let isReverseDNS = SWPMatch.looksReverseDNS(canonical.name)
        let confidence: SWPConfidence = (isReverseDNS && !canonical.teamIDStripped)
            ? .confirmed : .likely

        let isStray = !isDirectory && !isReverseDNS
        return Candidate(url: url,
                         owner: isStray ? "__stray__"
                                        : ownerKey(for: canonical.name, isReverseDNS: isReverseDNS),
                         label: location.label,
                         confidence: isStray ? .likely : confidence,
                         resolvedName: canonical.name,
                         isStrayFile: isStray)
    }

    /// `MCMMetadataIdentifier` from a container's hidden metadata plist.
    private func resolveContainerIdentifier(_ url: URL) -> String? {
        let metadata = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: metadata),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    private func looksLikeUUID(_ name: String) -> Bool {
        name.count == 36 && name.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil
    }

    // MARK: Grouping

    /// Groups by vendor so one app's seven scattered folders read as one row.
    private func ownerKey(for name: String, isReverseDNS: Bool) -> String {
        guard isReverseDNS else { return SWPMatch.normalise(name) }
        let parts = name.lowercased().split(separator: ".").map(String.init)
        return parts.count >= 2 ? parts[1] : (parts.first ?? name.lowercased())
    }

    /// Owner groups of Review tier smaller than this are folded into one
    /// summary row.
    ///
    /// A 4 KB name-only guess and a 2.9 GB confirmed orphan were rendering as
    /// equals, and on this Mac the long tail of 4 KB rows buried everything
    /// worth looking at. Folding is presentation only — the items stay
    /// individually listed inside the group and remain selectable.
    private static var smallGroupThreshold: Int64 { SWPSettings.foldThresholdBytes }

    private func group(_ candidates: [Candidate]) -> [SWPGroup] {
        guard !candidates.isEmpty else { return [] }

        // One parallel sizing pass for every candidate. Sizing each item inside
        // the grouping loop was serial and dominated the leftovers scan.
        let sizes = SWPDiskSize.sizes(of: candidates.map(\.url))
        var itemByPath: [String: SWPItem] = [:]
        for (index, candidate) in candidates.enumerated() {
            itemByPath[candidate.url.path] = SWPItem(
                url: candidate.url,
                sizeBytes: sizes[index],
                modified: SWPDiskSize.modified(of: candidate.url),
                location: candidate.label,
                requiresAdmin: SWPSafety.requiresAdmin(candidate.url))
        }

        var buckets: [String: [Candidate]] = [:]
        for candidate in candidates {
            buckets[candidate.owner, default: []].append(candidate)
        }

        var groups: [SWPGroup] = []
        var strayItems: [SWPItem] = []
        var smallItems: [SWPItem] = []
        var smallOwners = 0

        for (key, bucket) in buckets {
            let items = bucket.compactMap { itemByPath[$0.url.path] }
            guard !items.isEmpty else { continue }

            if key == "__stray__" {
                strayItems = items
                continue
            }

            // A group is only as trustworthy as its weakest member: if any path
            // in it was a name-only guess, the whole row needs review.
            let confidence: SWPConfidence = bucket.contains { $0.confidence == .likely }
                ? .likely : .confirmed
            let total = items.reduce(0) { $0 + $1.sizeBytes }

            if confidence == .likely, Self.smallGroupThreshold > 0,
               total < Self.smallGroupThreshold {
                smallItems += items
                smallOwners += 1
                continue
            }

            groups.append(SWPGroup(id: "leftovers.\(key)",
                                   name: displayName(for: bucket),
                                   category: .leftovers,
                                   confidence: confidence,
                                   items: items))
        }

        if !smallItems.isEmpty {
            groups.append(SWPGroup(id: "leftovers.__small__",
                                   name: "Small leftovers · \(smallOwners) apps",
                                   category: .leftovers,
                                   confidence: .likely,
                                   items: smallItems.sorted { $0.sizeBytes > $1.sizeBytes }))
        }
        if !strayItems.isEmpty {
            groups.append(SWPGroup(id: "leftovers.__stray__",
                                   name: "Stray files",
                                   category: .leftovers,
                                   confidence: .likely,
                                   items: strayItems.sorted { $0.sizeBytes > $1.sizeBytes }))
        }
        return groups
    }

    /// Vendor tokens whose title-cased form reads wrong.
    ///
    /// `Operasoftware` and `Bravesoftware` were the ones that looked broken in
    /// the list; the rest are here so the common cases render the way their
    /// owners spell them.
    private static let vendorNames: [String: String] = [
        "operasoftware": "Opera Software", "bravesoftware": "Brave Software",
        "macpaw": "MacPaw", "microsoft": "Microsoft", "google": "Google",
        "jetbrains": "JetBrains", "libreoffice": "LibreOffice", "vmware": "VMware",
        "crystalidea": "CrystalIdea", "paragon-software": "Paragon Software",
        "premiumsoft": "PremiumSoft", "qtproject": "Qt Project", "openai": "OpenAI",
        "github": "GitHub", "gitlab": "GitLab", "youtube": "YouTube",
        "vandyke": "VanDyke", "teamviewer": "TeamViewer", "anydesk": "AnyDesk",
        "protonmail": "Proton Mail", "protonvpn": "Proton VPN", "isaacmarovitz": "Whisky",
    ]

    /// Prefers a human-readable name over a reverse-DNS one for the row title.
    ///
    /// Three rules, each from a row that looked wrong on this Mac: keep the
    /// folder's own casing when there is a plain name (`NetVision`, not
    /// `netvision`); map known vendors (`Operasoftware` → `Opera Software`);
    /// and never render a token shorter than three characters as a name —
    /// `lu` and `Kts` were meaningless, so those fall back to the full
    /// identifier, which at least tells the user what they are looking at.
    private func displayName(for bucket: [Candidate]) -> String {
        // `resolvedName` rather than the file name: a UUID container's row was
        // titled with the UUID, throwing away the owner we had already
        // resolved from its metadata.
        let names = bucket.map(\.resolvedName)
        let plain = names.filter { !SWPMatch.looksReverseDNS($0) }
        if let best = plain.max(by: { $0.count < $1.count }), best.count >= 3 {
            return best
        }

        if let first = names.first {
            let parts = first.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                let vendor = parts[1]
                if let mapped = Self.vendorNames[vendor.lowercased()] { return mapped }
                if vendor.count >= 3 { return vendor.capitalized }
            }
            // Nothing usable — show the identifier itself rather than a
            // two-letter fragment of it.
            return first
        }
        return "Unknown"
    }

}
