import CoreGraphics
import XCTest
@testable import RecoveryEvidenceKit

final class BoardVariantTests: XCTestCase {
    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testRotationPutsEachFinalistInEachSlotOnce() {
        let finalists = [6, 7, 8]
        let views = (0..<3).map { SlotAssignment.rotated(finalists, viewIndex: $0) }
        XCTAssertEqual(views, [[6, 7, 8], [7, 8, 6], [8, 6, 7]])
        for slot in 0..<3 {
            XCTAssertEqual(Set(views.map { $0[slot] }), Set(finalists), "slot \(slot)")
        }
        // Two finalists (the step-zero edge) alternate.
        XCTAssertEqual((0..<3).map { SlotAssignment.rotated([-1, 0], viewIndex: $0) }, [[-1, 0], [0, -1], [-1, 0]])
        XCTAssertEqual(SlotAssignment.order(finalists, viewIndex: 1, order: .sorted), finalists)
    }

    func testBaselinePromptsAreTheShippedStrings() {
        XCTAssertEqual(RecoveryPrompts.rank(slotCount: 3, style: .baseline), RecoveryPrompts.baselineRank)
        XCTAssertTrue(RecoveryPrompts.baselineRank.contains("renders A–H"))
        XCTAssertTrue(RecoveryPrompts.rank(slotCount: 3, style: .dynamicRange).contains("renders A–C"))
        XCTAssertTrue(RecoveryPrompts.rank(slotCount: 1, style: .dynamicRange).contains("renders A are"))
        XCTAssertEqual(RecoveryPrompts.check(style: .baseline), RecoveryPrompts.baselineCheck)
    }

    func testLabelStyles() {
        XCTAssertEqual(TileLabelStyle.slotAndStep.label(slot: "B", stepNumber: 12), "B · Step 12")
        XCTAssertEqual(TileLabelStyle.slotOnly.label(slot: "B", stepNumber: 12), "B")
    }

    func testV2BoardsAreBoardSizedAndDifferFromV1() throws {
        let candidates = try (0..<3).map { RecoveryBoardLayoutV2.Candidate(slot: ["A", "B", "C"][$0], image: try image(512, 384), stepNumber: $0 + 1) }
        let physical = try image(1440, 1920)
        let v2 = try RecoveryBoardLayoutV2.composeBoard(physical: physical, candidates: candidates, labels: .slotOnly)
        XCTAssertEqual([v2.width, v2.height], [1024, 1024])
        let v1 = try RecoveryBoardLayoutV1.composeBoard(physical: physical, candidates: candidates)
        XCTAssertNotEqual(v1.dataProvider?.data as Data?, v2.dataProvider?.data as Data?)
        let check = try RecoveryBoardLayoutV2.composeCheckBoard(physical: physical, target: candidates[0], labels: .slotOnly)
        XCTAssertEqual([check.width, check.height], [1024, 1024])
        // Five or more candidates fall back to the grid.
        let eight = try (0..<8).map { RecoveryBoardLayoutV2.Candidate(slot: "ABCDEFGH".map(String.init)[$0], image: try image(64, 64), stepNumber: $0) }
        XCTAssertEqual(try RecoveryBoardLayoutV2.composeBoard(physical: physical, candidates: eight, labels: .slotAndStep).width, 1024)
    }

    func testVariantIDsAndDefaults() throws {
        XCTAssertEqual(
            RecoveryInferenceVariant(slotOrder: .rotated, boardLayout: .v2, labels: .slotOnly, promptStyle: .dynamicRange, imageSide: 768).id,
            "slot_order=rotated,board=v2,labels=slot,prompt=dynamic_range,image_side=768"
        )
        let old = try JSONDecoder().decode(RecoveryInferenceVariant.self, from: Data("{}".utf8))
        XCTAssertEqual(old, .baseline)
    }
}
