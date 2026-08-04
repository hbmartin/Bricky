import ImageIO
import RealityKit
import UIKit

@MainActor
final class InstructionSnapshotRenderer {
    private let plan: InstructionPlan
    private let engine: LDrawGeometryEngine
    private var cache: [String: UIImage] = [:]

    init(plan: InstructionPlan, partPackRoot: URL) throws {
        self.plan = plan
        let root = try InstructionModelImporter.applicationSupportRoot()
        let source = root.appendingPathComponent("Models/\(plan.sourceSHA256)/Source", isDirectory: true)
        engine = LDrawGeometryEngine(sourceRoot: source, partPackRoot: partPackRoot)
    }

    func image(forStepIndex index: Int) async throws -> UIImage {
        let key = "guide:\(index)"
        if let cached = cache[key] { return cached }
        let placements = index < 0 ? [] : Array(plan.cumulativePlacements(through: plan.steps[index]))
        let snapshot = try await engine.snapshot(placements: placements)
        let model = try RealityKitInstructionAdapter.makeEntity(from: snapshot)
        let view = ARView(frame: CGRect(x: 0, y: 0, width: 420, height: 420), cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.systemBackground)
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(model)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 38
        let distance = Self.cameraDistance(bounds: snapshot.bounds)
        camera.look(at: .zero, from: SIMD3(distance, distance * 0.72, distance), relativeTo: nil)
        anchor.addChild(camera)
        view.scene.addAnchor(anchor)
        let image = try await Self.snapshot(of: view)
        cache[key] = image
        return image
    }

    /// Render in the same physical coordinate frame as the guided AR capture.
    /// The model-to-world transform is the user's transient alignment and the
    /// camera-to-world transform is recorded with that capture.
    ///
    /// Frame convention: `capture.cameraTransform` and `capture.cameraIntrinsics`
    /// are expressed in ARKit's landscape sensor frame. The virtual camera
    /// reproduces that landscape framing at the sensor's aspect ratio with the
    /// vertical FOV computed from the NATIVE sensor intrinsics (never from the
    /// downscaled stored image), and the snapshot is then rotated by the same
    /// gravity-derived rotation the physical capture applied, so candidate
    /// tiles and the stored photo share one upright orientation.
    func image(forStepIndex index: Int, capture: RecoveryCapture, alignment: ARAlignment) async throws -> UIImage {
        let key = "capture:\(capture.id.uuidString):\(index)"
        if let cached = cache[key] { return cached }
        guard capture.cameraTransform.count == 16,
              capture.cameraIntrinsics.count == 9,
              capture.cameraImageResolution.count == 2 else {
            throw RecoveryError.invalidCaptureMetadata
        }
        // Column-major intrinsics: [fx 0 0 | 0 fy 0 | cx cy 1]. Framing uses
        // the captured sensor dimensions directly; the principal point is not
        // assumed to be the exact image center.
        let fy = capture.cameraIntrinsics[4]
        let nativeWidth = CGFloat(capture.cameraImageResolution[0])
        let nativeHeight = CGFloat(capture.cameraImageResolution[1])
        guard fy > 0, nativeWidth > 0, nativeHeight > 0 else {
            throw RecoveryError.invalidCaptureMetadata
        }
        let placements = index < 0 ? [] : Array(plan.cumulativePlacements(through: plan.steps[index]))
        let snapshot = try await engine.snapshot(placements: placements)
        let model = try RealityKitInstructionAdapter.makeEntity(from: snapshot)
        let renderWidth: CGFloat = 512
        let renderHeight = max(64, (renderWidth * nativeHeight / nativeWidth).rounded())
        let view = ARView(frame: CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight), cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.systemBackground)

        let modelAnchor = AnchorEntity(world: .zero)
        modelAnchor.transform.matrix = alignment.transform
        modelAnchor.addChild(model)
        view.scene.addAnchor(modelAnchor)

        let cameraAnchor = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        let cameraMatrix = Self.matrix(capture.cameraTransform)
        camera.transform.matrix = cameraMatrix
        // Vertical FOV in the landscape sensor frame from native intrinsics:
        // fovY = 2 * atan((nativeHeight / 2) / fy).
        let fovRadians = 2 * atan(Float(nativeHeight / 2) / fy)
        camera.camera.fieldOfViewInDegrees = min(100, max(20, fovRadians * 180 / .pi))
        let light = DirectionalLight()
        light.light.intensity = 2_500
        camera.addChild(light)
        cameraAnchor.addChild(camera)
        view.scene.addAnchor(cameraAnchor)

        let landscapeImage = try await Self.snapshot(of: view)
        let image = Self.rotate(landscapeImage, to: RecoveryFrameConvention.uprightRotation(cameraTransform: cameraMatrix))
        cache[key] = image
        return image
    }

    /// Snapshots the view, treating nil or zero-sized results as errors so a
    /// blank image is never cached or fed to the model.
    private static func snapshot(of view: ARView) async throws -> UIImage {
        let image: UIImage? = await withCheckedContinuation { continuation in
            view.snapshot(saveToHDR: false) { continuation.resume(returning: $0) }
        }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            throw RecoveryError.candidateRenderFailed
        }
        return image
    }

    /// Rotates a landscape-sensor-frame render by the same rotation the
    /// physical capture applied, baking the result to `.up` orientation.
    private static func rotate(_ image: UIImage, to orientation: CGImagePropertyOrientation) -> UIImage {
        guard orientation != .up, let cgImage = image.cgImage else { return image }
        let mapped: UIImage.Orientation
        switch orientation {
        case .up: mapped = .up
        case .down: mapped = .down
        case .left: mapped = .left
        case .right: mapped = .right
        case .upMirrored: mapped = .upMirrored
        case .downMirrored: mapped = .downMirrored
        case .leftMirrored: mapped = .leftMirrored
        case .rightMirrored: mapped = .rightMirrored
        @unknown default: mapped = .up
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: mapped).normalizedOrientation()
    }

    private static func cameraDistance(bounds: LDrawBounds?) -> Float {
        guard let bounds, bounds.minimum.count == 3, bounds.maximum.count == 3 else { return 0.35 }
        let extent = zip(bounds.minimum, bounds.maximum).map { abs($1 - $0) }.max() ?? 0.1
        return max(0.12, Float(extent) * 2.4)
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }

}

/// Thin wrapper over the shared layout in RecoveryEvidenceKit — one
/// implementation for the app and the Mac harness, pinned to exactly
/// 1024×1024 px (the previous UIKit renderer drew at screen scale, so disk
/// boards were 2–3× larger than documented; the model input was unaffected
/// because the runtime resizes to 1024 anyway).
@MainActor
enum RecoveryBoardComposer {
    static func compose(
        physicalViewURL: URL,
        candidates: [(slot: String, image: UIImage, stepNumber: Int)]
    ) throws -> URL {
        guard let physical = try? RecoveryBoardLayoutV1.loadImage(at: physicalViewURL) else {
            throw RecoveryError.captureImageMissing
        }
        let kitCandidates = try candidates.map { candidate in
            guard let cgImage = candidate.image.cgImage else {
                throw RecoveryError.captureImageMissing
            }
            return RecoveryBoardLayoutV1.Candidate(
                slot: candidate.slot,
                image: cgImage,
                stepNumber: candidate.stepNumber
            )
        }
        let board = try RecoveryBoardLayoutV1.composeBoard(physical: physical, candidates: kitCandidates)
        let root = try InstructionModelImporter.applicationSupportRoot()
        let boards = root.appendingPathComponent("InferenceBoards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let output = boards.appendingPathComponent("\(UUID().uuidString).jpg")
        try RecoveryBoardLayoutV1.writeJPEG(board, to: output)
        return output
    }
}
