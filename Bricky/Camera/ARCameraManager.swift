import ARKit
import AVFoundation
import Combine
import Foundation
import os

/// The intentionally small AR session boundary shared by alignment, guided
/// capture, and step checking. Alignment state lives elsewhere and is never
/// restored after interruption or relaunch.
@MainActor
final class ARCameraManager: NSObject, ObservableObject {
    enum CameraError: LocalizedError {
        case cameraUnavailable
        case arNotSupported
        case permissionDenied
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable:
                "The camera is not available on this device."
            case .arNotSupported:
                "ARKit world tracking is not supported on this device."
            case .permissionDenied:
                "Camera access is required for alignment and recovery. Enable it in Settings."
            case .sessionFailed(let message):
                "The AR session failed: \(message)"
            }
        }
    }

    @Published private(set) var error: CameraError?
    @Published private(set) var isSessionRunning = false
    @Published private(set) var trackingState: ARCamera.TrackingState = .notAvailable

    let session = ARSession()
    private let delegateQueue = DispatchQueue(label: AppConfig.queuePrefix + ".ar.delegate")

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue
    }

    deinit { session.pause() }

    func checkPermissions() {
        guard Self.isSupported else {
            error = .arNotSupported
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.configureSession() }
                    else { self?.error = .permissionDenied }
                }
            }
        case .denied, .restricted:
            error = .permissionDenied
        @unknown default:
            error = .cameraUnavailable
        }
    }

    func stopSession() {
        session.pause()
        isSessionRunning = false
        trackingState = .notAvailable
    }

    /// Raycasts a point expressed in the presenting AR view's coordinates.
    func unprojectToPlane(screenPoint: CGPoint, viewportSize: CGSize) -> SIMD3<Float>? {
        guard viewportSize.width > 0, viewportSize.height > 0,
              let frame = session.currentFrame,
              screenPoint.x >= 0, screenPoint.x <= viewportSize.width,
              screenPoint.y >= 0, screenPoint.y <= viewportSize.height else {
            return nil
        }
        let query = frame.raycastQuery(
            from: screenPoint,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        )
        guard let hit = session.raycast(query).first else { return nil }
        return SIMD3(
            hit.worldTransform.columns.3.x,
            hit.worldTransform.columns.3.y,
            hit.worldTransform.columns.3.z
        )
    }

    private func configureSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.isAutoFocusEnabled = true
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        error = nil
        isSessionRunning = true
    }
}

extension ARCameraManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let tracking = frame.camera.trackingState
        Task { @MainActor [weak self] in self?.trackingState = tracking }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let tracking = camera.trackingState
        Task { @MainActor [weak self] in self?.trackingState = tracking }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.trackingState = .notAvailable }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        os.Logger(subsystem: AppConfig.bundleID, category: "ARCamera")
            .error("AR session failed: \(message, privacy: .public)")
        Task { @MainActor [weak self] in
            self?.isSessionRunning = false
            self?.trackingState = .notAvailable
            self?.error = .sessionFailed(message)
        }
    }
}
