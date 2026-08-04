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

    /// Copies the smoothed scene depth and its confidence out of the frame.
    /// Smoothed depth is the tracking input (ADR 0009); the verifier
    /// captures raw depth separately because smoothing lags fresh bricks.
    private static func extract(_ frame: ARFrame) -> RegistrationFrameInput? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidenceMap = sceneDepth.confidenceMap else { return nil }
        let depthMap = sceneDepth.depthMap
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

        // Intrinsics are expressed at the capture resolution; rescale to the
        // depth grid so projection lands in depth pixels directly.
        let imageSize = frame.camera.imageResolution
        let scaleX = Float(width) / Float(imageSize.width)
        let scaleY = Float(height) / Float(imageSize.height)
        var intrinsics = frame.camera.intrinsics
        intrinsics[0][0] *= scaleX
        intrinsics[2][0] *= scaleX
        intrinsics[1][1] *= scaleY
        intrinsics[2][1] *= scaleY

        return RegistrationFrameInput(
            depth: depth,
            confidence: confidence,
            width: width,
            height: height,
            depthIntrinsics: intrinsics,
            worldFromCamera: frame.camera.transform,
            timestamp: frame.timestamp
        )
    }
}
