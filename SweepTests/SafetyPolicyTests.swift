import XCTest

// MARK: - Safety policy

/// These are the tests that matter.
///
/// Sweep moves files the user cannot easily re-create, so the interesting
/// failure is not "a scan missed something" but "the policy allowed something
/// it must never allow". Every case below is a path that would represent real
/// damage if it ever came back `.allowed`.
final class SafetyPolicyTests: XCTestCase {

    private let home = NSHomeDirectory()

    // MARK: Refusals

    func testRefusesSystemLocations() {
        for path in ["/", "/System", "/System/Library", "/Applications", "/usr", "/bin",
                     "/etc", "/var", "/Library", "/Users", "/opt/homebrew"] {
            XCTAssertFalse(SWPSafety.validate(URL(fileURLWithPath: path)).isAllowed,
                           "must refuse \(path)")
        }
    }

    func testRefusesUserDocumentLocations() {
        for name in ["", "Documents", "Desktop", "Downloads", "Pictures", "Movies",
                     "Music", "Library", "Library/Keychains", "Library/Mail"] {
            let url = URL(fileURLWithPath: home).appendingPathComponent(name)
            XCTAssertFalse(SWPSafety.validate(url).isAllowed, "must refuse ~/\(name)")
        }
    }

    /// The off-by-one that would hurt most: deleting a whole allowed root
    /// rather than a child of it.
    func testRefusesAllowedRootsThemselves() {
        for root in SWPSafety.allowedRoots {
            XCTAssertFalse(SWPSafety.validate(root).isAllowed,
                           "must refuse the root \(root.path)")
        }
    }

    func testRefusesAppleOwnedNames() {
        let caches = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches")
        for name in ["com.apple.Safari", "com.apple.finder", "group.com.apple.notes"] {
            XCTAssertFalse(SWPSafety.validate(caches.appendingPathComponent(name)).isAllowed,
                           "must refuse \(name)")
        }
    }

    func testRefusesProtectedNamesInsideAllowedRoots() {
        let support = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support")
        for name in ["MobileSync", "AddressBook", "Knowledge", "CloudDocs", "FileProvider"] {
            XCTAssertFalse(SWPSafety.validate(support.appendingPathComponent(name)).isAllowed,
                           "must refuse \(name)")
        }
    }

    func testRefusesProtectedDescendantsWithinAllowedRoots() {
        let paths = [
            "\(home)/Library/Application Support/MobileSync/Backup/01234567",
            "\(home)/Library/Application Support/PACE/Licenses/third-party",
            "\(home)/Library/Containers/com.apple.Notes/Data/Library/example",
            "\(home)/Library/Caches/CloudKit/accounts/example",
            "\(home)/Library/Developer/CoreSimulator/Devices/01234567/data",
            "/Library/Application Support/Logic/Instruments/example",
            "/Library/Preferences/ByHost/com.example.setting.plist",
        ]
        for path in paths {
            XCTAssertFalse(SWPSafety.validate(URL(fileURLWithPath: path)).isAllowed,
                           "must refuse protected descendant \(path)")
        }
    }

    func testRefusesPathsOutsideEveryRoot() {
        for path in ["/tmp/whatever", "/private/var/db/receipts", "\(NSHomeDirectory())/Documents/notes.md"] {
            XCTAssertFalse(SWPSafety.validate(URL(fileURLWithPath: path)).isAllowed,
                           "must refuse \(path)")
        }
    }

    /// `~/Library/Caches/../../Documents` must not be laundered into an
    /// allowed path by standardisation.
    func testRefusesTraversalOutOfARoot() {
        let sneaky = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Caches/../../Documents/Taxes")
        XCTAssertFalse(SWPSafety.validate(sneaky).isAllowed)
    }

    // MARK: Regressions

    /// Every case here was produced by running the real scanner against this
    /// Mac and finding it in the results. They are the reason the deny-list
    /// exists, so they are pinned rather than left to be rediscovered.
    func testRefusesAppleFoldersWithOrdinaryNames() {
        let cases = [
            "/Library/Application Support/Logic",              // GarageBand's sound library
            "\(NSHomeDirectory())/Library/Caches/GeoServices",
            "\(NSHomeDirectory())/Library/Caches/CloudKit",
            "\(NSHomeDirectory())/Library/Caches/GameKit",
            "\(NSHomeDirectory())/Library/Preferences/MobileMeAccounts.plist",
            "\(NSHomeDirectory())/Library/Application Support/default.store",
            "\(NSHomeDirectory())/Library/Logs/iPad Updater Logs",
        ]
        for path in cases {
            XCTAssertFalse(SWPSafety.validate(URL(fileURLWithPath: path)).isAllowed,
                           "must refuse \(path)")
        }
    }

    /// Apple wraps its identifiers in several prefixes. This one reached the
    /// results list as "an orphan from a vendor called Com".
    func testRefusesAppleIdentifiersBehindAnyPrefix() {
        let preferences = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences")
        for name in ["systemgroup.com.apple.icloud.searchpartyd.sharedsettings.plist",
                     "group.com.apple.notes.plist",
                     "UBF8T346G9.com.apple.something.plist"] {
            XCTAssertFalse(SWPSafety.validate(preferences.appendingPathComponent(name)).isAllowed,
                           "must refuse \(name)")
        }
    }

    /// A UUID-named profile picture cache never compares equal to anything, so
    /// it needs the prefix rule rather than the exact-name list.
    func testRefusesUUIDSuffixedAppleArtefacts() {
        let url = URL(fileURLWithPath: home).appendingPathComponent(
            "Library/Caches/AAProfilePicture_584F4C43-C352-4F47-9E48-7433CBD38014.png")
        XCTAssertFalse(SWPSafety.validate(url).isAllowed)
    }

    /// Cross-app licensing and updater SDKs are shared dependencies: Paddle
    /// and FLEXnet hold paid licenses for whichever installed apps embed them,
    /// PACE holds audio-plugin authorisations. No inventory can prove nothing
    /// depends on them, so they must be refused wherever they appear.
    func testRefusesSharedLicensingAndRuntimeSDKs() {
        let userSupport = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support")
        let systemSupport = URL(fileURLWithPath: "/Library/Application Support")
        for name in ["Paddle", "FLEXnet Publisher", "PACE", "eSellerate",
                     "Setapp", "DevMate", "Mono", "Oracle"] {
            XCTAssertFalse(SWPSafety.validate(userSupport.appendingPathComponent(name)).isAllowed,
                           "must refuse ~/…/\(name)")
            XCTAssertFalse(SWPSafety.validate(systemSupport.appendingPathComponent(name)).isAllowed,
                           "must refuse /Library/…/\(name)")
        }
    }

    // MARK: Approvals

    func testAllowsOrdinaryLeftovers() {
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library")
        let allowed = [
            "Application Support/SomeDeletedApp",
            "Caches/com.example.tool",
            "Logs/SomeDeletedApp",
            "Containers/com.example.app",
            "HTTPStorages/com.example.app",
            "Preferences/com.example.app.plist",
            "Developer/Xcode/DerivedData/Project-abcdef",
            "Developer/Xcode/Archives/2026-09-22/Example.xcarchive",
            "Developer/CoreSimulator/Caches/example",
            "Developer/Xcode/UserData/Previews",
        ]
        for path in allowed {
            let url = library.appendingPathComponent(path)
            XCTAssertTrue(SWPSafety.validate(url).isAllowed, "must allow ~/Library/\(path)")
        }
    }

    func testAllowsSystemLibraryLeftoversButMarksThemAdmin() {
        let url = URL(fileURLWithPath: "/Library/Application Support/SomeDeletedApp")
        XCTAssertTrue(SWPSafety.validate(url).isAllowed)
        XCTAssertTrue(SWPSafety.requiresAdmin(url))
    }

    func testUserPathsDoNotRequireAdmin() {
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/com.example")
        XCTAssertFalse(SWPSafety.requiresAdmin(url))
    }

    // MARK: Symlinks

    private func cacheFixture() throws -> URL {
        let caches = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches")
        let fixture = caches.appendingPathComponent("swp-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: fixture) }
        return fixture
    }

    func testRefusesSymlinkEscapingAllowedRoots() throws {
        let fixture = try cacheFixture()
        let alias = fixture.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: URL(fileURLWithPath: home).appendingPathComponent("Documents"))

        XCTAssertFalse(SWPSafety.validate(alias).isAllowed)
        XCTAssertFalse(SWPSafety.validate(alias.appendingPathComponent("example")).isAllowed)
    }

    func testRefusesSymlinkToProtectedSubtreeAndItsChildren() throws {
        let fixture = try cacheFixture()
        let backup = fixture.appendingPathComponent("MobileSync/Backup")
        let child = backup.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let alias = fixture.appendingPathComponent("DerivedData")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backup)

        XCTAssertTrue(SWPSafety.validate(fixture.appendingPathComponent("ordinary-cache")).isAllowed)
        XCTAssertFalse(SWPSafety.validate(child).isAllowed)
        XCTAssertFalse(SWPSafety.validate(alias).isAllowed)
        XCTAssertFalse(SWPSafety.validate(alias.appendingPathComponent(child.lastPathComponent)).isAllowed)
    }

    func testRefusesLinkedAncestorsIntoAnotherAllowedRoot() throws {
        let fixture = try cacheFixture()
        let destination = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs")
        let alias = fixture.appendingPathComponent("other-cache")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        let childName = "swp-policy-missing-\(UUID().uuidString)"

        XCTAssertTrue(SWPSafety.validate(destination.appendingPathComponent(childName)).isAllowed)
        XCTAssertFalse(SWPSafety.validate(alias).isAllowed)
        XCTAssertFalse(SWPSafety.validate(alias.appendingPathComponent(childName)).isAllowed)
    }

    func testRefusesDanglingLinksAndTheirMissingDescendants() throws {
        let fixture = try cacheFixture()
        let alias = fixture.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: fixture.appendingPathComponent("missing"))

        XCTAssertFalse(SWPSafety.validate(alias).isAllowed)
        XCTAssertFalse(SWPSafety.validate(alias.appendingPathComponent("missing-child")).isAllowed)
    }

    func testAppBundleRefusesLinkedRootVendorAndLeaf() throws {
        let fixture = try cacheFixture()
        let applications = fixture.appendingPathComponent("Applications")
        let bundle = applications.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertTrue(SWPSafety.validateAppBundle(bundle, home: fixture).isAllowed)

        let alias = applications.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle)
        XCTAssertFalse(SWPSafety.validateAppBundle(alias, home: fixture).isAllowed)

        let vendor = applications.appendingPathComponent("Vendor")
        try FileManager.default.createSymbolicLink(at: vendor, withDestinationURL: applications)
        XCTAssertFalse(SWPSafety.validateAppBundle(
            vendor.appendingPathComponent("Example.app"), home: fixture).isAllowed)

        let otherHome = fixture.appendingPathComponent("other-home")
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: false)
        let linkedRoot = otherHome.appendingPathComponent("Applications")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: applications)
        XCTAssertFalse(SWPSafety.validateAppBundle(
            linkedRoot.appendingPathComponent("Example.app"), home: otherHome).isAllowed)
    }

    func testOwnedLocalAIAliasNeverAuthorizesLinkedCacheAncestors() throws {
        let fixture = try cacheFixture()
        let cache = fixture.appendingPathComponent("Library/Caches/Homebrew")
        let downloads = cache.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let downloadName = String(repeating: "a", count: 64) + "--ollama--0.34.2.arm64_tahoe.bottle.tar.gz"
        let download = downloads.appendingPathComponent(downloadName)
        try Data("fixture".utf8).write(to: download)
        let alias = cache.appendingPathComponent("ollama--0.34.2")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "downloads/" + downloadName)
        XCTAssertTrue(SWPSafety.validateLocalAI(alias, product: .ollama, home: fixture).isAllowed)
        XCTAssertFalse(SWPSafety.validateLocalAI(alias, product: .lmStudio, home: fixture).isAllowed)

        let otherHome = fixture.appendingPathComponent("other-home")
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: otherHome.appendingPathComponent("Library"),
            withDestinationURL: fixture.appendingPathComponent("Library"))
        XCTAssertFalse(SWPSafety.validateLocalAI(
            otherHome.appendingPathComponent("Library/Caches/Homebrew/ollama--0.34.2"),
            product: .ollama, home: otherHome).isAllowed)
    }
}
