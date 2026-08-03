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
        guard capture.cameraTransform.count == 16, capture.cameraIntrinsics.count == 9 else {
            throw RecoveryError.invalidCaptureMetadata
        }
        // Column-major intrinsics: [fx 0 0 | 0 fy 0 | cx cy 1]. The principal
        // point sits at the native image center, so it doubles as the native
        // sensor half-size even though RecoveryCapture stores no dimensions.
        let fy = capture.cameraIntrinsics[4]
        let cx = CGFloat(capture.cameraIntrinsics[6])
        let cy = CGFloat(capture.cameraIntrinsics[7])
        guard fy > 0, cx > 0, cy > 0 else {
            throw RecoveryError.invalidCaptureMetadata
        }
        let placements = index < 0 ? [] : Array(plan.cumulativePlacements(through: plan.steps[index]))
        let snapshot = try await engine.snapshot(placements: placements)
        let model = try RealityKitInstructionAdapter.makeEntity(from: snapshot)
        let renderWidth: CGFloat = 512
        let renderHeight = max(64, (renderWidth * cy / cx).rounded())
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
        // fovY = 2 * atan((nativeHeight / 2) / fy), with nativeHeight / 2 = cy.
        let fovRadians = 2 * atan(Float(cy) / fy)
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

@MainActor
enum RecoveryBoardComposer {
    static func compose(
        physicalViewURL: URL,
        candidates: [(slot: String, image: UIImage, stepNumber: Int)]
    ) throws -> URL {
        guard let physical = UIImage(contentsOfFile: physicalViewURL.path) else {
            throw RecoveryError.captureImageMissing
        }
        let size = CGSize(width: 1024, height: 1024)
        let renderer = UIGraphicsImageRenderer(size: size)
        let board = renderer.image { context in
            UIColor(white: 0.06, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            drawAspectFill(physical, in: CGRect(x: 16, y: 16, width: 992, height: 420))
            let columns = 4
            let gap: CGFloat = 12
            let tileWidth = (992 - gap * 3) / 4
            let tileHeight: CGFloat = 266
            for (offset, candidate) in candidates.enumerated() {
                let row = offset / columns
                let column = offset % columns
                let frame = CGRect(
                    x: 16 + CGFloat(column) * (tileWidth + gap),
                    y: 452 + CGFloat(row) * (tileHeight + gap),
                    width: tileWidth,
                    height: tileHeight
                )
                UIColor(white: 0.14, alpha: 1).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 14).fill()
                drawAspectFit(candidate.image, in: frame.insetBy(dx: 8, dy: 30))
                let label = "\(candidate.slot) · Step \(candidate.stepNumber)"
                label.draw(
                    at: CGPoint(x: frame.minX + 10, y: frame.minY + 7),
                    withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 19, weight: .bold),
                        .foregroundColor: UIColor.white
                    ]
                )
            }
        }
        let root = try InstructionModelImporter.applicationSupportRoot()
        let boards = root.appendingPathComponent("InferenceBoards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let output = boards.appendingPathComponent("\(UUID().uuidString).jpg")
        guard let data = board.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: output, options: .atomic)
        return output
    }

    private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = CGRect(x: rect.midX - target.width / 2, y: rect.midY - target.height / 2, width: target.width, height: target.height)
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: 14).addClip()
        image.draw(in: drawRect)
        context?.restoreGState()
    }

    private static func drawAspectFit(_ image: UIImage, in rect: CGRect) {
        let scale = min(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - target.width / 2, y: rect.midY - target.height / 2, width: target.width, height: target.height))
    }
}
