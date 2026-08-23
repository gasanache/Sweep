import XCTest

// MARK: - App-bundle gate

/// `validateAppBundle` is the only rule that can approve removing an
/// application, so its geometry is pinned exhaustively.
final class AppBundleGateTests: XCTestCase {

    func testAllowsAppsInTheApplicationsFolders() {
        for path in ["/Applications/FakeThing.app",
                     "/Applications/Utilities/FakeTool.app",
                     "/Applications/Adobe Photoshop 2026/Adobe Photoshop.app",
                     NSHomeDirectory() + "/Applications/FakeThing.app",
                     // Browser-installed PWA wrappers live one folder down.
                     NSHomeDirectory() + "/Applications/Chrome Apps.localized/Outlook (PWA).app"] {
            XCTAssertTrue(SWPSafety.validateAppBundle(URL(fileURLWithPath: path)).isAllowed,
                          "must allow \(path)")
        }
    }

    func testRefusesSystemAndStrayLocations() {
        for path in ["/System/Applications/Mail.app",
                     "/System/Library/CoreServices/Finder.app",
                     "/Library/SomeVendor/Tool.app",
                     "/Applications/Too/Deep/Nested.app",
                     NSHomeDirectory() + "/Desktop/Dropped.app",
                     NSHomeDirectory() + "/Downloads/Installer.app"] {
            XCTAssertFalse(SWPSafety.validateAppBundle(URL(fileURLWithPath: path)).isAllowed,
                           "must refuse \(path)")
        }
    }

    func testRefusesNonBundles() {
        for path in ["/Applications", "/Applications/NotAnApp", "/Applications/file.txt"] {
            XCTAssertFalse(SWPSafety.validateAppBundle(URL(fileURLWithPath: path)).isAllowed,
                           "must refuse \(path)")
        }
    }

    /// The scan gate must keep refusing app bundles: uninstalling is opt-in
    /// through the dedicated gate, never something a scanner can propose.
    func testScanGateStillRefusesApplications() {
        XCTAssertFalse(SWPSafety.validate(URL(fileURLWithPath: "/Applications/FakeThing.app")).isAllowed)
    }
}

// MARK: - Residue classification

/// The matching brain, tested against the scenarios that would hurt. Every
/// case name describes a real-world mistake this feature must never make.
final class ResidueClassifierTests: XCTestCase {

    /// Word, with Excel and OneDrive still installed.
    private var word: SWPResidueClassifier {
        SWPResidueClassifier(
            bundleID: "com.microsoft.word",
            vendorPrefix: "com.microsoft",
            productToken: "word",
            nameTokens: ["microsoftword", "word"],
            teamID: "UBF8T346G9",
            otherVendorApps: ["com.microsoft": ["Microsoft Excel", "OneDrive"]],
            otherTeamApps: ["UBF8T346G9": ["Microsoft Excel", "OneDrive"]],
            otherNameTokens: ["microsoftexcel", "excel", "onedrive"])
    }

    func testOwnBundleFilesAreExclusive() {
        XCTAssertEqual(word.classify("com.microsoft.word"), .exclusive)
        XCTAssertEqual(word.classify("com.microsoft.word.plist"), .exclusive)
        XCTAssertEqual(word.classify("com.microsoft.word.savedState"), .exclusive)
        XCTAssertEqual(word.classify("com.microsoft.word.helper"), .exclusive)
        XCTAssertEqual(word.classify("UBF8T346G9.com.microsoft.word"), .exclusive)
    }

    /// The mistake AppCleaner-style tools make: vendor siblings' shared
    /// machinery must be recognised as shared while any sibling remains.
    func testVendorMachineryIsSharedWhileSiblingsRemain() {
        XCTAssertEqual(word.classify("com.microsoft.autoupdate2"),
                       .shared(["Microsoft Excel", "OneDrive"]))
        XCTAssertEqual(word.classify("com.microsoft.office.licensingV2"),
                       .shared(["Microsoft Excel", "OneDrive"]))
        XCTAssertEqual(word.classify("UBF8T346G9.Office"),
                       .shared(["Microsoft Excel", "OneDrive"]))
    }

    func testOtherVendorsAndTeamsAreUnrelated() {
        XCTAssertEqual(word.classify("com.google.chrome"), .unrelated)
        XCTAssertEqual(word.classify("EQHXZ8M8AV.com.google.drivefs"), .unrelated)
        XCTAssertEqual(word.classify("Krisp"), .unrelated)
    }

    /// Regression from the first ground-truth run: another installed app's
    /// folder must be *invisible* in this app's plan, not paraded as
    /// "shared". Shared means ours-and-theirs, never just theirs.
    func testUnrelatedAppsNeverAppearAsShared() {
        let wordWithBrave = SWPResidueClassifier(
            bundleID: "com.microsoft.word",
            vendorPrefix: "com.microsoft",
            productToken: "word",
            nameTokens: ["microsoftword", "word"],
            teamID: "UBF8T346G9",
            otherVendorApps: [:],
            otherTeamApps: [:],
            otherNameTokens: ["bravesoftware", "brave", "colorsync"])
        XCTAssertEqual(wordWithBrave.classify("BraveSoftware"), .unrelated)
        XCTAssertEqual(wordWithBrave.classify("ColorSync"), .unrelated)
    }

    /// A vendor's last app: no siblings left, so vendor machinery becomes a
    /// reviewable name match — offered, never pre-ticked.
    func testLoneVendorAppOffersVendorMachineryUnticked() {
        let krisp = SWPResidueClassifier(
            bundleID: "ai.krisp.krispmac",
            vendorPrefix: "ai.krisp",
            productToken: "krispmac",
            nameTokens: ["krisp", "krispmac"],
            teamID: "TEAMKRISP1",
            otherVendorApps: [:],
            otherTeamApps: [:],
            otherNameTokens: ["someotherapp"])
        XCTAssertEqual(krisp.classify("ai.krisp.krispmac"), .exclusive)
        XCTAssertEqual(krisp.classify("ai.krisp.updater"), .nameMatch)
        XCTAssertEqual(krisp.classify("Krisp"), .exclusive)
        // A team container that is neither the bundle id nor an exact app name
        // stays a reviewable match even for a lone-team app.
        XCTAssertEqual(krisp.classify("TEAMKRISP1.KrispShared"), .nameMatch)
    }

    /// Chrome going, Drive staying: the plain "Google" folder answers to both,
    /// so it must be shared — this is the exact case the user asked about.
    func testPlainVendorFolderSharedWhenAnotherAppAnswersToIt() {
        let chrome = SWPResidueClassifier(
            bundleID: "com.google.chrome",
            vendorPrefix: "com.google",
            productToken: "chrome",
            nameTokens: ["googlechrome", "chrome"],
            teamID: "EQHXZ8M8AV",
            otherVendorApps: ["com.google": ["Google Drive"]],
            otherTeamApps: ["EQHXZ8M8AV": ["Google Drive"]],
            otherNameTokens: ["googledrive"])
        XCTAssertEqual(chrome.classify("Google"), .shared([]))
        XCTAssertEqual(chrome.classify("com.google.drivefs"), .shared(["Google Drive"]))
        XCTAssertEqual(chrome.classify("com.google.chrome.helper"), .exclusive)
    }

    /// An unsigned target may only claim team containers by exact bundle id.
    /// Chrome's installed web apps are literally `com.google.Chrome.app.<hash>`
    /// and are separately installed apps that Sweep itself lists. Treating
    /// "starts with my bundle id" as proof of ownership classified them
    /// `.exclusive` — the one tier that is ticked without a click — handing the
    /// user a pre-ticked row containing another live app's entire data set.
    func testBundleScopedIdentifierOwnedByAnotherAppIsShared() {
        let chrome = SWPResidueClassifier(
            bundleID: "com.google.chrome",
            vendorPrefix: "com.google",
            productToken: "chrome",
            nameTokens: ["googlechrome", "chrome"],
            teamID: "EQHXZ8M8AV",
            otherVendorApps: [:],
            otherBundleIDs: ["com.google.chrome.app.abc": "Microsoft Teams",
                             "com.google.chrome.canary": "Chrome Canary"],
            otherTeamApps: [:],
            otherNameTokens: [])

        XCTAssertEqual(chrome.classify("com.google.chrome.app.abc"),
                       .shared(["Microsoft Teams"]),
                       "a PWA wrapper is a different installed app, not Chrome's data")
        XCTAssertEqual(chrome.classify("com.google.chrome.canary"),
                       .shared(["Chrome Canary"]))
        // Our own bundle and its helpers stay exclusive.
        XCTAssertEqual(chrome.classify("com.google.chrome"), .exclusive)
        XCTAssertEqual(chrome.classify("com.google.chrome.helper"), .exclusive)
    }

    func testUnsignedTargetClaimsOnlyExactTeamContainers() {
        let unsigned = SWPResidueClassifier(
            bundleID: "com.tiny.tool",
            vendorPrefix: "com.tiny",
            productToken: "tool",
            nameTokens: ["tinytool"],
            teamID: nil,
            otherVendorApps: [:],
            otherTeamApps: [:],
            otherNameTokens: [])
        XCTAssertEqual(unsigned.classify("ABCDEFGH12.com.tiny.tool"), .exclusive)
        XCTAssertEqual(unsigned.classify("ABCDEFGH12.SharedStuff"), .unrelated)
    }
}
