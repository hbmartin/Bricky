import ARKit
import CoreImage
import Foundation
import UIKit

@MainActor
struct RecoveryCaptureService {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func capture(from manager: ARCameraManager, angle: CaptureAngle, alignmentID: UUID) throws -> RecoveryCapture {
        guard let frame = manager.session.currentFrame else {
            throw ARCameraManager.CameraError.cameraUnavailable
        }
        let source = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cgImage = context.createCGImage(source, from: source.extent) else {
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
