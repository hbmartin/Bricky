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

#if canImport(FoundationModels)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Runs the system model on two generated images; local only
/// (`BRICKY_FM_LIVE=1`), informational: it proves the image path works on
/// this Mac, not how the advisor judges real builds.
final class StepCheckAdviceLiveTests: XCTestCase {
    private func jpeg(red: CGFloat, green: CGFloat, blue: CGFloat, block: CGRect?) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 80, y: 60, width: 160, height: 60))
        if let block {
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(block)
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testTheAdvisorAnswersOnImages() async throws {
        guard ProcessInfo.processInfo.environment["BRICKY_FM_LIVE"] == "1" else {
            throw XCTSkip("set BRICKY_FM_LIVE=1 to run the system model")
        }
        guard #available(macOS 27.0, iOS 27.0, *) else { throw XCTSkip("needs the 27 SDK") }
        if let reason = FoundationModelsRepairWording.readiness() { throw XCTSkip("system model not ready: \(reason)") }
        let block = CGRect(x: 130, y: 120, width: 60, height: 30)
        let photo = try jpeg(red: 0.8, green: 0.1, blue: 0.05, block: nil)
        let target = try jpeg(red: 0.0, green: 0.33, blue: 0.75, block: block)
        let advice = await FoundationModelsStepCheckAdvisor(deadline: .seconds(20)).advise(StepCheckAdviceInput(
            photoJPEG: photo, targetJPEG: target,
            deltaBox: .init(x: Float(block.minX / 320), y: Float((240 - block.maxY) / 240), width: Float(block.width / 320), height: Float(block.height / 240)),
            targetIsRegistered: true, stepNumber: 2
        ))
        print("LIVE_ADVICE standalone=\(advice.standalone?.rawValue ?? advice.standaloneOutcome) closed=\(advice.closed?.rawValue ?? advice.closedOutcome) ms=\(advice.milliseconds)")
        XCTAssertTrue(advice.standaloneOutcome == "answered" || advice.standaloneOutcome.hasPrefix("failed_"))
    }
}
#endif
