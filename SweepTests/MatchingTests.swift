import XCTest

// MARK: - Name canonicalisation

/// Regression tests written against the real false positives from the manual
/// audit that produced this app. Each case is a name that fooled an earlier
/// version of the matcher.
final class MatchingTests: XCTestCase {

    // MARK: canonicalName

    func testStripsPreferenceExtension() {
        XCTAssertEqual(SWPMatch.canonicalName("com.example.app.plist").name, "com.example.app")
    }

    /// ByHost preferences carry a hardware UUID that would otherwise make every
    /// one of them look like a unique unknown vendor.
    func testStripsByHostUUIDSuffix() {
        let raw = "com.example.app.9C4B1D2E-4F3A-4B8C-9E2D-1A2B3C4D5E6F.plist"
        XCTAssertEqual(SWPMatch.canonicalName(raw).name, "com.example.app")
    }

    func testStripsGroupPrefix() {
        XCTAssertEqual(SWPMatch.canonicalName("group.com.example.app").name, "com.example.app")
    }

    /// A known team id resolves to its vendor; an unknown one is stripped but
    /// flags the result as lower confidence, because we are then guessing.
    func testResolvesKnownTeamIDAndFlagsUnknownOnes() {
        let known = SWPMatch.canonicalName("UBF8T346G9.com.microsoft.oneauth")
        XCTAssertEqual(known.name, "com.microsoft.oneauth")
        XCTAssertFalse(known.teamIDStripped)

        let unknown = SWPMatch.canonicalName("ZZ1234ABCD.com.vendor.thing")
        XCTAssertEqual(unknown.name, "com.vendor.thing")
        XCTAssertTrue(unknown.teamIDStripped)
    }

    // MARK: looksReverseDNS

    func testRecognisesReverseDNSNames() {
        for name in ["com.example.app", "io.sentry", "org.m0k.transmission", "co.uk.thing"] {
            XCTAssertTrue(SWPMatch.looksReverseDNS(name), "\(name) should read as reverse-DNS")
        }
        for name in ["Krisp", "NetVision", "PremiumSoft CyberTech", "Logic"] {
            XCTAssertFalse(SWPMatch.looksReverseDNS(name), "\(name) should read as a plain name")
        }
    }

    func testNormaliseStripsPunctuationAndCase() {
        XCTAssertEqual(SWPMatch.normalise("PremiumSoft CyberTech"), "premiumsoftcybertech")
        XCTAssertEqual(SWPMatch.normalise("alt-tab-macos"), "alttabmacos")
    }

    // MARK: Toolchains

    /// A 4.9 GB Go build cache was reported as "leftovers of a deleted app"
    /// until these names were excluded from the inferential sweep.
    func testToolchainNamesAreRecognised() {
        for name in ["gobuild", "pip", "staticcheck", "msplaywright", "swiftpm",
                     "homebrew", "cocoapods", "nodegyp"] {
            XCTAssertTrue(SWPMatch.toolchainNames.contains(name),
                          "\(name) must be treated as a toolchain, not an app leftover")
        }
    }

    /// Copyright lines supply vendor names, but only after the boilerplate is
    /// stripped — otherwise every app contributes "rights" and "reserved".
    func testCorporateBoilerplateIsExcluded() {
        for word in ["copyright", "rights", "reserved", "inc", "ltd", "software"] {
            XCTAssertTrue(SWPMatch.corporateWords.contains(word),
                          "\(word) must not become a vendor word")
        }
        XCTAssertFalse(SWPMatch.corporateWords.contains("premiumsoft"),
                       "a real vendor name must survive the filter")
    }

    // MARK: Generic words

    /// Vendor matching must never key on these, or every app with a "Helper"
    /// would vouch for every other app's leftovers.
    func testGenericWordsAreExcludedFromMatching() {
        for word in ["helper", "updater", "agent", "installer", "service"] {
            XCTAssertTrue(SWPMatch.genericWords.contains(word), "\(word) must be generic")
        }
    }
}

// MARK: - Model behaviour

final class ScanModelTests: XCTestCase {

    private func makeItem(_ path: String, bytes: Int64) -> SWPItem {
        SWPItem(url: URL(fileURLWithPath: path), sizeBytes: bytes, modified: nil,
                location: "Caches", requiresAdmin: path.hasPrefix("/Library/"))
    }

    func testGroupSumsItsItems() {
        let group = SWPGroup(id: "g", name: "Test", category: .leftovers, confidence: .confirmed,
                             items: [makeItem("/tmp/a", bytes: 100),
                                     makeItem("/tmp/b", bytes: 250)])
        XCTAssertEqual(group.sizeBytes, 350)
        XCTAssertFalse(group.requiresAdmin)
    }

    func testGroupInheritsAdminFromAnyItem() {
        let group = SWPGroup(id: "g", name: "Test", category: .leftovers, confidence: .confirmed,
                             items: [makeItem("/tmp/a", bytes: 1),
                                     makeItem("/Library/Foo", bytes: 1)])
        XCTAssertTrue(group.requiresAdmin)
    }

    /// `.inUse` marks data whose owner is still installed. It must be a
    /// distinct tier with its own label and sort position — folding it into
    /// `.safe` was the bug this tier exists to prevent.
    func testInUseIsADistinctTier() {
        XCTAssertEqual(SWPConfidence.inUse.label, "In Use")
        XCTAssertNotEqual(SWPConfidence.inUse.sortRank, SWPConfidence.safe.sortRank)
        XCTAssertGreaterThan(SWPConfidence.inUse.sortRank, SWPConfidence.safe.sortRank,
                             "in-use data sorts below the freely-disposable tier")
    }

    /// The trust floor: a hand-built inventory with a couple of entries must
    /// read as unreliable, because a real Mac always carries dozens of
    /// bundled apps — a tiny index means the build failed, and an inventory
    /// that failed must never be allowed to call everything orphaned.
    func testTinyInventoryIsUntrustworthy() {
        let small = SWPAppInventory.fixture(bundleIDs: ["com.example.app"],
                                            nameTokens: ["exampleapp"])
        XCTAssertFalse(small.isTrustworthy)

        let sized = SWPAppInventory.fixture(
            bundleIDs: Set((0..<40).map { "com.example.app\($0)" }),
            appCount: 50)
        XCTAssertTrue(sized.isTrustworthy)
    }

    /// Ownership answers through the fixture: exact id, helper suffix, and a
    /// genuinely absent vendor.
    func testFixtureInventoryOwnership() {
        let inventory = SWPAppInventory.fixture(bundleIDs: ["com.example.app"],
                                                nameTokens: ["exampleapp"])
        XCTAssertTrue(inventory.owns("com.example.app"))
        XCTAssertTrue(inventory.owns("com.example.app.helper"),
                      "helpers share their app's two-component prefix")
        XCTAssertFalse(inventory.owns("com.vanished.tool"))
    }

    /// Hard evidence sorts above guesses, and bigger sorts above smaller.
    func testResultsSortByEvidenceThenSize() {
        var result = SWPScanResult()
        result.groups = [
            SWPGroup(id: "1", name: "likely-big", category: .leftovers, confidence: .likely,
                     items: [makeItem("/tmp/1", bytes: 900)]),
            SWPGroup(id: "2", name: "confirmed-small", category: .leftovers,
                     confidence: .confirmed, items: [makeItem("/tmp/2", bytes: 10)]),
            SWPGroup(id: "3", name: "confirmed-big", category: .leftovers,
                     confidence: .confirmed, items: [makeItem("/tmp/3", bytes: 500)]),
        ]
        XCTAssertEqual(result.groups(in: .leftovers).map(\.name),
                       ["confirmed-big", "confirmed-small", "likely-big"])
    }

    func testByteFormattingSplitsValueFromUnit() {
        let split = SWPBytes.split(5_368_709_120)
        XCTAssertFalse(split.value.isEmpty)
        XCTAssertEqual(split.unit, "GB")
    }

    /// `ByteCountFormatter` separates number and unit with a non-breaking
    /// space in many locales; the splitter must treat that as whitespace or
    /// every non-English Mac renders the unit inside the 46 pt number.
    func testSplitHandlesNonBreakingSpace() {
        let split = SWPBytes.splitFormatted("1,2\u{00A0}Go")
        XCTAssertEqual(split.value, "1,2")
        XCTAssertEqual(split.unit, "Go")
    }

    /// The nesting guard before removal: a selected child of a selected parent
    /// is dropped (the parent's trashing takes it along), while a sibling that
    /// merely shares a string prefix survives — the classic `/tmp/a` vs
    /// `/tmp/ab` trap.
    func testPruneDropsNestedSelectionsButKeepsPrefixSiblings() {
        let parent = makeItem("/tmp/a", bytes: 1)
        let child = makeItem("/tmp/a/b/c", bytes: 1)
        let prefixSibling = makeItem("/tmp/ab", bytes: 1)
        let pruned = SWPRemovalService.prunedOfDescendants([child, parent, prefixSibling])
        XCTAssertEqual(Set(pruned.map(\.id)), ["/tmp/a", "/tmp/ab"])
    }

    /// Same plist name in LaunchAgents and LaunchDaemons must land in the
    /// quarantine under two distinct names — `mv -f` would otherwise let the
    /// second overwrite the first, destroying a file promised recoverable.
    func testQuarantineNamesNeverCollide() {
        let items = [makeItem("/Library/LaunchAgents/com.foo.svc.plist", bytes: 1),
                     makeItem("/Library/LaunchDaemons/com.foo.svc.plist", bytes: 1),
                     makeItem("/Library/PrivilegedHelperTools/com.foo.svc", bytes: 1),
                     makeItem("/Library/Application Support/com.foo.svc", bytes: 1)]
        let names = SWPRemovalService.quarantineNames(for: items)
        XCTAssertEqual(names.count, Set(names.map { $0.lowercased() }).count,
                       "all quarantine names must be unique")
        XCTAssertEqual(names[0], "com.foo.svc.plist")
        XCTAssertEqual(names[1], "com.foo.svc 2.plist")
        XCTAssertEqual(names[2], "com.foo.svc")
        XCTAssertEqual(names[3], "com.foo 2.svc")
    }
}
