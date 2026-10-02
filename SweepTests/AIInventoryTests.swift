import XCTest
import Foundation
import Darwin

final class AIInventoryTests: XCTestCase {
    private func fixture() throws -> URL {
        guard let physical = realpath(NSTemporaryDirectory(), nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("SweepAIInventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func file(_ relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        return url
    }

    private func scanner(_ home: URL) -> SWPAIInventoryScanner {
        SWPAIInventoryScanner(home: home, applicationRoots: [], commandRoots: [], environment: [:])
    }

    func testSeparatesAssistantDataFromModelCandidatesWithoutReadingSecrets() throws {
        let root = try fixture()
        let secret = try file(".codex/auth.json", in: root)
        let conversation = try file(".claude/projects/session.jsonl", in: root)
        try file("Library/Containers/com.openai.chat/Data/history.db", in: root)
        let model = try file("Models/example.gguf", in: root)
        try file("Models/ordinary.bin", in: root)
        XCTAssertEqual(chmod(secret.path, 0), 0)
        XCTAssertEqual(chmod(conversation.path, 0), 0)
        defer { chmod(secret.path, 0o600); chmod(conversation.path, 0o600) }
        let snapshot = scanner(root).scan()
        XCTAssertEqual(snapshot.findings.filter { $0.kind.isModel }.map(\.url), [model])
        XCTAssertTrue(Set(snapshot.findings.filter { $0.kind == .assistantData }.map(\.product))
            .isSuperset(of: ["Codex", "Claude Code", "ChatGPT"]))
        XCTAssertFalse(snapshot.findings.contains { $0.url == secret || $0.url == conversation })
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }

    func testHuggingFaceRepositoriesAreNotCountedPerRevisionOrShard() throws {
        let root = try fixture()
        let repository = root.appendingPathComponent(".cache/huggingface/hub/models--fixture--tiny")
        try file("blobs/weight", in: repository)
        let link = repository.appendingPathComponent("snapshots/revision/model.safetensors")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../blobs/weight")
        let snapshot = scanner(root).scan()
        XCTAssertEqual(snapshot.findings.filter { $0.kind.isModel }.map { $0.url.path }, [repository.path])
        XCTAssertEqual(snapshot.findings.first { $0.url.path == repository.path }?.kind, .modelRepository)
        XCTAssertTrue(snapshot.isPartial, "Unfollowed links must remain visible as partial coverage")
        XCTAssertFalse(snapshot.findings.contains { $0.url == link })
    }

    func testCustomEnvironmentAndAddedFoldersAreInspectedAndDeduplicated() throws {
        let root = try fixture()
        let custom = root.appendingPathComponent("Custom")
        let model = try file("model.safetensors", in: custom)
        var scan = scanner(root)
        scan.environment = ["OLLAMA_MODELS": custom.path, "HF_HOME": "relative/path"]
        scan.additionalFolders = [custom, custom]
        let snapshot = scan.scan()
        XCTAssertEqual(snapshot.findings.filter { $0.url == model }.count, 1)
        XCTAssertEqual(snapshot.findings.filter { $0.url.path == custom.path }.count, 1)
        XCTAssertEqual(Set(snapshot.findings.map(\.id)).count, snapshot.findings.count)
    }

    func testLinkedRootsAndChildrenAreNotFollowed() throws {
        let root = try fixture()
        let outside = try fixture()
        let model = try file("secret.gguf", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Models"), withDestinationURL: outside)
        let snapshot = scanner(root).scan()
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertFalse(snapshot.findings.contains { $0.url == model })
        XCTAssertNil(snapshot.findings.first { $0.url.lastPathComponent == "Models" }?.allocatedBytes)
    }

    func testBudgetExhaustionDoesNotPretendToBeAnEmptyCompleteScan() throws {
        let root = try fixture()
        for index in 0..<8 { try file("Models/\(index).gguf", in: root) }
        var scan = scanner(root)
        scan.maximumEntries = 2
        let snapshot = scan.scan()
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertTrue(snapshot.findings.contains { $0.isPartial && $0.note.contains("limit") })
        XCTAssertTrue(snapshot.notes.contains { $0.contains("Missing rows") })
    }

    func testFindingLimitRemainsBoundedAndExplicit() throws {
        let root = try fixture()
        for index in 0..<8 { try file("Models/\(index).gguf", in: root) }
        var scan = scanner(root)
        scan.maximumFindings = 3
        let snapshot = scan.scan()
        XCTAssertLessThanOrEqual(snapshot.findings.count, 3)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertTrue(snapshot.notes.contains("Finding limit reached."))
    }

    func testModelFormatsAndOpaqueOllamaBlobs() throws {
        for name in ["test.gguf", "TEST.SAFETENSORS", "model.onnx", "weights.pt", "weights.ckpt", "network.mlpackage", "network.keras", "weights.npz", "network.h5", "saved_model.pb", "model.bin", "pytorch_model-00001.bin", "ggml-base.bin"] {
            XCTAssertTrue(SWPAIInventoryScanner.isModelFilename(name), name)
        }
        for name in ["auth.json", "history.jsonl", "tool.bin", "trace.pb", "README.md", "model.gguf.txt"] {
            XCTAssertFalse(SWPAIInventoryScanner.isModelFilename(name), name)
        }
        let root = try fixture()
        try file(".ollama/models/blobs/sha256-fixture", in: root)
        let snapshot = scanner(root).scan()
        XCTAssertEqual(snapshot.locationCount, 1)
        XCTAssertEqual(snapshot.modelCount, 0, "Opaque blobs are a store, not distinct models")
        let package = root.appendingPathComponent("Models/network.mlpackage")
        try file("Data/weights", in: package)
        let withPackage = scanner(root).scan()
        XCTAssertEqual(withPackage.findings.filter { $0.kind.isModel }.map { $0.url.path }, [package.path],
                       "Core ML package detection must not depend on installed UTI registrations")
    }

    func testGenericCleanupCannotRemoveKnownAssistantOrSharedModelData() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        for path in ["Library/Caches/com.openai.chat", "Library/Application Support/Claude",
                     "Library/Containers/com.openai.chat/Data", ".cache/torch/hub", ".cache/huggingface/hub",
                     "Library/Application Support/nomic.ai"] {
            let url = home.appendingPathComponent(path)
            XCTAssertTrue(SWPAICatalog.protectsFromGenericRemoval(url, home: home), path)
            XCTAssertFalse(SWPSafety.validate(url).isAllowed, path)
        }
        XCTAssertFalse(SWPAICatalog.protectsFromGenericRemoval(home.appendingPathComponent("Library/Caches/com.openai.chat-other"), home: home))
    }

    @MainActor
    func testMainScanCarriesAIOutsideCleanupTotalsAndSelection() async throws {
        let root = try fixture()
        let evidence = SWPAIInventory(findings: [SWPAIFinding(url: root, product: "Fixture", kind: .modelStore, allocatedBytes: 4096)])
        let engine = SWPScanEngine(scanWork: { _, _, folders, _, stage in
            XCTAssertEqual(folders, [root])
            var result = SWPScanResult()
            result.aiInventory = evidence
            await stage(.ai, [], result)
        })
        engine.additionalAIFolders = [root]
        engine.scan()
        for _ in 0..<300 where engine.lastScanDate == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(engine.lastScanDate)
        XCTAssertEqual(engine.result.aiInventory?.locationCount, 1)
        XCTAssertEqual(engine.result.totalBytes, 0)
        engine.selectAllSafe()
        XCTAssertTrue(engine.selectedGroups.isEmpty)
        XCTAssertTrue(engine.completedStages.contains(.ai))
        XCTAssertFalse(SWPDestination.tools.contains(.localAI))
    }

    @MainActor
    func testStorePreservesSearchSelectionAndRejectsOlderInventory() async {
        let url = URL(fileURLWithPath: "/fixture/Models/model.gguf")
        let finding = SWPAIFinding(url: url, product: "Fixture", kind: .modelFile, allocatedBytes: 1)
        let now = Date()
        let store = SWPLocalAIStore(load: { [] }, loadInventory: { _ in SWPAIInventory() })
        store.acceptInventory(SWPAIInventory(findings: [finding], scannedAt: now))
        store.inventoryQuery = "model.gguf"
        store.selectedFindingID = finding.id
        store.acceptInventory(SWPAIInventory(scannedAt: now.addingTimeInterval(-1)))
        XCTAssertEqual(store.visibleFindings.map(\.id), [finding.id])
        XCTAssertEqual(store.selectedFindingID, finding.id)
        store.acceptInventory(SWPAIInventory(scannedAt: now.addingTimeInterval(1)))
        XCTAssertNil(store.selectedFindingID)
        XCTAssertEqual(store.inventoryQuery, "model.gguf")
    }

    @MainActor
    func testDiscoveryDoesNotBuildDestructiveCleanupPlans() async {
        let store = SWPLocalAIStore(load: { XCTFail("Discovery must not build a cleanup plan"); return [] },
                                    loadInventory: { _ in SWPAIInventory() })
        await store.refreshIfNeeded()
        XCTAssertNotNil(store.inventory)
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertFalse(store.isScanning)
    }

    @MainActor
    func testMainScanWithOldFolderScopeCannotEraseAddedFolderResults() async throws {
        let root = try fixture()
        let store = SWPLocalAIStore(load: { [] }, loadInventory: { folders in
            SWPAIInventory(additionalFolderPaths: Set(folders.map(\.path)))
        })
        await store.addFolder(root)
        let time = try XCTUnwrap(store.inventory?.scannedAt)
        store.acceptInventory(SWPAIInventory(scannedAt: time.addingTimeInterval(1)))
        XCTAssertEqual(store.inventory?.additionalFolderPaths, [root.path])
        XCTAssertEqual(store.inventory?.scannedAt, time)
        await store.removeFolder(root)
        XCTAssertTrue(store.additionalFolders.isEmpty)
        XCTAssertTrue(SWPAIInspectionProtection.shared.protects(root), "Leaving discovery must not re-arm an older cleanup plan")
    }

    func testAddedModelFoldersAndAggregateParentsAreReservedFromBulkRemoval() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let parent = home.appendingPathComponent("Library/Caches/Sweep-AI-test-\(UUID().uuidString)")
        let modelRoot = parent.appendingPathComponent("custom-models")
        SWPAIInspectionProtection.shared.reserve([modelRoot])
        for url in [parent, modelRoot, modelRoot.appendingPathComponent("model.gguf")] {
            XCTAssertFalse(SWPSafety.validate(url).isAllowed)
        }
        XCTAssertFalse(SWPAIInspectionProtection.shared.protects(URL(fileURLWithPath: parent.path + "-other")))
    }

    func testCancelledDiscoveryDoesNotPublishACompleteEmptyInventory() async throws {
        let scan = scanner(try fixture())
        let worker = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return scan.scan()
        }
        worker.cancel()
        let snapshot = await worker.value
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertTrue(snapshot.findings.isEmpty)
        XCTAssertTrue(snapshot.notes.contains("Discovery was cancelled."))
    }

    func testModelHardLinksKeepTheirNonAdditiveExplanation() throws {
        let root = try fixture()
        let first = try file("Models/a.gguf", in: root)
        let second = first.deletingLastPathComponent().appendingPathComponent("b.gguf")
        try FileManager.default.linkItem(at: first, to: second)
        let snapshot = scanner(root).scan()
        let duplicate = try XCTUnwrap(snapshot.findings.first { $0.url.path == second.path })
        XCTAssertEqual(duplicate.allocatedBytes, 0)
        XCTAssertTrue(duplicate.note.contains("Hard link"))
    }

    @MainActor
    func testConfirmationPreventsRefreshAndFolderRetargeting() async {
        let store = SWPLocalAIStore(load: { XCTFail("Must not refresh a reviewed plan"); return [] },
                                    loadInventory: { _ in XCTFail("Must not refresh during confirmation"); return SWPAIInventory() })
        store.isConfirming = true
        await store.refresh()
        await store.addFolder(URL(fileURLWithPath: "/fixture"))
        XCTAssertTrue(store.additionalFolders.isEmpty)
    }
}
