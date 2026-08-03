import SwiftUI
import ARKit
import RealityKit

/// UIViewRepresentable wrapper for ARView — used when tracking mode is `.arWorldTracking`.
/// Provides the AR camera feed with world tracking enabled.
struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        // The session is owned by ARCameraManager; RealityKit must not run
        // its own configuration over the manager's plane-detection config.
        arView.automaticallyConfigureSession = false
        arView.session = session
        arView.renderOptions = [.disablePersonOcclusion, .disableMotionBlur, .disableDepthOfField]
        // We only need the camera feed — no virtual content rendering
        arView.environment.background = .cameraFeed()
        arView.cameraMode = .ar
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Session is managed by ARCameraManager
    }
}
