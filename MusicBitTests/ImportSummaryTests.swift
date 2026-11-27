import XCTest
@testable import MusicBit

final class ImportSummaryTests: XCTestCase {
    func testSummaryCountsOutcomes() {
        let summary = ImportProgressViewModel.Summary(
            imported: 2,
            duplicates: 1,
            failed: 1,
            pending: 2,
            total: 6
        )

        XCTAssertEqual(summary.finished, 4)
        XCTAssertEqual(summary.fraction, 4.0 / 6.0, accuracy: 0.0001)
        XCTAssertFalse(summary.isComplete)
    }

    func testFinishedSummaryIsComplete() {
        let summary = ImportProgressViewModel.Summary(
            imported: 3,
            duplicates: 0,
            failed: 0,
            pending: 0,
            total: 3
        )

        XCTAssertEqual(summary.fraction, 1, accuracy: 0.0001)
        XCTAssertTrue(summary.isComplete)
    }

    func testEmptySummaryHasNoProgressAndIsNotComplete() {
        let summary = ImportProgressViewModel.Summary(
            imported: 0,
            duplicates: 0,
            failed: 0,
            pending: 0,
            total: 0
        )

        XCTAssertEqual(summary.fraction, 0)
        XCTAssertFalse(summary.isComplete)
    }
}
