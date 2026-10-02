import XCTest
import Foundation
import Combine
import Darwin

final class StorageTests: XCTestCase {
    func testHardLinksAreAttributedOnceInNameOrderAcrossFolders() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let first = try fixture.folder("root/A")
        let second = try fixture.folder("root/B")
        let file = try fixture.file("root/A/first", bytes: 32_768)
        try FileManager.default.linkItem(at: file, to: second.appendingPathComponent("second"))
        let root = fixture.url.appendingPathComponent("root")

        let result = try SWPStorageScanner().scan(rootURL: root)
        let a = try XCTUnwrap(result.root.children.first { $0.name == "A" })
        let b = try XCTUnwrap(result.root.children.first { $0.name == "B" })
        XCTAssertEqual(a.children.first?.allocatedBytes, try allocated(file))
        XCTAssertEqual(b.children.first?.allocatedBytes, 0)
        XCTAssertEqual(result.coverage.duplicateHardLinks, 1)
        XCTAssertEqual(result.root.allocatedBytes, try allocated(root) + allocated(first) + allocated(second) + allocated(file))
        XCTAssertFalse(result.root.isPartial)
    }

    func testSymbolicLinksDoNotContributeOutsideAllocationOrAllowRootTraversal() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let root = try fixture.folder("root")
        let outside = try fixture.folder("outside")
        _ = try fixture.file("outside/private-data", bytes: 65_536)
        let link = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = try SWPStorageScanner().scan(rootURL: root)
        XCTAssertEqual(result.coverage.skippedLinks, 1)
        XCTAssertTrue(result.root.isPartial)
        XCTAssertEqual(result.root.allocatedBytes, try allocated(root))
        let entry = try XCTUnwrap(result.root.children.first)
        XCTAssertNil(entry.allocatedBytes)
        XCTAssertFalse(entry.canBrowse)
        XCTAssertTrue(entry.children.isEmpty)
        XCTAssertThrowsError(try SWPStorageScanner().scan(rootURL: link))
        _ = try fixture.folder("outside/nested")
        XCTAssertThrowsError(try SWPStorageScanner().scan(rootURL: link.appendingPathComponent("nested")))
    }

    func testPackageContentsAreMeasuredButNotExposedForNavigation() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let root = try fixture.folder("root")
        let package = try fixture.folder("root/Example.app")
        let contents = try fixture.folder("root/Example.app/Contents")
        let payload = try fixture.file("root/Example.app/Contents/payload", bytes: 16_384)

        let result = try SWPStorageScanner().scan(rootURL: root)
        let entry = try XCTUnwrap(result.root.children.first)
        XCTAssertFalse(entry.canBrowse)
        XCTAssertTrue(entry.children.isEmpty)
        XCTAssertEqual(entry.allocatedBytes, try allocated(package) + allocated(contents) + allocated(payload))
        XCTAssertFalse(entry.isPartial)
    }

    func testEntryDepthAndMemoryLimitsReportIncompleteCoverage() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let root = try fixture.folder("root")
        _ = try fixture.file("root/one", bytes: 1)
        _ = try fixture.file("root/two", bytes: 1)

        let limited = try SWPStorageScanner(maximumEntries: 1).scan(rootURL: root)
        XCTAssertTrue(limited.coverage.reachedLimit)
        XCTAssertTrue(limited.root.isPartial)
        XCTAssertEqual(limited.coverage.visitedEntries, 1)
        XCTAssertTrue(limited.root.children.isEmpty, "An incomplete directory listing must not arbitrarily attribute hard links")
        let exact = try SWPStorageScanner(maximumEntries: 2).scan(rootURL: root)
        XCTAssertFalse(exact.coverage.reachedLimit)
        XCTAssertFalse(exact.root.isPartial)
        XCTAssertEqual(Set(exact.root.children.map(\.name)), ["one", "two"])

        let memory = try SWPStorageScanner(maximumPathBytes: 1).scan(rootURL: root)
        XCTAssertTrue(memory.coverage.reachedLimit)
        XCTAssertTrue(memory.root.isPartial)
        XCTAssertEqual(memory.coverage.visitedEntries, 0)

        _ = try fixture.folder("deep/child")
        _ = try fixture.file("deep/child/file", bytes: 4_096)
        let depth = try SWPStorageScanner(maximumDepth: 1).scan(rootURL: fixture.url.appendingPathComponent("deep"))
        XCTAssertTrue(depth.coverage.reachedLimit)
        let child = try XCTUnwrap(depth.root.children.first)
        XCTAssertTrue(child.isPartial)
        XCTAssertTrue(child.children.isEmpty)
    }

    func testRescanRefusesAReplacedRootIdentity() throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let root = try fixture.folder("root")
        let original = try SWPStorageScanner().scan(rootURL: root)
        try FileManager.default.moveItem(at: root, to: fixture.url.appendingPathComponent("previous-root"))
        _ = try fixture.folder("root")
        _ = try fixture.file("root/unreviewed", bytes: 4_096)
        XCTAssertThrowsError(try SWPStorageScanner().scan(rootURL: root, expectedIdentity: original.rootIdentity))
        let newlyChosen = try SWPStorageScanner().scan(rootURL: root)
        XCTAssertEqual(newlyChosen.root.children.map(\.name), ["unreviewed"])
    }

    func testCancellationReachesSynchronousDetachedTraversal() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let root = try fixture.folder("root")
        _ = try fixture.file("root/file", bytes: 8_192)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SWPStorageScanner().scan(rootURL: root)
        }
        let result = try await worker.value
        XCTAssertTrue(result.coverage.cancelled)
        XCTAssertTrue(result.root.isPartial)
        XCTAssertTrue(result.root.children.isEmpty)
    }

    @MainActor
    func testNewFolderCancelsOldWorkerAndRejectsItsLateResult() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let firstURL = try fixture.folder("first")
        let secondURL = try fixture.folder("second")
        let first = try SWPStorageScanner().scan(rootURL: firstURL)
        let second = try SWPStorageScanner().scan(rootURL: secondURL)
        let entered = expectation(description: "First worker entered")
        let returned = expectation(description: "Old worker returned after replacement")
        let source = StorageScanGate(first: first, second: second, entered: entered, returned: returned)
        let store = SWPStorageStore(load: { url, _ in source.load(url) })
        let newerPublished = expectation(description: "New folder inventory published")
        let stalePublished = expectation(description: "Old folder must never replace new folder")
        stalePublished.isInverted = true
        let observation = store.$snapshot.compactMap { $0 }.sink { result in
            if result.root.url == secondURL { newerPublished.fulfill() }
            if result.root.url == firstURL { stalePublished.fulfill() }
        }
        defer { observation.cancel(); source.release.signal() }

        store.selectFolder(firstURL)
        await fulfillment(of: [entered], timeout: 3)
        store.selectFolder(secondURL)
        await fulfillment(of: [newerPublished], timeout: 3)
        source.release.signal()
        await fulfillment(of: [returned], timeout: 3)
        await fulfillment(of: [stalePublished], timeout: 0.2)
        XCTAssertTrue(source.oldWorkerWasCancelled)
        XCTAssertEqual(store.rootURL, secondURL)
        XCTAssertEqual(store.snapshot?.root.url, secondURL)
        XCTAssertFalse(store.isScanning)
    }

    @MainActor
    func testNavigationIsLimitedToBrowsableChildrenOfCurrentSnapshot() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let root = try fixture.folder("root")
        _ = try fixture.folder("root/child/nested")
        _ = try fixture.folder("root/Example.app")
        let snapshot = try SWPStorageScanner().scan(rootURL: root)
        let store = SWPStorageStore(load: { _, _ in snapshot })
        let loaded = expectation(description: "Navigation inventory loaded")
        let observation = store.$snapshot.compactMap { $0 }.sink { _ in loaded.fulfill() }
        defer { observation.cancel() }
        store.selectFolder(root)
        await fulfillment(of: [loaded], timeout: 3)

        let child = try XCTUnwrap(snapshot.root.children.first { $0.name == "child" })
        let nested = try XCTUnwrap(child.children.first)
        let package = try XCTUnwrap(snapshot.root.children.first { $0.name == "Example.app" })
        store.browse(nested)
        store.browse(package)
        XCTAssertEqual(store.currentEntry?.url, root, "Only immediate, non-package folders are browsable")
        store.browse(child)
        store.browse(nested)
        XCTAssertEqual(store.currentEntry?.url, nested.url)
        store.goBack()
        XCTAssertEqual(store.currentEntry?.url, child.url)
        store.goToRoot()
        store.goBack()
        XCTAssertEqual(store.currentEntry?.url, root)
    }

    private func allocated(_ url: URL) throws -> Int64 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int64(metadata.st_blocks) * 512
    }
}

private struct StorageFixture {
    let url: URL

    init() throws {
        guard let physical = realpath(NSTemporaryDirectory(), nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(physical) }
        url = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func folder(_ path: String) throws -> URL {
        let result = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    func file(_ path: String, bytes: Int) throws -> URL {
        let result = url.appendingPathComponent(path)
        try Data(repeating: 0x5A, count: bytes).write(to: result)
        return result
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private final class StorageScanGate: @unchecked Sendable {
    let first: SWPStorageSnapshot
    let second: SWPStorageSnapshot
    let entered: XCTestExpectation
    let returned: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancellationObserved = false

    init(first: SWPStorageSnapshot, second: SWPStorageSnapshot,
         entered: XCTestExpectation, returned: XCTestExpectation) {
        self.first = first
        self.second = second
        self.entered = entered
        self.returned = returned
    }

    var oldWorkerWasCancelled: Bool { lock.withLock { cancellationObserved } }

    func load(_ url: URL) -> SWPStorageSnapshot {
        guard url == first.root.url else { return second }
        entered.fulfill()
        _ = release.wait(timeout: .now() + 5)
        lock.withLock { cancellationObserved = Task.isCancelled }
        returned.fulfill()
        // Deliberately ignore cancellation to model a filesystem request that
        // finishes late; the store must still reject this stale generation.
        return first
    }
}
