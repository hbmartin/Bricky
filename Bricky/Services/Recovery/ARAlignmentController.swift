import ARKit
import RealityKit
import SwiftUI

@MainActor
final class ARAlignmentController: ObservableObject {
    @Published private(set) var alignment: ARAlignment?
    @Published var guidance = "Move your device until a horizontal surface appears."

    func placeGhost(manager: ARCameraManager, viewport: CGSize) {
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        guard let point = manager.unprojectToPlane(screenPoint: center, viewportSize: viewport) else {
            guidance = "Aim the center reticle at the build surface."
            return
        }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(point.x, point.y, point.z, 1)
        alignment = ARAlignment(id: UUID(), transform: transform, isTracking: true)
        guidance = "Drag the controls until the ghost matches the physical build."
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session = session
        view.environment.background = .cameraFeed()
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField]
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        if context.coordinator.renderedEntity !== entity {
            if let anchor = context.coordinator.anchor { view.scene.removeAnchor(anchor) }
            context.coordinator.anchor = nil
            context.coordinator.renderedEntity = entity
            if let entity {
                let anchor = AnchorEntity(world: .zero)
                anchor.addChild(entity)
                view.scene.addAnchor(anchor)
                context.coordinator.anchor = anchor
            }
        }
        if let transform = alignment?.transform {
            context.coordinator.anchor?.transform.matrix = transform
            context.coordinator.anchor?.isEnabled = true
        } else {
            context.coordinator.anchor?.isEnabled = false
        }
    }

    final class Coordinator {
        var anchor: AnchorEntity?
        weak var renderedEntity: Entity?
    }
}
