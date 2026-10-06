import XCTest
import simd
@testable import Bricky

final class VerificationWindowBufferTests: XCTestCase {
    private func sample(_ timestamp: TimeInterval) -> VerificationWindowSample {
        VerificationWindowSample(
            frameID: UUID(),
            frame: RegistrationFrameInput(
                depth: [], confidence: [], rawDepth: nil, rawConfidence: nil, width: 0, height: 0,
                depthIntrinsics: matrix_identity_float3x3, worldFromCamera: matrix_identity_float4x4, timestamp: timestamp
            ),
            registration: ModelRegistration(
                alignmentID: UUID(), worldFromModel: matrix_identity_float4x4, state: .locked,
                quality: .none, fittedStepIndex: 0, timestamp: timestamp
            ),
            result: StepVerification(
                stepID: "s", verdict: .incomplete, detectability: .strong, deltaPixels: 0, framesUsed: 0,
                completeFraction: 0, incompleteFraction: 0, registrationQuality: .none, timestamp: timestamp
            ),
            ingestMilliseconds: 1
        )
    }

    func testKeepsTheNewestFramesOldestFirst() {
        var buffer = VerificationWindowBuffer(capacity: 3)
        for timestamp in 1...5 { buffer.append(sample(TimeInterval(timestamp))) }
        XCTAssertEqual(buffer.samples.map(\.frame.timestamp), [3, 4, 5])
        buffer.removeAll()
        XCTAssertTrue(buffer.samples.isEmpty)
    }
}
