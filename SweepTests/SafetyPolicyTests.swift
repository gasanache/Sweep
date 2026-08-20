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

    /// A link inside an allowed root pointing at `~/Documents` must be refused,
    /// so that trashing it can never be read as touching the target.
    func testRefusesSymlinkEscapingAllowedRoots() throws {
        let caches = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches")
        let link = caches.appendingPathComponent("swp-test-escape-\(UUID().uuidString)")
        let target = URL(fileURLWithPath: home).appendingPathComponent("Documents")
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw XCTSkip("no ~/Documents on this machine")
        }

        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }

        XCTAssertFalse(SWPSafety.validate(link).isAllowed)
    }
}
