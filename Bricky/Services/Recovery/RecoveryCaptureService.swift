import ARKit
import CoreImage
import Foundation
import UIKit

/// Shared frame convention for recovery captures.
///
/// ARKit's `capturedImage`, `camera.transform`, and `camera.intrinsics` are
/// all expressed in the landscape sensor frame (+x along the device's long
/// axis toward the home-button side, +y along the short axis, camera looking
/// down -z). Stored physical captures are rotated so gravity points down in
/// the image; candidate renders are produced in the same landscape sensor
/// frame and rotated by the same amount, so both share one orientation.
enum RecoveryFrameConvention {
    /// The rotation that makes the landscape sensor image upright, derived
    /// from the gravity-aligned world transform of the camera at capture
    /// time. Deriving it from the recorded transform (rather than the
    /// interface orientation, which `RecoveryCapture` cannot persist) keeps
    /// capture and render exactly consistent — the renderer re-derives the
    /// identical rotation from the persisted matrix — and stays correct for
    /// landscape-held devices even under rotation lock.
    static func uprightRotation(cameraTransform transform: simd_float4x4) -> CGImagePropertyOrientation {
        // World up expressed in camera space: the world-y components of the
        // camera basis vectors.
        let up = SIMD3(transform.columns.0.y, transform.columns.1.y, transform.columns.2.y)
        // Near-degenerate when the camera points straight up or down; fall
        // back to the portrait rotation, which capture and render both share.
        guard max(abs(up.x), abs(up.y)) > 0.2 else { return .right }
        if abs(up.y) >= abs(up.x) {
            // Sensor +y aligned with world up: landscape, home button right
            // (.up) or left (.down).
            return up.y >= 0 ? .up : .down
        }
        // Sensor +x aligned with world up: upside-down portrait (.left) or
        // regular portrait (.right).
        return up.x >= 0 ? .left : .right
    }
}

@MainActor
struct RecoveryCaptureService {
    /// Creating a CIContext is expensive; share one across all captures.
    private static let sharedContext = CIContext(options: [.cacheIntermediates: false])

    func capture(from manager: ARCameraManager, angle: CaptureAngle, alignmentID: UUID) throws -> RecoveryCapture {
        guard let frame = manager.session.currentFrame else {
            throw ARCameraManager.CameraError.cameraUnavailable
        }
        // Rotate the raw landscape sensor frame upright based on the device's
        // physical pose instead of assuming portrait (.right); see
        // RecoveryFrameConvention.
        let rotation = RecoveryFrameConvention.uprightRotation(cameraTransform: frame.camera.transform)
        let source = CIImage(cvPixelBuffer: frame.capturedImage).oriented(rotation)
        guard let cgImage = Self.sharedContext.createCGImage(source, from: source.extent) else {
            throw ARCameraManager.CameraError.cameraUnavailable
        }
        let image = UIImage(cgImage: cgImage).normalizedForInference()
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        let root = try InstructionModelImporter.applicationSupportRoot()
        let captures = root.appendingPathComponent("RecoveryCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).jpg"
        try data.write(to: captures.appendingPathComponent(filename), options: .atomic)

        return RecoveryCapture(
            id: UUID(),
            imageRelativePath: "RecoveryCaptures/\(filename)",
            cameraTransform: Self.flatten(frame.camera.transform),
            cameraIntrinsics: Self.flatten(frame.camera.intrinsics),
            alignmentID: alignmentID,
            angle: angle,
            capturedAt: .now
        )
    }

    private static func flatten(_ matrix: simd_float4x4) -> [Float] {
        (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
    }

    private static func flatten(_ matrix: simd_float3x3) -> [Float] {
        (0..<3).flatMap { column in (0..<3).map { row in matrix[column][row] } }
    }
}
