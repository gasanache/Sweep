import Foundation
import Security

// MARK: - Installed app

/// One application the uninstaller can act on.
///
/// Identity is the bundle path: two copies of the same app are two distinct
/// rows, which is what the user sees in Finder too.
struct SWPInstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    /// Lowercased. Empty when the bundle has no Info.plist identifier — such
    /// an app can still be uninstalled, matched by name alone.
    let bundleID: String
    let version: String
    /// Spotlight's last-used date. `nil` when Spotlight has no record — which
    /// is itself informative for a never-opened app, so it is rendered as
    /// "never used", not hidden.
    var lastUsed: Date?
    /// The bundle ships a system extension (network filter, DriverKit driver,
    /// endpoint security). Removing the app does not unload it — only the app
    /// itself can, so the uninstaller says so rather than silently leaving a
    /// running extension behind.
    var hasSystemExtension: Bool = false

    var id: String { url.path }

    var lastUsedText: String {
        guard let lastUsed else { return "never used" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "used " + formatter.localizedString(for: lastUsed, relativeTo: Date())
    }
}

// MARK: - Lister

/// Enumerates uninstallable applications and reads their identities.
///
/// Deliberately AppKit-free (Foundation + Security only) so it compiles into
/// the test bundle and the headless verification harness. Icons and
/// running-state, which need AppKit, live in the store and views.
enum SWPInstalledApps {

    /// Everything the uninstaller may list.
    ///
    /// `/System/Applications` is intentionally absent: those apps cannot be
    /// removed and listing them would only manufacture refusals. Safari and
    /// Sweep itself are excluded here *and* refused by
    /// `SWPSafety.validateAppBundle` — the list filter is courtesy, the gate
    /// is the guarantee.
    static func list() -> [SWPInstalledApp] {
        var apps: [SWPInstalledApp] = []
        var seen = Set<String>()

        for root in uninstallRoots {
            // Depth 1 — the root plus exactly one subfolder — mirrors what
            // `validateAppBundle` accepts, so the list can never show an app
            // the gate would later refuse.
            for url in appBundles(under: root, depth: 1) {
                let standard = url.standardizedFileURL.path
                guard !seen.contains(standard) else { continue }
                seen.insert(standard)
                guard let app = info(at: url) else { continue }
                if app.bundleID == "com.apple.safari" { continue }
                if app.bundleID == Bundle.main.bundleIdentifier?.lowercased() { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The wider inventory used for shared-data attribution: same roots plus
    /// the system applications, because "does anything else answer to this
    /// name" should consider Apple's apps too.
    static func listForAttribution() -> [SWPInstalledApp] {
        var apps = list()
        for url in appBundles(under: URL(fileURLWithPath: "/System/Applications"), depth: 1) {
            if let app = info(at: url) { apps.append(app) }
        }
        return apps
    }

    private static let uninstallRoots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true),
    ]

    private static func appBundles(under root: URL, depth: Int) -> [URL] {
        guard depth >= 0 else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var found: [URL] = []
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            if child.pathExtension == "app" {
                found.append(child)
            } else {
                found += appBundles(under: child, depth: depth - 1)
            }
        }
        return found
    }

    /// Reads one bundle's identity from its Info.plist.
    static func info(at url: URL) -> SWPInstalledApp? {
        guard let plist = infoPlist(in: url) else { return nil }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = ((plist["CFBundleIdentifier"] as? String) ?? "").lowercased()
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String) ?? ""

        let extensionsDirectory = url.appendingPathComponent("Contents/Library/SystemExtensions")
        let hasExtension = FileManager.default.fileExists(atPath: extensionsDirectory.path)

        return SWPInstalledApp(url: url, name: name, bundleID: bundleID, version: version,
                               lastUsed: lastUsedDate(of: url),
                               hasSystemExtension: hasExtension)
    }

    /// An app bundle's Info.plist, including iOS apps run on Apple silicon.
    ///
    /// Those are shipped as `Foo.app/Wrapper/Foo.app/Info.plist` with nothing
    /// at `Contents/Info.plist`, so reading only the macOS layout returned nil
    /// — contributing no bundle id and no name tokens, which let a live app's
    /// container be reported as a confirmed orphan.
    static func infoPlist(in bundle: URL) -> [String: Any]? {
        var candidates = [bundle.appendingPathComponent("Contents/Info.plist")]
        let wrapper = bundle.appendingPathComponent("Wrapper")
        if let wrapped = try? FileManager.default.contentsOfDirectory(
            at: wrapper, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for inner in wrapped where inner.pathExtension == "app" {
                candidates.append(inner.appendingPathComponent("Info.plist"))
            }
        }
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any] else { continue }
            return plist
        }
        return nil
    }

    /// `kMDItemLastUsedDate` via Spotlight.
    ///
    /// `NSMetadataItem` rather than shelling out to `mdls`: one in-process
    /// lookup per app, no subprocess for a list that can run to hundreds.
    private static func lastUsedDate(of url: URL) -> Date? {
        guard let item = NSMetadataItem(url: url) else { return nil }
        return item.value(forAttribute: "kMDItemLastUsedDate") as? Date
    }

    /// Extra name evidence for the classifier: executable name and the
    /// on-disk file name, which often differ from the display name.
    static func nameTokens(of app: SWPInstalledApp) -> Set<String> {
        var tokens: Set<String> = []
        var raw = [app.name, app.url.deletingPathExtension().lastPathComponent]
        if let plist = infoPlist(in: app.url) {
            for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let value = plist[key] as? String { raw.append(value) }
            }
        }
        for value in raw {
            let token = SWPMatch.normalise(value)
            if token.count >= 3, !SWPMatch.genericWords.contains(token) {
                tokens.insert(token)
            }
        }
        return tokens
    }

    // MARK: Code signature

    /// The signing team identifier, read from the static code signature.
    ///
    /// The Security framework rather than shelling out to `codesign`: one
    /// in-process call, no parsing, and it works identically in the headless
    /// harness. `nil` for unsigned or ad-hoc-signed bundles, which the
    /// classifier treats as "cannot claim team-prefixed containers except by
    /// exact bundle id".
    static func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
