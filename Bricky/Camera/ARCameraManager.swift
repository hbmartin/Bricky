import ARKit
import AVFoundation
import Combine
import Foundation
import UIKit
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

    deinit {
        // deinit is nonisolated and may run off the main thread while the
        // session is otherwise MainActor-managed, so hop instead of pausing
        // inline. The task captures only the session (never self), so it
        // cannot create a retain cycle; views also pause via stopSession()
        // in onDisappear, making this a safety net for the last release.
        let session = session
        Task { @MainActor in session.pause() }
    }

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
    ///
    /// `ARFrame.raycastQuery(from:allowing:alignment:)` takes NORMALIZED
    /// image-space coordinates in the captured image's landscape frame, so
    /// the view point is first normalized against the viewport and then
    /// mapped through the inverse of the frame's display transform.
    func unprojectToPlane(screenPoint: CGPoint, viewportSize: CGSize) -> SIMD3<Float>? {
        guard viewportSize.width > 0, viewportSize.height > 0,
              let frame = session.currentFrame,
              screenPoint.x >= 0, screenPoint.x <= viewportSize.width,
              screenPoint.y >= 0, screenPoint.y <= viewportSize.height else {
            return nil
        }
        let normalizedViewPoint = CGPoint(
            x: screenPoint.x / viewportSize.width,
            y: screenPoint.y / viewportSize.height
        )
        // displayTransform maps normalized image coordinates to normalized
        // view coordinates; invert it to go the other way.
        let displayTransform = frame.displayTransform(
            for: Self.currentInterfaceOrientation(),
            viewportSize: viewportSize
        )
        let imagePoint = normalizedViewPoint.applying(displayTransform.inverted())
        guard imagePoint.x >= 0, imagePoint.x <= 1,
              imagePoint.y >= 0, imagePoint.y <= 1 else {
            return nil
        }
        let query = frame.raycastQuery(
            from: imagePoint,
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

    private static func currentInterfaceOrientation() -> UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.interfaceOrientation ?? .portrait
    }

    private func configureSession() {
        // Re-running a live session with reset options would discard the
        // current world frame (and invalidate any placed alignment) mid-flow;
        // callers re-check permissions on every appearance, so keep this
        // idempotent while the session is running.
        guard !isSessionRunning else { return }
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
        // This fires at ~60 fps; skip the @Published write when nothing
        // changed so observing SwiftUI views are not invalidated per frame.
        Task { @MainActor [weak self] in
            guard let self, self.trackingState != tracking else { return }
            self.trackingState = tracking
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let tracking = camera.trackingState
        Task { @MainActor [weak self] in
            guard let self, self.trackingState != tracking else { return }
            self.trackingState = tracking
        }
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
