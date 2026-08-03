import ImageIO
import simd
import XCTest
@testable import Bricky

final class RecoveryCaptureTests: XCTestCase {
    func testUprightRotationCoversEveryDeviceOrientationAndPoleFallback() {
        XCTAssertEqual(RecoveryFrameConvention.uprightRotation(cameraTransform: transform(upX: 0, upY: 1)), .up)
        XCTAssertEqual(RecoveryFrameConvention.uprightRotation(cameraTransform: transform(upX: 0, upY: -1)), .down)
        XCTAssertEqual(RecoveryFrameConvention.uprightRotation(cameraTransform: transform(upX: 1, upY: 0)), .left)
        XCTAssertEqual(RecoveryFrameConvention.uprightRotation(cameraTransform: transform(upX: -1, upY: 0)), .right)
        XCTAssertEqual(RecoveryFrameConvention.uprightRotation(cameraTransform: transform(upX: 0, upY: 0)), .right)
    }

    private func transform(upX: Float, upY: Float) -> simd_float4x4 {
        var value = matrix_identity_float4x4
        value.columns.0.y = upX
        value.columns.1.y = upY
        return value
    }
}
