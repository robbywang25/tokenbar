import XCTest
import SwiftUI
@testable import TokenBar

final class MetricFlowLayoutTests: XCTestCase {
    private func arrange(_ sizes: [CGSize], width: CGFloat?) -> MetricFlowArrangement {
        MetricFlowArrangement(sizes: sizes, proposedWidth: width, horizontalSpacing: 12, verticalSpacing: 6)
    }

    func testFiniteProposalKeepsContainerWidthInsteadOfShrinkingToLongestRow() {
        let metrics = [CGSize(width: 100.2, height: 14), CGSize(width: 100.2, height: 14),
                       CGSize(width: 70, height: 18), CGSize(width: 180, height: 12)]
        let measured = arrange(metrics, width: 384)
        XCTAssertEqual(measured.size, CGSize(width: 384, height: 36))
        XCTAssertEqual(measured.origins.last, CGPoint(x: 0, y: 24))
        XCTAssertEqual(arrange(metrics, width: measured.size.width), measured)
        XCTAssertEqual(zip(measured.origins, metrics).map { $0.y + $1.height }.max(), measured.size.height)
    }

    func testPlacementWidthOneULPSmallerCannotAddAnUnmeasuredRow() {
        let metrics = [CGSize(width: 100.2, height: 14), CGSize(width: 100.2, height: 14)]
        let measured = arrange(metrics, width: ProposedViewSize.unspecified.width)
        let placed = arrange(metrics, width: measured.size.width.nextDown)
        XCTAssertEqual(measured.size.width, 212.4)
        XCTAssertEqual(placed.origins, measured.origins)
        XCTAssertEqual(placed.size.height, 14)
        XCTAssertEqual(placed.origins[1].y, 0)
    }

    func testMeaningfulNarrowingStillMovesTheWholeMetricToTheNextRow() {
        let metrics = [CGSize(width: 100.2, height: 14), CGSize(width: 100.2, height: 14)]
        let placed = arrange(metrics, width: 212.4 - 0.25)
        XCTAssertEqual(placed.size.height, 34)
        XCTAssertEqual(placed.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20)])
    }

    func testUnspecifiedAndInfiniteProbesProduceTheSameFiniteIdealSize() {
        let metrics = [CGSize(width: 80, height: 12), CGSize(width: 70, height: 18)]
        let ideal = arrange(metrics, width: ProposedViewSize.unspecified.width)
        let maximum = arrange(metrics, width: ProposedViewSize.infinity.width)
        XCTAssertEqual(ideal, maximum)
        XCTAssertEqual(ideal.size, CGSize(width: 162, height: 18))
        XCTAssertTrue(ideal.size.width.isFinite)
        XCTAssertEqual(arrange(metrics, width: ideal.size.width), ideal)
    }

    func testZeroWidthStacksItemsAndOversizedMetricDoesNotExpandTheContainer() {
        let metrics = [CGSize(width: 500, height: 18), CGSize(width: 20, height: 12)]
        let minimum = arrange(metrics, width: ProposedViewSize.zero.width)
        XCTAssertEqual(minimum.size, CGSize(width: 0, height: 36))
        XCTAssertEqual(minimum.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 24)])
        let narrow = arrange(metrics, width: 200)
        XCTAssertEqual(narrow.size, CGSize(width: 200, height: 36))
        XCTAssertEqual(narrow.origins, minimum.origins)
        XCTAssertEqual(arrange(metrics, width: narrow.size.width), narrow)
    }

    func testEmptyContentHasNoHeightForEveryProbe() {
        for width: CGFloat? in [nil, 0, 384, .infinity] {
            let result = arrange([], width: width)
            XCTAssertTrue(result.origins.isEmpty)
            XCTAssertEqual(result.size.height, 0)
            XCTAssertEqual(result.size.width, width == 384 ? 384 : 0)
        }
    }

    func testMixedHeightRowsDoNotOverlapAndReportedHeightContainsEveryItem() {
        let metrics = [CGSize(width: 80, height: 10), CGSize(width: 80, height: 25),
                       CGSize(width: 120, height: 12), CGSize(width: 20, height: 9)]
        let result = arrange(metrics, width: 200)
        XCTAssertEqual(result.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 92, y: 0),
                                        CGPoint(x: 0, y: 31), CGPoint(x: 132, y: 31)])
        XCTAssertEqual(result.size, CGSize(width: 200, height: 43))
        let frames = zip(result.origins, metrics).map { CGRect(origin: $0, size: $1) }
        for index in frames.indices {
            XCTAssertLessThanOrEqual(frames[index].maxY, result.size.height)
            for other in frames.indices where other > index {
                XCTAssertFalse(frames[index].intersects(frames[other]))
            }
        }
    }

    func testRepeatedParentMeasurementsConvergeWithoutChangingHeight() {
        let metrics = [CGSize(width: 68.3, height: 14), CGSize(width: 132.1, height: 20),
                       CGSize(width: 56.4, height: 12), CGSize(width: 92.8, height: 14)]
        for proposal: CGFloat? in [nil, 0, 120, 212.4, 384, .infinity] {
            let initial = arrange(metrics, width: proposal)
            var result = initial
            for _ in 0..<20 {
                result = arrange(metrics, width: result.size.width)
                XCTAssertEqual(result, initial)
            }
        }
    }
}
