import RecoveryEvidenceKit
import XCTest
@testable import BrickyLanguage

/// The advisor may only move a check toward incomplete, and its crop is the
/// geometry's box, grown a little and kept inside the image.
final class StepCheckAdviceTests: XCTestCase {
    private func advice(_ standalone: CheckVerdictV1?, _ closed: ClosedCheckAnswer?) -> StepCheckAdvice {
        StepCheckAdvice(standalone: standalone, standaloneOutcome: "answered", closed: closed, closedOutcome: "answered", milliseconds: 1)
    }

    func testTheAdvisorOnlyEverTakesACompleteAway() {
        for primary in CheckVerdictV1.allCases {
            for standalone in [nil] + CheckVerdictV1.allCases.map(Optional.some) {
                for closed in [nil] + ClosedCheckAnswer.allCases.map(Optional.some) {
                    let merged = ShadowMerge.merge(primary: primary, advice: advice(standalone, closed))
                    if primary != .complete {
                        XCTAssertEqual(merged, primary, "never moves a non-complete verdict")
                    }
                    XCTAssertTrue(merged == primary || merged == .incomplete, "only toward incomplete")
                }
            }
        }
        XCTAssertEqual(ShadowMerge.merge(primary: .complete, advice: advice(.complete, .absent)), .incomplete)
        XCTAssertEqual(ShadowMerge.merge(primary: .complete, advice: advice(.incomplete, nil)), .incomplete)
        XCTAssertEqual(ShadowMerge.merge(primary: .complete, advice: advice(.uncertain, .cannotTell)), .complete)
        XCTAssertEqual(ShadowMerge.merge(primary: .complete, advice: .skipped("unavailable_model")), .complete)
    }

    func testTheCropIsTheBoxGrownAndClamped() throws {
        let box = CheckGeometryRecord.Box(x: 0.4, y: 0.5, width: 0.2, height: 0.1)
        let rect = try XCTUnwrap(CheckCrop.rect(for: box, imageWidth: 1000, imageHeight: 800, margin: 0.25))
        // Grown by 0.25 × 0.2 = 0.05 on every side: x 0.35–0.65, y 0.45–0.65.
        let ideal = CGRect(x: 350, y: 360, width: 300, height: 160)
        XCTAssertTrue(rect.contains(ideal), "\(rect) covers \(ideal)")
        XCTAssertLessThanOrEqual(rect.width - ideal.width, 2)
        XCTAssertLessThanOrEqual(rect.height - ideal.height, 2)
        let edge = try XCTUnwrap(CheckCrop.rect(for: .init(x: 0.95, y: 0, width: 0.05, height: 0.05), imageWidth: 100, imageHeight: 100))
        XCTAssertLessThanOrEqual(edge.maxX, 100)
        XCTAssertGreaterThanOrEqual(edge.minY, 0)
        XCTAssertNil(CheckCrop.rect(for: .init(x: 0.5, y: 0.5, width: 0, height: 0.1), imageWidth: 100, imageHeight: 100))
    }
}
