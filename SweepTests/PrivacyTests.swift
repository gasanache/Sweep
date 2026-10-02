import XCTest
import SQLite3

final class PrivacyTests: XCTestCase {
    private func app(_ identifier: String, id: String? = nil, canReset: Bool = true) -> SWPPrivacyApp {
        SWPPrivacyApp(id: id ?? identifier, name: "Fixture", bundleID: identifier,
                      paths: [], grants: [], canReset: canReset)
    }

    func testInvalidAppScopeNeverBecomesAllApps() {
        for identifier in ["", " ", "-All", "com.example;id", "com.example\napp",
                           "com.example'App", "$(whoami)", "com..example", "com.example\0App"] {
            XCTAssertThrowsError(try SWPPrivacyBackend.resetArguments(service: .all, app: app(identifier)))
            XCTAssertThrowsError(try SWPPrivacyBackend.administratorScript(service: .all, app: app(identifier)))
        }
        XCTAssertThrowsError(try SWPPrivacyBackend.resetArguments(
            service: .camera, app: app("com.example.App", id: "com.example.Other")))
        XCTAssertThrowsError(try SWPPrivacyBackend.resetArguments(
            service: .camera, app: app("com.example.App", canReset: false)))
    }

    func testCaseSensitiveBundleScopeAndExplicitAllApps() throws {
        XCTAssertEqual(try SWPPrivacyBackend.resetArguments(service: .camera, app: app("com.Example.App")),
                       ["reset", "Camera", "com.Example.App"])
        XCTAssertEqual(try SWPPrivacyBackend.resetArguments(service: .all, app: nil), ["reset", "All"])
        let pathClient = SWPPrivacyApp(id: "/usr/local/bin/tool", name: "tool", bundleID: nil,
                                      paths: ["/usr/local/bin/tool"], grants: [], canReset: false)
        XCTAssertThrowsError(try SWPPrivacyBackend.resetArguments(service: .all, app: pathClient))
    }

    func testReadOnlyMissingDatabaseDoesNotCreateAnything() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = SWPPrivacyBackend.readDatabase(at: folder.appendingPathComponent("TCC.db"), source: .user)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.coverage.isEmpty, "Missing data must have an explicit coverage failure")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testDatabaseReadPreservesBytesAndDoesNotCreateSidecars() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("TCC # fixture?.db")
        try makeDatabase(at: url, sql: """
            CREATE TABLE access (client TEXT, client_type INTEGER, service TEXT, auth_value INTEGER, policy_id INTEGER);
            INSERT INTO access VALUES ('com.Example.App', 0, 'kTCCServiceCamera', 2, NULL);
            INSERT INTO access VALUES ('/usr/local/bin/tool', 1, 'kTCCServiceMicrophone', 0, NULL);
            INSERT INTO access VALUES ('com.Example.Unknown', 99, 'kTCCServiceFuture', 42, 4);
            """)
        let before = try Data(contentsOf: url)
        let result = SWPPrivacyBackend.readDatabase(at: url, source: .system)
        XCTAssertEqual(result.entries.map(\.client), ["com.Example.App", "/usr/local/bin/tool", "com.Example.Unknown"])
        XCTAssertEqual(result.entries.map(\.clientType), [.bundleID, .absolutePath, .unknown(99)])
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [url.lastPathComponent])
        let apps = SWPPrivacyBackend.mergeInventory(bundleURLs: [], entries: result.entries)
        XCTAssertTrue(try XCTUnwrap(apps.first { $0.id == "com.Example.App" }).canReset)
        XCTAssertFalse(try XCTUnwrap(apps.first { $0.id == "/usr/local/bin/tool" }).canReset)
        XCTAssertFalse(try XCTUnwrap(apps.first { $0.name == "com.Example.Unknown" }).canReset)
    }

    func testMalformedAuthorizationIsUnknownNotCoercedToDenied() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("TCC.db")
        try makeDatabase(at: url, sql: """
            CREATE TABLE access (client TEXT, client_type, service TEXT, auth_value);
            INSERT INTO access VALUES ('com.example.App', 0, 'kTCCServiceCamera', 'not-an-integer');
            INSERT INTO access VALUES ('com.example.Other', '0', 'kTCCServiceCamera', NULL);
            """)
        let result = SWPPrivacyBackend.readDatabase(at: url, source: .user)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[1].clientType, .unknown(nil))
        for entry in result.entries {
            XCTAssertTrue(entry.grant.status.localizedCaseInsensitiveContains("unknown"))
            XCTAssertFalse(entry.grant.status.localizedCaseInsensitiveContains("denied"))
        }
    }

    func testUnsupportedSchemaDoesNotInventPermissionState() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("TCC.db")
        try makeDatabase(at: url, sql: "CREATE TABLE access (client TEXT, service TEXT);")
        let result = SWPPrivacyBackend.readDatabase(at: url, source: .user)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.coverage.isEmpty)
    }

    func testInventoryMergesCopiesWithoutLosingCaseOrPathClients() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try makeApp(at: folder.appendingPathComponent("First.app"), identifier: "com.Example.App")
        let second = try makeApp(at: folder.appendingPathComponent("Second.app"), identifier: "com.Example.App")
        let third = try makeApp(at: folder.appendingPathComponent("Lowercase.app"), identifier: "com.example.app")
        let grant = SWPPrivacyGrant(id: "user-1", serviceName: "Camera", status: "Recorded allowed")
        let entries = [SWPPrivacyRecordedEntry(client: "com.Example.App", clientType: .bundleID, grant: grant),
                       SWPPrivacyRecordedEntry(client: "com.Example.App", clientType: .unknown(7), grant: grant)]
        let apps = SWPPrivacyBackend.mergeInventory(bundleURLs: [first, first, second, third], entries: entries)
        let upper = try XCTUnwrap(apps.first { $0.id == "com.Example.App" })
        XCTAssertEqual(Set(upper.paths), Set([first.path, second.path]))
        XCTAssertEqual(upper.grants, [grant])
        XCTAssertTrue(upper.isInstalled)
        XCTAssertTrue(apps.contains { $0.id == "com.example.app" && $0.grants.isEmpty })
        let unknown = try XCTUnwrap(apps.first { !$0.canReset })
        XCTAssertNil(unknown.bundleID)
        XCTAssertFalse(unknown.isInstalled)
    }

    func testChosenApplicationRejectsNonBundlesAndMissingIdentifiers() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try SWPPrivacyBackend.chosenApp(at: folder))
        let missing = try makeApp(at: folder.appendingPathComponent("Missing.app"), identifier: "")
        XCTAssertThrowsError(try SWPPrivacyBackend.chosenApp(at: missing))
        let valid = try makeApp(at: folder.appendingPathComponent("Valid.app"), identifier: "com.Example.Valid")
        let chosen = try SWPPrivacyBackend.chosenApp(at: valid)
        XCTAssertEqual(chosen.bundleID, "com.Example.Valid")
        XCTAssertEqual(chosen.paths, [valid.path])
    }

    func testLegacyAllowedValueIsNotInterpretedAsModernUnknown() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("TCC.db")
        try makeDatabase(at: url, sql: """
            CREATE TABLE access (client TEXT, client_type INTEGER, service TEXT, allowed INTEGER);
            INSERT INTO access VALUES ('com.example.App', 0, 'kTCCServiceCamera', 1);
            """)
        let record = try XCTUnwrap(SWPPrivacyBackend.readDatabase(at: url, source: .user).entries.first)
        XCTAssertTrue(record.grant.status.localizedCaseInsensitiveContains("allowed"))
        XCTAssertFalse(record.grant.status.localizedCaseInsensitiveContains("unknown"))
    }

    @MainActor
    func testOverlappingResetsAreSerializedAndCannotBroadenScope() async {
        let gate = PrivacyOperationGate()
        let store = SWPPrivacyStore(
            loadSnapshot: { _ in SWPPrivacySnapshot(apps: [], coverage: []) },
            performReset: { _, _, _ in await gate.suspend(); return SWPPrivacyOutcome(status: .completed, summary: "Operation finished") })
        let target = app("com.Example.App")
        let first = Task { await store.reset(service: .camera, app: target, scope: .currentUser) }
        await gate.waitForStart()
        XCTAssertTrue(store.isResetting)
        await store.reset(service: .all, app: nil, scope: .allUsers)
        await store.refresh()
        XCTAssertFalse(store.isLoading)
        let invocations = await gate.count
        XCTAssertEqual(invocations, 1, "The second, broader reset must never reach the executor")
        await gate.release()
        await first.value
        XCTAssertFalse(store.isResetting)
    }

    @MainActor
    func testLatePreResetInventoryCannotReplacePostResetSnapshot() async {
        let gate = PrivacyOperationGate()
        let oldApp = app("com.example.Old")
        let newApp = app("com.example.New")
        let store = SWPPrivacyStore(
            loadSnapshot: { _ in
                if await gate.claimFirst() {
                    await gate.suspend()
                    return SWPPrivacySnapshot(apps: [oldApp], coverage: ["before"])
                }
                return SWPPrivacySnapshot(apps: [newApp], coverage: ["after"])
            },
            performReset: { _, _, _ in SWPPrivacyOutcome(status: .completed, summary: "Operation finished") })
        let staleRefresh = Task { await store.refresh() }
        await gate.waitForStart()
        await store.reset(service: .camera, app: newApp, scope: .currentUser)
        let outcome = store.result
        await gate.release()
        await staleRefresh.value
        XCTAssertEqual(store.apps.map(\.id), [newApp.id])
        XCTAssertEqual(store.coverage, ["after"])
        XCTAssertEqual(store.result, outcome)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testInvalidTargetDoesNotInvokeResetExecutor() async {
        let gate = PrivacyOperationGate()
        let store = SWPPrivacyStore(
            loadSnapshot: { _ in SWPPrivacySnapshot(apps: [], coverage: []) },
            performReset: { _, _, _ in await gate.record(); return SWPPrivacyOutcome(status: .failed, summary: "Should not run") })
        await store.reset(service: .all, app: app(""), scope: .allUsers)
        let invocations = await gate.count
        XCTAssertEqual(invocations, 0)
        XCTAssertNotNil(store.result)
        XCTAssertFalse(store.isResetting)
    }

    func testStructuredEvidencePreservesSourceTargetsAndUnknowns() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("TCC.db")
        try makeDatabase(at: url, sql: """
            CREATE TABLE access (client TEXT, client_type INTEGER, service TEXT, auth_value INTEGER, indirect_object_identifier TEXT);
            INSERT INTO access VALUES ('com.example.App', 0, 'kTCCServiceCamera', 2, NULL);
            INSERT INTO access VALUES ('com.example.App', 0, 'kTCCServiceCamera', 0, NULL);
            INSERT INTO access VALUES ('com.example.App', 0, 'kTCCServiceAppleEvents', 2, 'com.example.Target');
            INSERT INTO access VALUES ('com.example.App', 0, 'kTCCServiceCalendarWriteOnly', 3, NULL);
            INSERT INTO access VALUES ('com.example.App', 0, 'kTCCServiceFuture', 88, NULL);
            """)
        let snapshot = SWPPrivacyBackend.readDatabase(at: url, source: .system)
        XCTAssertTrue(snapshot.isReadable)
        XCTAssertEqual(snapshot.entries[0].grant.source, .system)
        XCTAssertEqual(snapshot.entries[0].grant.decision, .allowed)
        XCTAssertEqual(snapshot.entries[1].grant.decision, .denied)
        XCTAssertEqual(snapshot.entries[2].grant.service, .appleEvents)
        XCTAssertTrue(snapshot.entries[2].grant.serviceName.contains("com.example.Target"))
        XCTAssertEqual(snapshot.entries[3].grant.service, .calendar)
        XCTAssertEqual(snapshot.entries[3].grant.decision, .limited)
        XCTAssertNil(snapshot.entries[4].grant.service)
        XCTAssertEqual(snapshot.entries[4].grant.decision, .unknown)
        let merged = try XCTUnwrap(SWPPrivacyBackend.mergeInventory(bundleURLs: [], entries: snapshot.entries).first)
        XCTAssertEqual(merged.recordedSummary(for: .camera), "Mixed recorded decisions")
        XCTAssertEqual(merged.recordedSummary(for: .microphone), "No readable record")
        XCTAssertEqual(merged.records(for: .camera).count, 2)
    }

    @MainActor
    func testBrowserContextSurvivesRefreshAndSelectionReconciles() async {
        let target = app("com.example.Target")
        let gate = PrivacyOperationGate()
        let store = SWPPrivacyStore(loadSnapshot: { _ in
            let first = await gate.claimFirst()
            return SWPPrivacySnapshot(apps: first ? [target] : [], coverage: [])
        })
        await store.refresh()
        store.query = "Target"
        store.selectedAppID = target.id
        store.showsAllCategories = true
        XCTAssertEqual(store.filteredApps.map(\.id), [target.id])
        XCTAssertEqual(store.selectedApp?.id, target.id)
        store.inspect(target)
        XCTAssertEqual(store.inspectedApp?.id, target.id)
        // The context belongs to the surviving store, not a disposable view.
        XCTAssertTrue(store.hasLoaded)
        await store.refresh()
        XCTAssertNil(store.selectedAppID, "A disappeared app must not remain an actionable target")
        XCTAssertNil(store.inspectedAppID)
        XCTAssertEqual(store.query, "Target")
        XCTAssertTrue(store.showsAllCategories)
    }

    @MainActor
    func testInspectAndBackPreserveFullListContext() async {
        let target = app("com.example.Target")
        let store = SWPPrivacyStore(loadSnapshot: { _ in SWPPrivacySnapshot(apps: [target], coverage: []) })
        await store.refresh()
        store.query = "Target"
        store.appScope = .recordedOnly
        store.selectedAppID = target.id
        XCTAssertNil(store.inspectedApp, "Selecting a table row must not replace the full list")
        store.inspect(target)
        XCTAssertEqual(store.inspectedApp?.id, target.id)
        await store.refresh()
        XCTAssertEqual(store.inspectedApp?.id, target.id)
        store.showApps()
        XCTAssertNil(store.inspectedApp)
        XCTAssertEqual(store.selectedAppID, target.id)
        XCTAssertEqual(store.query, "Target")
        XCTAssertEqual(store.appScope, .recordedOnly)
        store.inspect(app("com.example.Missing"))
        XCTAssertNil(store.inspectedApp)
    }

    @MainActor
    func testSearchPreservesExplicitAppFilters() async {
        var apple = app("com.apple.Fixture")
        apple.isInstalled = true
        let helper = app("com.example.Helper")
        let snapshot = SWPPrivacySnapshot(apps: [apple, helper], coverage: [], readableSources: [.user])
        let store = SWPPrivacyStore(loadSnapshot: { _ in snapshot })
        await store.refresh()
        store.query = "com.apple"
        XCTAssertTrue(store.filteredApps.isEmpty, "Search must not silently override Apple-app exclusion")
        store.showAppleApps = true
        XCTAssertEqual(store.filteredApps.map(\.id), [apple.id])
        store.selectedAppID = apple.id
        store.appScope = .recordedOnly
        XCTAssertNil(store.selectedAppID)
        store.query = ""
        XCTAssertEqual(store.filteredApps.map(\.id), [helper.id])
        XCTAssertEqual(store.coverageSummary, "Records read from one of two sources")
    }

    @MainActor
    func testFailedAdditionIsNotReportedAsReset() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SWPPrivacyStore(loadSnapshot: { _ in SWPPrivacySnapshot(apps: [], coverage: []) })
        let id = await store.includeApp(at: folder)
        XCTAssertNil(id)
        XCTAssertEqual(store.result?.operation, .addApp)
        XCTAssertEqual(store.result?.status, .failed)
        XCTAssertEqual(store.result?.title, "Could not add app")
    }

    func testLegacyAndUnexpectedDecisionValuesStayDistinct() {
        XCTAssertEqual(SWPPrivacyDecision.decode(1, legacy: true), .allowed)
        XCTAssertEqual(SWPPrivacyDecision.decode(1, legacy: false), .undetermined)
        XCTAssertEqual(SWPPrivacyDecision.decode(nil, legacy: false), .unknown)
        XCTAssertEqual(SWPPrivacyDecision.decode(87, legacy: false), .unknown)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-privacy-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDatabase(at url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: 1) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    @discardableResult
    private func makeApp(at url: URL, identifier: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": "Fixture"],
                                                       format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
}

private actor PrivacyOperationGate {
    private(set) var count = 0
    private var claimed = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func record() { count += 1 }

    func claimFirst() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }

    func suspend() async {
        count += 1
        await withCheckedContinuation { continuation in
            suspended = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitForStart() async {
        guard suspended == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        suspended?.resume()
        suspended = nil
    }
}
