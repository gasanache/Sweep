import XCTest
import Darwin

/// Exercises production workflows using isolated files and injected operations.
final class WorkflowRegressionTests: XCTestCase {
    private func fixture() throws -> URL {
        let physical = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
        defer { free(physical) }
        let url = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("SweepWorkflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func item(_ url: URL, bytes: Int64 = 1) -> SWPItem {
        SWPItem(url: url, sizeBytes: bytes, modified: nil, location: "Fixture", requiresAdmin: false)
    }

    private func app(_ url: URL) -> SWPInstalledApp {
        SWPInstalledApp(url: url, name: "Audit Fixture", bundleID: "test.sweep.audit." + UUID().uuidString.lowercased(),
                        version: "1", lastUsed: nil)
    }

    private func plan(_ app: SWPInstalledApp, residues: [SWPItem] = []) -> SWPUninstallPlan {
        SWPUninstallPlan(app: app, appItem: item(app.url), exclusive: residues, nameMatches: [], shared: [])
    }

    func testUnsignedTargetRespectsOtherOwnersInsideTeamContainers() {
        let classifier = SWPResidueClassifier(bundleID: "com.audit.product", vendorPrefix: "com.audit",
            productToken: "product", nameTokens: ["product"], teamID: nil, otherVendorApps: [:],
            otherBundleIDs: ["com.audit.product": "Another copy", "com.audit.product.webapp": "Web app"],
            otherTeamApps: [:], otherNameTokens: [])
        for prefix in ["", "ABCDEFGHIJ."] {
            XCTAssertEqual(classifier.classify(prefix + "com.audit.product"), .shared(["Another copy"]))
            XCTAssertEqual(classifier.classify(prefix + "com.audit.product.webapp"), .shared(["Web app"]))
        }
    }

    func testGenericGateReservesLocalAIObjectsDescendantsAndAggregateParents() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for product in SWPLocalAIProduct.allCases {
            for url in SWPLocalAIScanner.homeTargets(for: product, home: home) {
                XCTAssertFalse(SWPSafety.validate(url).isAllowed, url.path)
                XCTAssertFalse(SWPSafety.validate(url.appendingPathComponent("nested/payload")).isAllowed, url.path)
            }
        }
        let cache = home.appendingPathComponent("Library/Caches/Homebrew")
        for relative in ["", "downloads", "Cask", "ollama--1.2.3", "ollama--1.2.3/nested",
                         "downloads/" + String(repeating: "a", count: 64) + "--ollama-1.2.3.tar.gz"] {
            XCTAssertTrue(SWPSafety.requiresLocalAIReview(cache.appendingPathComponent(relative)), relative)
        }
        XCTAssertFalse(SWPSafety.requiresLocalAIReview(cache.appendingPathComponent("downloads/" + String(repeating: "b", count: 64) + "--wget-1.2.tar.gz")))
        XCTAssertFalse(SWPSafety.requiresLocalAIReview(home.appendingPathComponent("Library/Caches/unrelated")))
        for relative in ["Library/Application Support/lm studio/models", "Library/Caches/AI.ELEMENTLABS.LMSTUDIO", "Library/Caches/homebrew/downloads"] {
            XCTAssertFalse(SWPSafety.validate(home.appendingPathComponent(relative)).isAllowed, relative)
        }
    }

    func testIncompleteInventoryNeverPromotesUnknownDisposableGroupsToSafe() {
        let inventory = SWPAppInventory.fixture(bundleIDs: ["com.audit.installed"])
        XCTAssertFalse(inventory.isTrustworthy)
        let scanner = SWPJunkScanner(inventory: inventory, claimed: [])
        let unknown = URL(fileURLWithPath: "/fixture/com.unowned.unknown")
        XCTAssertEqual(scanner.ownership(of: unknown), .likely)
        let groups = scanner.disposableGroups([
            item(unknown), item(URL(fileURLWithPath: "/fixture/org.unowned.large"), bytes: 100_000_000),
            item(URL(fileURLWithPath: "/fixture/com.audit.installed"))
        ], category: .caches, summaryName: "Caches")
        XCTAssertFalse(groups.contains { $0.confidence == .safe })
        XCTAssertEqual(groups.filter { $0.confidence == .likely }.count, 2)
        XCTAssertEqual(groups.filter { $0.confidence == .inUse }.count, 1)
    }

    func testInventoryCommandDeadlineKillsATermIgnoringChild() {
        let started = ProcessInfo.processInfo.systemUptime
        let result = SWPAppInventory.command("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.03)
        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.failure)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testInheritedOutputHandleDoesNotHoldTheCallerUntilEOF() {
        let started = ProcessInfo.processInfo.systemUptime
        let result = SWPAppInventory.command("/bin/sh", ["-c", "/bin/sleep 3 & printf done; exit 0"], timeout: 0.2)
        XCTAssertTrue(result.succeeded, result.failure ?? result.output)
        XCTAssertEqual(result.output, "done")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testFailedOrExcessiveInventoryOutputIsNotPositiveEvidence() {
        XCTAssertEqual(SWPAppInventory.shell("/bin/sh", ["-c", "printf misleading; exit 1"]), "")
        let result = SWPAppInventory.command("/bin/sh", ["-c", "while :; do printf 0123456789; done"], maximumOutput: 32)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.output.utf8.count, 32)
    }

    private func moveScript(_ root: URL, beforeMove: String = "") throws -> String {
        let source = root.appendingPathComponent("source")
        let identity = try SWPRemovalService.fileIdentity(source)
        let quotedRoot = "'" + root.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd -P " + quotedRoot + " &&\n"
            + SWPRemovalService.commandPrelude + "\n"
            + SWPRemovalService.moveCommand(source: "./source", destination: "./payload", identity: identity,
                index: 0, manifestRow: "payload\t" + source.path + "\t" + identity, beforeMove: beforeMove)
    }

    func testPrivilegedMovePrimitiveRefusesManifestFailureBeforeMoving() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("source")
        try Data("recover me".utf8).write(to: source)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(SWPRemovalService.manifestName), withIntermediateDirectories: false)
        let result = SWPAppInventory.command("/bin/sh", ["-c", try moveScript(root)])
        XCTAssertTrue(result.output.contains("SWPFAIL:0"), result.output)
        XCTAssertEqual(try Data(contentsOf: source), Data("recover me".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("payload").path))
    }

    func testPrivilegedMoveIntentExistsBeforeMutationAndFailedMoveIsNotRestorable() throws {
        let root = try fixture()
        try Data("recover me".utf8).write(to: root.appendingPathComponent("source"))
        let manifest = root.appendingPathComponent(SWPRemovalService.manifestName)
        try Data("# audit\n".utf8).write(to: manifest)
        // A before-move hook may fail after the intent write. The intent must
        // already exist, but must not create a restore entry without its inode.
        let result = SWPAppInventory.command("/bin/sh", ["-c", try moveScript(root,
            beforeMove: "/usr/bin/grep -q '^payload' ./sweep-manifest.tsv && echo INTENT_PRESENT; false")])
        XCTAssertTrue(result.output.contains("INTENT_PRESENT"), result.output)
        XCTAssertTrue(result.output.contains("SWPFAIL:0"))
        XCTAssertTrue(SWPRemovalService.entries(in: root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("source").path))
    }

    func testAdministratorStartupPrimitiveVerifiesUnloadBeforeMovingConfiguration() throws {
        for bootoutFails in [false, true] {
            let root = try fixture()
            try Data("configuration".utf8).write(to: root.appendingPathComponent("source"))
            try Data("# audit\n".utf8).write(to: root.appendingPathComponent(SWPRemovalService.manifestName))
            try Data().write(to: root.appendingPathComponent("registered"))
            let source = root.appendingPathComponent("source").path
            let helper = root.appendingPathComponent("fixture-launchctl")
            try Data("""
            #!/bin/sh
            case "$1" in
                print) [ -f ./registered ] || exit 113; printf '\\tpath = %s\\n' '\(source)' ;;
                bootout) \(bootoutFails ? "exit 1" : "/bin/rm ./registered") ;;
                *) exit 1 ;;
            esac
            """.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let script = try moveScript(root, beforeMove: "swp_stop_job 'gui/\(getuid())/com.audit.fixture' '\(source)'")
                .replacingOccurrences(of: "/bin/launchctl", with: "./fixture-launchctl")
            let result = SWPAppInventory.command("/bin/sh", ["-c", script])
            XCTAssertTrue(result.output.contains(bootoutFails ? "SWPFAIL:0" : "SWPOK:0"), result.output)
            XCTAssertEqual(FileManager.default.fileExists(atPath: source), bootoutFails)
            XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("registered").path), bootoutFails)
        }
    }

    private func startupPlist(_ home: URL, label: String = "com.audit.actual-label") throws -> URL {
        let url = home.appendingPathComponent("Library/LaunchAgents/not-the-label.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/fixture/not-executed"], format: .xml, options: 0).write(to: url)
        return url
    }

    func testStartupIdentityUsesLabelAndCorrectDomain() throws {
        let home = try fixture()
        let plist = try startupPlist(home)
        XCTAssertEqual(try SWPRemovalService.startupTarget(for: plist, home: home), "gui/\(getuid())/com.audit.actual-label")
        XCTAssertEqual(SWPRemovalService.startupDomain(for: URL(fileURLWithPath: "/Library/LaunchAgents/test.plist")), "gui/\(getuid())")
        XCTAssertEqual(SWPRemovalService.startupDomain(for: URL(fileURLWithPath: "/Library/LaunchDaemons/test.plist")), "system")
        _ = try startupPlist(home, label: "com.apple.protected")
        XCTAssertThrowsError(try SWPRemovalService.startupTarget(for: plist, home: home))
    }

    func testStartupStopRequiresVerifiedRegistrationAndVerifiedAbsence() throws {
        let home = try fixture()
        let plist = try startupPlist(home)
        let command = CommandSequence([
            .init(status: 0, output: "\tpath = \(plist.path)\n"), .init(status: 0), .init(status: 113)
        ])
        let service = SWPRemovalService(startupCommand: { command.next($1) })
        try service.stopStartupJob(at: plist, home: home)
        XCTAssertEqual(command.calls, [["print", "gui/\(getuid())/com.audit.actual-label"],
                                     ["bootout", "gui/\(getuid())/com.audit.actual-label"],
                                     ["print", "gui/\(getuid())/com.audit.actual-label"]])
    }

    func testStartupStopRefusesWrongRegistrationBootoutFailureAndRespawn() throws {
        let home = try fixture()
        let plist = try startupPlist(home)
        for results: [SWPAppInventory.CommandResult] in [
            [.init(status: 0, output: "path = /unrelated.plist")],
            [.init(status: 0, output: "path = \(plist.path)"), .init(status: 1, output: "denied")],
            [.init(status: 0, output: "path = \(plist.path)"), .init(status: 0), .init(status: 0, output: "restarted")]
        ] {
            let command = CommandSequence(results)
            let service = SWPRemovalService(startupCommand: { command.next($1) })
            XCTAssertThrowsError(try service.stopStartupJob(at: plist, home: home))
            XCTAssertEqual(command.calls.count, results.count)
            XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("State did not arrive before deadline", file: file, line: line)
    }

    @MainActor
    func testRescanKeepsResultsVisibleAndStaleCallbacksCannotUnlockRemoval() async throws {
        let group = SWPGroup(id: "fixture", name: "Fixture", category: .caches, confidence: .safe,
                             items: [item(try fixture().appendingPathComponent("missing"))])
        let driver = ScanDriver(group: group)
        let removal = BlockingWork()
        defer { removal.release.signal() }
        let engine = SWPScanEngine(scanWork: { _, _, _, progress, stage in
            await driver.run(progress: progress, stage: stage)
        }, removeItems: { _ in removal.run(); return SWPRemovalOutcome() })
        engine.scan()
        await eventually { engine.lastScanDate != nil }
        XCTAssertEqual(engine.phase, .results)
        engine.selectedGroupIDs = [group.id]
        engine.scan()
        await driver.waitForRescan()
        await Task.yield()
        XCTAssertEqual(engine.phase, .results)
        XCTAssertTrue(engine.isRescanning)
        XCTAssertEqual(engine.result.groups, [group])
        engine.confirmRemoval()
        engine.performRemoval()
        await eventually { removal.didEnter }
        XCTAssertTrue(engine.isMutating)
        engine.cancelScan()
        engine.showResults()
        engine.scan()
        await driver.releaseRescan()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.completedStages, [.inventory])
        XCTAssertEqual(engine.phase, .removing)
        XCTAssertTrue(engine.isRemoving)
        XCTAssertTrue(engine.isMutating)
        removal.release.signal()
        await eventually { !engine.isRemoving }
        XCTAssertEqual(engine.phase, .results)
    }

    @MainActor
    func testEmptyRescanRetainsOldRowsUntilCompletionThenClearsThem() async throws {
        let group = SWPGroup(id: "fixture", name: "Fixture", category: .caches, confidence: .safe,
                             items: [item(try fixture().appendingPathComponent("missing"))])
        let driver = ScanDriver(group: group, emptyRescan: true)
        let engine = SWPScanEngine(scanWork: { _, _, _, progress, stage in
            await driver.run(progress: progress, stage: stage)
        })
        engine.scan()
        await eventually { engine.lastScanDate != nil }
        engine.scan()
        await driver.waitForRescan()
        XCTAssertEqual(engine.result.groups, [group])
        XCTAssertEqual(engine.phase, .results)
        XCTAssertTrue(engine.isRescanning)
        await driver.releaseRescan()
        await eventually { !engine.isRescanning }
        XCTAssertTrue(engine.result.groups.isEmpty)
        XCTAssertEqual(engine.phase, .results)
    }

    @MainActor
    func testCancellingPlanBuildClearsBusyAndOldWorkerCannotReplaceNewPlan() async throws {
        let root = try fixture()
        let oldApp = app(root.appendingPathComponent("old.app"))
        let newApp = app(root.appendingPathComponent("new.app"))
        let oldPlan = plan(oldApp), newPlan = plan(newApp)
        let work = BlockingWork()
        defer { work.release.signal() }
        let store = SWPUninstallStore(buildPlan: { app in
            if app.id == oldApp.id { work.run(); return oldPlan }
            return newPlan
        })
        store.select(oldApp)
        await eventually { work.didEnter }
        store.clearPlan()
        XCTAssertFalse(store.isBuildingPlan)
        store.select(newApp)
        await eventually { !store.isBuildingPlan }
        XCTAssertEqual(store.plan?.app.id, newApp.id)
        work.release.signal()
        await eventually { work.didReturn }
        await Task.yield()
        XCTAssertEqual(store.plan?.app.id, newApp.id)
        XCTAssertFalse(store.isBuildingPlan)
    }

    @MainActor
    func testRemovedBundleDoesNotHideRefusedResidue() async throws {
        let root = try fixture()
        let residue = root.appendingPathComponent("residue")
        try FileManager.default.createSymbolicLink(atPath: residue.path, withDestinationPath: "missing-target")
        let reviewed = plan(app(root.appendingPathComponent("already-moved.app")), residues: [item(residue)])
        let store = SWPUninstallStore(buildPlan: { _ in reviewed }, removePlan: { _, _ in
            var result = SWPRemovalOutcome()
            result.trashedCount = 1
            result.refusedByPolicy = [residue.path]
            return result
        })
        store.select(reviewed.app)
        await eventually { !store.isBuildingPlan }
        store.performUninstall()
        await eventually { !store.isUninstalling }
        XCTAssertEqual(store.lastOutcome?.refusedByPolicy, [residue.path])
        XCTAssertTrue(store.statusMessage?.contains(residue.path) == true)
        XCTAssertTrue(store.plan?.bundleAlreadyTrashed == true)
        XCTAssertEqual(store.plan?.exclusive.map(\.id), [residue.path])
    }

    @MainActor
    func testCancelledAuthorizationReportsEarlierMovesRatherThanNothingRemoved() async throws {
        let root = try fixture()
        let application = app(root.appendingPathComponent("still-installed.app"))
        try FileManager.default.createDirectory(at: application.url, withIntermediateDirectories: false)
        let reviewed = plan(application)
        let store = SWPUninstallStore(buildPlan: { _ in reviewed }, removePlan: { _, _ in
            var result = SWPRemovalOutcome(); result.trashedCount = 1; result.adminCancelled = true
            return result
        })
        store.select(application)
        await eventually { !store.isBuildingPlan }
        store.performUninstall()
        await eventually { !store.isUninstalling }
        XCTAssertTrue(store.statusMessage?.contains("Moved 1 item") == true)
        XCTAssertTrue(store.statusMessage?.contains("cancelled") == true)
        XCTAssertFalse(store.statusMessage?.contains("nothing was removed") == true)
        XCTAssertNotNil(store.plan)
    }

    @MainActor
    func testTrashWatcherSurvivesImmediateStopStart() async throws {
        let root = try fixture()
        let watcher = SWPTrashWatcher(trashURL: root)
        defer { watcher.stop() }
        for _ in 0..<20 { watcher.start(); watcher.stop() }
        watcher.start()
        await Task.yield() // let old cancellation handlers run before new writes
        let application = root.appendingPathComponent("Audit-" + UUID().uuidString + ".app")
        let contents = application.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let identifier = "test.sweep.watcher." + UUID().uuidString.lowercased()
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
            "CFBundleName": "Audit Fixture"], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: root.appendingPathComponent("event"))
        await eventually { watcher.pending?.app.bundleID == identifier }
        XCTAssertTrue(watcher.isWatching)
    }
}

final class PresentationRegressionTests: XCTestCase {
    @MainActor
    func testNavigationHasExactlyOneActiveDestination() {
        let engine = SWPScanEngine()
        engine.destination = .cleanup(.developer)
        XCTAssertTrue(engine.destination.isCleanup)
        XCTAssertEqual(engine.selectedCategory, .developer)
        for destination in SWPDestination.tools {
            engine.destination = destination
            XCTAssertFalse(engine.destination.isCleanup)
            XCTAssertEqual(engine.destination, destination)
        }
    }

    func testCleanerDatesDescribeModificationNotUsage() {
        let item = SWPItem(url: URL(fileURLWithPath: "/fixture/data"), sizeBytes: 1,
                           modified: Date(), location: "Fixture", requiresAdmin: false)
        let group = SWPGroup(id: "fixture", name: "Fixture", category: .caches, confidence: .safe, items: [item])
        XCTAssertTrue(group.subtitle.contains("modified"))
        XCTAssertFalse(group.subtitle.contains("used"))
    }

    @MainActor
    func testUninstallerRefreshReplacesInventoryAndClearsMissingSelection() async {
        let first = SWPInstalledApp(url: URL(fileURLWithPath: "/fixture/First.app"), name: "First", bundleID: "test.first", version: "1", lastUsed: nil)
        let second = SWPInstalledApp(url: URL(fileURLWithPath: "/fixture/Second.app"), name: "Second", bundleID: "test.second", version: "1", lastUsed: nil)
        let sequence = AppListSequence([[first], [second]])
        let store = SWPUninstallStore(loadApps: { sequence.next() }, measureApps: { apps in
            Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Int64(42)) })
        })
        store.loadAppsIfNeeded()
        for _ in 0..<400 where store.isLoadingApps || store.isMeasuringSizes { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.apps.map(\.id), [first.id])
        store.selectedAppID = first.id
        store.refreshApps()
        for _ in 0..<400 where store.isLoadingApps || store.isMeasuringSizes { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.apps.map(\.id), [second.id])
        XCTAssertNil(store.selectedAppID)
        XCTAssertEqual(store.size(of: second), 42)
        store.query = "nothing-matches"
        XCTAssertTrue(store.filteredApps.isEmpty)
        store.query = ""
        XCTAssertEqual(store.filteredApps.count, 1)
    }

    @MainActor
    func testLocalAIDiscoveryNotesAreDeduplicatedWithoutLosingEmptyProductNotes() async {
        let plans = SWPLocalAIProduct.allCases.map { product in
            SWPLocalAIPlan(product: product, items: [], appURLs: [], brewExecutable: nil,
                           hasBrewPackage: false, shellProfiles: [], blockers: [],
                           notes: ["Shared discovery issue", product.name + " coverage"])
        }
        let store = SWPLocalAIStore(load: { plans }, loadInventory: { _ in SWPAIInventory() })
        store.showsCleanup = true
        await store.refresh()
        XCTAssertTrue(store.visiblePlans.isEmpty)
        XCTAssertEqual(store.discoveryNotes.count, 3)
        XCTAssertEqual(store.discoveryNotes.filter { $0 == "Shared discovery issue" }.count, 1)
    }
}

private final class AppListSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[SWPInstalledApp]]
    init(_ lists: [[SWPInstalledApp]]) { self.lists = lists }
    func next() -> [SWPInstalledApp] { lock.withLock { lists.isEmpty ? [] : lists.removeFirst() } }
}

private final class CommandSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SWPAppInventory.CommandResult]
    private var recorded: [[String]] = []
    init(_ results: [SWPAppInventory.CommandResult]) { self.results = results }
    var calls: [[String]] { lock.withLock { recorded } }
    func next(_ args: [String]) -> SWPAppInventory.CommandResult {
        lock.withLock {
            recorded.append(args)
            return results.isEmpty ? .init(status: 1, output: "unexpected command") : results.removeFirst()
        }
    }
}

private final class BlockingWork: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false, returned = false
    var didEnter: Bool { lock.withLock { entered } }
    var didReturn: Bool { lock.withLock { returned } }
    func run() {
        lock.withLock { entered = true }
        _ = release.wait(timeout: .now() + 10)
        lock.withLock { returned = true }
    }
}

private actor ScanDriver {
    let group: SWPGroup
    let emptyRescan: Bool
    private var count = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var rescanReturned = false
    init(group: SWPGroup, emptyRescan: Bool = false) { self.group = group; self.emptyRescan = emptyRescan }
    func run(progress: @escaping SWPScanEngine.ProgressHandler, stage: @escaping SWPScanEngine.StageHandler) async {
        count += 1
        if count > 1 {
            progress("Rescanning")
            await stage(.inventory, [], SWPScanResult())
            await withCheckedContinuation { parked = $0 }
        }
        progress("Late progress")
        await stage(.leftovers, count > 1 && emptyRescan ? [] : [group], SWPScanResult())
        if count > 1 { rescanReturned = true }
    }
    func waitForRescan() async {
        for _ in 0..<600 {
            if parked != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func releaseRescan() async {
        parked?.resume(); parked = nil
        for _ in 0..<600 {
            if rescanReturned { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
