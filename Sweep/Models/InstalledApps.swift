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

    var id: String { url.path }
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
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = ((plist["CFBundleIdentifier"] as? String) ?? "").lowercased()
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String) ?? ""

        return SWPInstalledApp(url: url, name: name, bundleID: bundleID, version: version)
    }

    /// Extra name evidence for the classifier: executable name and the
    /// on-disk file name, which often differ from the display name.
    static func nameTokens(of app: SWPInstalledApp) -> Set<String> {
        var tokens: Set<String> = []
        var raw = [app.name, app.url.deletingPathExtension().lastPathComponent]
        let plistURL = app.url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] {
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
