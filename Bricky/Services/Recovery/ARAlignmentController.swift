import ARKit
import RealityKit
import SwiftUI

@MainActor
final class ARAlignmentController: ObservableObject {
    @Published private(set) var alignment: ARAlignment?
    @Published var guidance = "Move your device until a horizontal surface appears."

    /// Places the ghost at the raycast hit under `screenPoint`, expressed in
    /// the AR view's coordinate space of size `viewport`. Defaults to the
    /// viewport center when no explicit point is given.
    func placeGhost(manager: ARCameraManager, viewport: CGSize, screenPoint: CGPoint? = nil) {
        let center = screenPoint ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        guard let point = manager.unprojectToPlane(screenPoint: center, viewportSize: viewport) else {
            guidance = "Aim the center reticle at the build surface."
            return
        }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(point.x, point.y, point.z, 1)
        alignment = ARAlignment(id: UUID(), transform: transform, isTracking: true)
        guidance = "Drag the controls until the ghost matches the physical build."
    }

    /// Converts a safe-area-sized GeometryReader into the full-window
    /// coordinate space used by the AR overlay and its centered reticle.
    func placeGhost(manager: ARCameraManager, proxy: GeometryProxy) {
        let frame = proxy.frame(in: .global)
        let viewport = CGSize(
            width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
            height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        )
        placeGhost(
            manager: manager,
            viewport: viewport,
            screenPoint: CGPoint(x: frame.midX, y: frame.midY)
        )
    }

    func nudge(x: Float = 0, z: Float = 0, yawDegrees: Float = 0) {
        guard var alignment else { return }
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(x, 0, z, 1)
        let radians = yawDegrees * .pi / 180
        let rotation = simd_float4x4(simd_quatf(angle: radians, axis: SIMD3(0, 1, 0)))
        alignment.transform = translation * alignment.transform * rotation
        self.alignment = alignment
    }

    func reset() {
        alignment = nil
        guidance = "Place the ghost again. Alignment is intentionally never restored across launches."
    }

    func trackingLost() {
        alignment = nil
        guidance = "Tracking was lost. Re-align the model before continuing."
    }
}

struct ARInstructionOverlay: UIViewRepresentable {
    let session: ARSession
    let entity: Entity?
    let alignment: ARAlignment?
    /// When the depth-ICP tracker holds a usable pose it supersedes the
    /// manual alignment transform (ADR 0009).
    var trackedTransform: simd_float4x4?
    /// When the registration first locks, the ghost is parked on an
    /// ARAnchor-backed entity so ARKit's world-map refinements keep it
    /// stable; tracker corrections ride on top as a child transform.
    var isLocked: Bool

    init(
        session: ARSession,
        entity: Entity?,
        alignment: ARAlignment?,
        trackedTransform: simd_float4x4? = nil,
        isLocked: Bool = false
    ) {
        self.session = session
        self.entity = entity
        self.alignment = alignment
        self.trackedTransform = trackedTransform
        self.isLocked = isLocked
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        // The session is owned by ARCameraManager; RealityKit must not run
        // its own configuration over the manager's plane-detection config.
        view.automaticallyConfigureSession = false
        view.session = session
        view.environment.background = .cameraFeed()
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField]
        // Scene-mesh occlusion: already-built bricks and the tabletop hide
        // the parts of the ghost that sit behind them. The ghost itself
        // remains a solid translucent render (ADR 0008 design-around: no
        // wireframe ghost, no wireframe-to-phantom switch on completion).
        view.environment.sceneUnderstanding.options.insert(.occlusion)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        let transform = trackedTransform ?? alignment?.transform

        // Alignment removed (reset or tracking abandoned): tear down both
        // anchor kinds so the next placement starts clean in what may be a
        // brand-new world frame.
        guard let transform else {
            if let arAnchor = coordinator.arAnchor { session.remove(anchor: arAnchor) }
            coordinator.arAnchor = nil
            if let anchor = coordinator.anchor { view.scene.removeAnchor(anchor) }
            coordinator.anchor = nil
            coordinator.renderedEntity = nil
            return
        }

        // First lock: park the ghost on an ARAnchor at the tracked pose.
        if isLocked, coordinator.arAnchor == nil {
            if let anchor = coordinator.anchor { view.scene.removeAnchor(anchor) }
            coordinator.anchor = nil
            coordinator.renderedEntity = nil
            let arAnchor = ARAnchor(name: "bricky.registration", transform: transform)
            session.add(anchor: arAnchor)
            let anchored = AnchorEntity(.anchor(identifier: arAnchor.identifier))
            view.scene.addAnchor(anchored)
            coordinator.arAnchor = arAnchor
            coordinator.anchor = anchored
        }

        if coordinator.anchor == nil {
            let anchor = AnchorEntity(world: .zero)
            view.scene.addAnchor(anchor)
            coordinator.anchor = anchor
        }
        guard let anchor = coordinator.anchor else { return }

        if coordinator.renderedEntity !== entity {
            anchor.children.removeAll()
            coordinator.renderedEntity = entity
            if let entity { anchor.addChild(entity) }
        }

        if coordinator.arAnchor == nil {
            anchor.transform.matrix = transform
            // A reused entity may still carry a locked-mode correction from a
            // previous anchor; the manual path renders at the anchor alone.
            entity?.transform = Transform.identity
        } else if let entity {
            // The child correction places the ghost exactly at the tracked
            // pose regardless of where ARKit currently holds the anchor:
            // child-world = anchor-world × correction = tracked.
            let anchorWorld = anchor.transformMatrix(relativeTo: nil)
            entity.transform.matrix = simd_inverse(anchorWorld) * transform
        }
        anchor.isEnabled = true
    }

    final class Coordinator {
        var anchor: AnchorEntity?
        var arAnchor: ARAnchor?
        weak var renderedEntity: Entity?
    }
}
