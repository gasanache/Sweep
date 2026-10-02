import XCTest
import Foundation

final class LocalAIStoreTests: XCTestCase {
    @MainActor
    func testSecondRemovalAndRefreshCannotInterleaveWithCleanup() async {
        let entered = expectation(description: "Removal started")
        let gate = LocalAICleanupGate(entered: entered)
        let plan = SWPLocalAIPlan(product: .lmStudio,
                                  items: [SWPItem(url: URL(fileURLWithPath: "/fixture/.lmstudio"),
                                                  sizeBytes: 4096, modified: nil,
                                                  location: "Fixture", requiresAdmin: false)],
                                  appURLs: [], brewExecutable: nil, hasBrewPackage: false,
                                  shellProfiles: [], blockers: [], notes: [])
        let store = SWPLocalAIStore(load: { [plan] }, loadInventory: { _ in SWPAIInventory() }, remove: { _ in gate.perform() })
        store.showsCleanup = true
        await store.refresh()
        let first = Task { await store.remove(plan) }
        await fulfillment(of: [entered], timeout: 3)
        await store.remove(plan)
        await store.refresh()
        XCTAssertTrue(store.isRemoving)
        XCTAssertNil(store.result)
        gate.release.signal()
        await first.value
        XCTAssertEqual(gate.callCount, 1, "One confirmation cannot overlap another cleanup")
        XCTAssertFalse(store.isRemoving)
        XCTAssertEqual(store.result?.failures, ["Fixture package could not be removed"])
        XCTAssertEqual(store.plans.map(\.id), [plan.id], "Remaining work survives the post-cleanup refresh")
    }

    @MainActor
    func testFailedRefreshInvalidatesPreviouslyActionablePlan() async {
        let source = LocalAIChangingSource()
        let store = SWPLocalAIStore(load: { try source.load() }, loadInventory: { _ in SWPAIInventory() }, remove: { _ in
            XCTFail("An invalidated plan must not be submitted")
            return SWPLocalAICleanupResult()
        })
        store.showsCleanup = true
        await store.refresh()
        XCTAssertEqual(store.plans.map(\.id), [SWPLocalAIProduct.ollama.id])
        await store.refresh()
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertNotNil(store.scanError)
    }
}

private final class LocalAICleanupGate: @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    init(entered: XCTestExpectation) { self.entered = entered }
    var callCount: Int { lock.withLock { calls } }
    func perform() -> SWPLocalAICleanupResult {
        lock.withLock { calls += 1 }
        entered.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else {
            return SWPLocalAICleanupResult(failures: ["Fixture gate timed out"])
        }
        return SWPLocalAICleanupResult(failures: ["Fixture package could not be removed"])
    }
}

private final class LocalAIChangingSource: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    func load() throws -> [SWPLocalAIPlan] {
        try lock.withLock {
            if loaded { throw CocoaError(.fileReadNoPermission) }
            loaded = true
            return [SWPLocalAIPlan(product: .ollama,
                                   items: [SWPItem(url: URL(fileURLWithPath: "/fixture/.ollama"),
                                                   sizeBytes: 4096, modified: nil,
                                                   location: "Fixture", requiresAdmin: false)],
                                   appURLs: [], brewExecutable: nil, hasBrewPackage: false,
                                   shellProfiles: [], blockers: [], notes: [])]
        }
    }
}
