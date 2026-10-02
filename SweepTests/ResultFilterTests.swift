import XCTest
import Foundation

final class ResultFilterTests: XCTestCase {
    func testMinimumSizesIncludeBoundaryAndUseTotalGroupBytes() {
        let thresholds: [(SWPMinimumSize, Int64)] = [
            (.tenMB, 10_000_000), (.hundredMB, 100_000_000), (.oneGB, 1_000_000_000)
        ]
        for (minimum, bytes) in thresholds {
            let below = group("below", sizes: [bytes - 1])
            let atBoundary = group("boundary", sizes: [bytes / 2, bytes - bytes / 2])
            let above = group("above", sizes: [bytes + 1])
            let filter = SWPResultFilter(minimumSize: minimum)
            XCTAssertEqual(filter.matchingGroups(in: [below, atBoundary, above]).map(\.id),
                           ["boundary", "above"], "Threshold \(minimum) is inclusive and per group")
        }
    }

    func testQuerySizeAndEvidenceComposeWithoutNarrowingGroupItems() {
        let wanted = group("vendor", evidence: .confirmed, sizes: [6_000_000, 4_000_000],
                           paths: ["/fixture/Chrome/Cache", "/fixture/vendor/Preferences"])
        let wantedByName = group("Chrome", evidence: .confirmed, sizes: [10_000_000])
        let wrongEvidence = group("Chrome running", evidence: .inUse, sizes: [20_000_000])
        let tooSmall = group("Chrome small", evidence: .confirmed, sizes: [9_999_999])
        let wrongQuery = group("Other", evidence: .confirmed, sizes: [20_000_000])
        let filter = SWPResultFilter(query: " \nCHROME \n", minimumSize: .tenMB, evidence: .confirmed)

        XCTAssertEqual(filter.matchingGroups(in: [wrongEvidence, tooSmall, wrongQuery, wanted, wantedByName]),
                       [wanted, wantedByName], "Name and path matches cannot bypass size or evidence")
    }

    func testEvidenceUsesEveryExistingConfidenceTierAndAllSizesIncludesZero() {
        let groups = [SWPConfidence.safe, .confirmed, .likely, .inUse].map { evidence in
            group(evidence.label, evidence: evidence, sizes: [0])
        }
        XCTAssertEqual(SWPResultFilter().matchingGroups(in: groups), groups)
        for (index, evidence) in [SWPConfidence.safe, .confirmed, .likely, .inUse].enumerated() {
            XCTAssertEqual(SWPResultFilter(evidence: evidence).matchingGroups(in: groups),
                           [groups[index]], "Evidence filtering must not merge Safe, Orphaned, Review or In Use")
        }
    }

    func testWhitespaceQueryDoesNotHideFindingsButOtherFiltersStayActive() {
        let finding = group("Cache", sizes: [1_000])
        var filter = SWPResultFilter(query: " \n\t")
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.matchingGroups(in: [finding]), [finding])
        filter.minimumSize = .tenMB
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.matchingGroups(in: [finding]), [])
        filter.minimumSize = .all
        filter.evidence = .inUse
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.matchingGroups(in: [finding]), [])
    }

    private func group(_ id: String, evidence: SWPConfidence = .safe,
                       sizes: [Int64], paths: [String]? = nil) -> SWPGroup {
        let items = sizes.enumerated().map { index, bytes in
            SWPItem(url: URL(fileURLWithPath: paths?[index] ?? "/fixture/\(id)/\(index)"),
                    sizeBytes: bytes, modified: nil, location: "Fixture", requiresAdmin: false)
        }
        return SWPGroup(id: id, name: id, category: .caches, confidence: evidence, items: items)
    }
}
