import ARKit
import Foundation
import os

/// Bridges ARSession delegate callbacks (background queue) to the
/// registration tracker (an actor) as a latest-wins stream of copied depth
/// frames. Copying 256×192 depth + confidence costs ~250 KB per frame, so
/// frames are extracted only while a consumer is attached, and at a bounded
/// rate rather than the session's full frame rate.
final class RegistrationFrameRelay: @unchecked Sendable {
    /// The tracker solves at ~10 Hz; feeding it faster only wastes copies.
    private static let minimumInterval: TimeInterval = 1.0 / 15.0

    private let lock = OSAllocatedUnfairLock()
    private var continuation: AsyncStream<RegistrationFrameInput>.Continuation?
    /// Continuations are not Equatable; the generation tells a superseded
    /// stream's termination apart from the active one's so it cannot clear a
    /// replacement out from under a new consumer.
    private var generation = 0
    private var lastYieldTimestamp: TimeInterval = -.infinity

    /// One consumer at a time: starting a new stream finishes the previous
    /// one, matching the single-tracker design.
    func frames() -> AsyncStream<RegistrationFrameInput> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (previous, streamGeneration): (AsyncStream<RegistrationFrameInput>.Continuation?, Int) = lock.withLock {
                generation += 1
                let previous = self.continuation
                self.continuation = continuation
                self.lastYieldTimestamp = -.infinity
                return (previous, generation)
            }
            previous?.finish()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    if self.generation == streamGeneration {
                        self.continuation = nil
                    }
                }
            }
        }
    }

    func stop() {
        let current: AsyncStream<RegistrationFrameInput>.Continuation? = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        current?.finish()
    }

    /// Called from the ARSession delegate queue for every frame; cheap when
    /// no consumer is attached or the rate gate has not elapsed.
    func ingest(_ frame: ARFrame) {
        let shouldExtract: Bool = lock.withLock {
            guard continuation != nil else { return false }
            guard frame.timestamp - lastYieldTimestamp >= Self.minimumInterval else { return false }
            lastYieldTimestamp = frame.timestamp
            return true
        }
        guard shouldExtract, let input = Self.extract(frame) else { return }
        let current: AsyncStream<RegistrationFrameInput>.Continuation? = lock.withLock { continuation }
        current?.yield(input)
    }

    /// Copies scene depth out of an arbitrary frame — used by the recovery
    /// flow to attach a depth observation to the center capture for the
    /// geometric estimator (ADR 0010).
    static func input(from frame: ARFrame) -> RegistrationFrameInput? {
        extract(frame)
    }

    /// Copies scene depth out of the frame: the smoothed variant is the ICP
    /// tracking input (ADR 0009), the raw variant is the verifier's per-frame
    /// evidence because smoothing lags freshly placed bricks.
    private static func extract(_ frame: ARFrame) -> RegistrationFrameInput? {
        guard let smoothed = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let tracking = copy(depthData: smoothed) else { return nil }
        // Only pay for a second copy when raw depth is a distinct buffer of
        // the same geometry.
        var raw: (depth: [Float32], confidence: [UInt8])?
        if let sceneDepth = frame.sceneDepth, sceneDepth !== smoothed,
           let copied = copy(depthData: sceneDepth),
           copied.width == tracking.width, copied.height == tracking.height {
            raw = (copied.depth, copied.confidence)
        }

        // Intrinsics are expressed at the capture resolution; rescale to the
        // depth grid so projection lands in depth pixels directly.
        let imageSize = frame.camera.imageResolution
        let scaleX = Float(tracking.width) / Float(imageSize.width)
        let scaleY = Float(tracking.height) / Float(imageSize.height)
        var intrinsics = frame.camera.intrinsics
        intrinsics[0][0] *= scaleX
        intrinsics[2][0] *= scaleX
        intrinsics[1][1] *= scaleY
        intrinsics[2][1] *= scaleY

        return RegistrationFrameInput(
            depth: tracking.depth,
            confidence: tracking.confidence,
            rawDepth: raw?.depth,
            rawConfidence: raw?.confidence,
            width: tracking.width,
            height: tracking.height,
            depthIntrinsics: intrinsics,
            worldFromCamera: frame.camera.transform,
            timestamp: frame.timestamp
        )
    }

    private static func copy(
        depthData: ARDepthData
    ) -> (depth: [Float32], confidence: [UInt8], width: Int, height: Int)? {
        guard let confidenceMap = depthData.confidenceMap else { return nil }
        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              CVPixelBufferGetWidth(confidenceMap) == width,
              CVPixelBufferGetHeight(confidenceMap) == height,
              let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) else { return nil }

        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        var depth = [Float32](repeating: 0, count: width * height)
        var confidence = [UInt8](repeating: 0, count: width * height)
        let depthPointer = depthBase.assumingMemoryBound(to: Float32.self)
        let confidencePointer = confidenceBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let depthRow = depthPointer.advanced(by: row * depthStride)
            let confidenceRow = confidencePointer.advanced(by: row * confidenceStride)
            let output = row * width
            for column in 0..<width {
                depth[output + column] = depthRow[column]
                confidence[output + column] = confidenceRow[column]
            }
        }
        return (depth, confidence, width, height)
    }
}
