import AVFoundation
import Combine
import CoreImage
import UIKit
import os

/// Captures a short "sweep" recording of a subject and extracts evenly-spaced
/// frames to feed the multiview (all-angles) 3D path. The user orbits the
/// subject while a coverage ring fills; on completion the frames are downsampled
/// to a handful of views (front/left/back/right).
///
/// Device-only (the camera does not run in the simulator). Frame throttling uses
/// an `OSAllocatedUnfairLock` in the capture callback per the project's
/// concurrency rules.
@MainActor
final class VideoSweepCapture: NSObject, ObservableObject {

    @Published private(set) var isSweeping = false
    @Published private(set) var completed = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var capturedFrames: [UIImage] = []
    @Published private(set) var errorMessage: String?
    /// The most recent live frame — used by the guided still-capture flow to
    /// grab a shot on the shutter tap. Updated continuously while the session
    /// runs, independent of an active sweep.
    @Published private(set) var latestFrame: UIImage?

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "\(AppConfig.queuePrefix).setforge.sweep")
    private let ciContext = CIContext(options: nil)
    private var lastIngest = Date.distantPast
    private var configured = false

    /// A soft target used only to fill the coverage ring — the sweep never ends
    /// automatically; the user taps Finish when they've captured every side.
    private let softTargetFrames = 16
    /// The user can't finish until at least this many views are captured, so a
    /// scan always has enough angles for a 3D model.
    let minFramesToFinish = 4
    /// Minimum spacing between kept frames.
    private let captureInterval: TimeInterval = 0.35

    /// Nonisolated throttle timestamp for the capture callback.
    private let throttle = OSAllocatedUnfairLock(initialState: Date.distantPast)

    /// Whether enough views have been captured for the user to end the sweep.
    var canFinish: Bool { frameCount >= minFramesToFinish }

    var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    // MARK: - Session lifecycle

    private func configure() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    func start() {
        configure()
        let session = self.session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    // MARK: - Sweep

    func startSweep() {
        capturedFrames = []
        frameCount = 0
        progress = 0
        completed = false
        errorMessage = nil
        lastIngest = .distantPast
        throttle.withLock { $0 = .distantPast }
        isSweeping = true
    }

    func cancelSweep() {
        isSweeping = false
    }

    /// Ends the sweep at the user's request. No-op until enough views exist.
    func finishSweep() {
        guard isSweeping, canFinish else { return }
        isSweeping = false
        completed = true
    }

    /// The frames chosen to send to the multiview model.
    func selectedViews(_ count: Int = 4) -> [UIImage] {
        Self.selectViews(from: capturedFrames, count: count)
    }

    /// Evenly-spaced downselect of the captured frames (pure, testable).
    static func selectViews(from frames: [UIImage], count: Int = 4) -> [UIImage] {
        guard frames.count > count else { return frames }
        var picked: [UIImage] = []
        for i in 0..<count {
            let idx = Int((Double(i) / Double(count - 1)) * Double(frames.count - 1))
            picked.append(frames[idx])
        }
        return picked
    }

    // MARK: - Ingest (main actor)

    private func ingest(_ image: UIImage) {
        // Always keep the newest frame for guided still capture.
        latestFrame = image
        guard isSweeping else { return }
        let now = Date()
        guard now.timeIntervalSince(lastIngest) >= captureInterval else { return }
        lastIngest = now
        capturedFrames.append(image)
        frameCount = capturedFrames.count
        // The ring reflects coverage toward a soft target but never auto-ends —
        // the user decides when every side has been captured.
        progress = min(1, Double(frameCount) / Double(softTargetFrames))
    }

    private func makeImage(from sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        // Back camera sample buffers are landscape-right; rotate to portrait.
        return UIImage(cgImage: cg, scale: 1, orientation: .right)
    }
}

extension VideoSweepCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        let shouldKeep = throttle.withLock { last -> Bool in
            if now.timeIntervalSince(last) >= 0.33 {
                last = now
                return true
            }
            return false
        }
        guard shouldKeep else { return }
        // Copy the buffer's image out on the capture queue, then hop to main.
        let sendable = SendableSampleBuffer(sampleBuffer)
        Task { @MainActor in
            if let image = self.makeImage(from: sendable.buffer) {
                self.ingest(image)
            }
        }
    }
}

/// Wraps a `CMSampleBuffer` so it can cross the actor boundary. The buffer is
/// only read (converted to a UIImage) on the main actor immediately after.
private struct SendableSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
    init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}
