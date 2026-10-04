import Foundation
import Metal
import os
import simd

/// The expected-depth map for one snapshot from one camera pose: linear
/// depth in meters per pixel, `0` where no geometry projects. Pixel layout
/// matches the LiDAR depth map (same intrinsics convention), so observed and
/// expected depth compare pixelwise with no reprojection.
struct ExpectedDepthMap: Sendable {
    let depth: [Float32]
    let width: Int
    let height: Int

    func depthAt(x: Int, y: Int) -> Float32 { depth[y * width + x] }
}

/// Vertex data for one snapshot, uploaded to the GPU once and drawn by any
/// number of renders. Verification renders the same completed and delta
/// geometry on every frame, so re-packing and re-uploading it per render (as
/// the renderer used to) was pure overhead.
final class DepthGeometry: @unchecked Sendable {
    fileprivate let buffer: MTLBuffer?
    let vertexCount: Int

    fileprivate init(buffer: MTLBuffer?, vertexCount: Int) {
        self.buffer = buffer
        self.vertexCount = vertexCount
    }
}

/// One pass of a batch: which geometry, from which pose, keeping which
/// surface.
struct DepthRenderRequest: @unchecked Sendable {
    let geometry: DepthGeometry
    let viewFromModel: simd_float4x4
    var surface: ExpectedDepthRenderer.Surface = .nearest
}

/// Rasterizes an `InstructionGeometrySnapshot` to linear depth at LiDAR
/// resolution. This is the one Metal render pass the registration and
/// verification stack is allowed (ADR 0006 amendment): RealityKit exposes no
/// depth readback, so expected depth must be produced directly — and the
/// same pass renders the synthetic evaluation corpus, keeping app and eval
/// depth generation a single code path (ADR 0009).
///
/// One instance serves the process (`shared()`): the shader compiles once,
/// render targets come from a pool, and a batch of hypotheses encodes into
/// one command buffer that completes asynchronously instead of blocking the
/// caller once per render.
///
/// Camera convention matches ARKit: camera space +X right, +Y up, -Z
/// forward; intrinsics are in (already depth-scaled) pixels with image y
/// down. Depth is distance along -Z, not ray length — the same convention as
/// `ARDepthData`.
final class ExpectedDepthRenderer: @unchecked Sendable {
    enum RendererError: LocalizedError {
        case metalUnavailable
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .metalUnavailable: "Metal is unavailable on this device."
            case .renderFailed: "The expected-depth render pass failed."
            }
        }
    }

    /// Which surface the rasterizer keeps per pixel: the nearest (standard
    /// occlusion) or the farthest, whose difference against nearest is the
    /// ray span through the geometry.
    enum Surface: Sendable {
        case nearest
        case farthest
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let farthestDepthState: MTLDepthStencilState
    private let targets = TargetPool()

    private static let sharedInstance = Result { try ExpectedDepthRenderer() }

    /// The process-wide renderer. Creating it compiles the shader, so the app
    /// warms it off the main thread at launch; every verifier and recovery
    /// estimator then reuses it.
    static func shared() throws -> ExpectedDepthRenderer {
        try sharedInstance.get()
    }

    /// The shader is compiled from source so the identical pass can be
    /// linked into the iOS app and the macOS synthetic-scene CLI without
    /// duplicating a .metal build phase per target — once per process, via
    /// `shared()`.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewFromModel;
        float fx, fy, cx, cy;
        float width, height, near, far;
    };

    struct VertexOut {
        float4 position [[position]];
        float linearDepth;
    };

    vertex VertexOut expected_depth_vertex(
        const device packed_float3 *positions [[buffer(0)]],
        constant Uniforms &uniforms [[buffer(1)]],
        uint vertexID [[vertex_id]]
    ) {
        float3 model = float3(positions[vertexID]);
        float4 cameraSpace = uniforms.viewFromModel * float4(model, 1.0);
        // ARKit camera looks down -Z; depth is the positive distance along it.
        float depth = -cameraSpace.z;
        float u = uniforms.fx * cameraSpace.x / depth + uniforms.cx;
        float v = uniforms.fy * (-cameraSpace.y) / depth + uniforms.cy;
        float ndcX = (u / uniforms.width) * 2.0 - 1.0;
        float ndcY = 1.0 - (v / uniforms.height) * 2.0;
        float z01 = (depth - uniforms.near) / (uniforms.far - uniforms.near);
        VertexOut out;
        // Multiply through by depth so the rasterizer's divide restores NDC
        // with perspective-correct interpolation; points behind the camera
        // get w <= 0 and are clipped.
        out.position = float4(ndcX * depth, ndcY * depth, z01 * depth, depth);
        out.linearDepth = depth;
        return out;
    }

    fragment float expected_depth_fragment(VertexOut in [[stage_in]]) {
        return in.linearDepth;
    }
    """

    private struct Uniforms {
        var viewFromModel: simd_float4x4
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
        var width: Float
        var height: Float
        var near: Float
        var far: Float
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw RendererError.metalUnavailable
        }
        self.device = device
        self.queue = queue

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "expected_depth_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "expected_depth_fragment")
        descriptor.colorAttachments[0].pixelFormat = .r32Float
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw RendererError.metalUnavailable
        }
        self.depthState = depthState
        depthDescriptor.depthCompareFunction = .greater
        guard let farthestDepthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw RendererError.metalUnavailable
        }
        self.farthestDepthState = farthestDepthState
    }

    /// Uploads a snapshot's vertices once for any number of renders. A
    /// failed upload is not thrown here: it surfaces as `renderFailed` from
    /// the first render that draws it, exactly as a per-render upload failure
    /// used to.
    func prepare(_ snapshot: InstructionGeometrySnapshot) -> DepthGeometry {
        let vertexCount = snapshot.buffers.reduce(0) { $0 + $1.positions.count }
        guard vertexCount > 0 else { return DepthGeometry(buffer: nil, vertexCount: 0) }
        // packed_float3 layout: 12-byte stride, unlike SIMD3's 16.
        var packed = [Float32]()
        packed.reserveCapacity(vertexCount * 3)
        for buffer in snapshot.buffers {
            for vertex in buffer.positions {
                packed.append(vertex.x)
                packed.append(vertex.y)
                packed.append(vertex.z)
            }
        }
        let buffer = device.makeBuffer(bytes: packed, length: packed.count * MemoryLayout<Float32>.stride)
        return DepthGeometry(buffer: buffer, vertexCount: vertexCount)
    }

    /// Renders the snapshot's linear depth from the given camera pose.
    /// `viewFromModel` maps model-frame points into ARKit camera space;
    /// `intrinsics` must already be scaled to `width x height` (the relay
    /// delivers them that way). Blocks until the GPU finishes; hot paths use
    /// the batched `render(_:…)` instead.
    func render(
        snapshot: InstructionGeometrySnapshot,
        viewFromModel: simd_float4x4,
        intrinsics: simd_float3x3,
        width: Int,
        height: Int,
        near: Float = 0.05,
        far: Float = 5.0,
        surface: Surface = .nearest
    ) throws -> ExpectedDepthMap {
        let request = DepthRenderRequest(geometry: prepare(snapshot), viewFromModel: viewFromModel, surface: surface)
        let batch = try encode([request], intrinsics: intrinsics, width: width, height: height, near: near, far: far)
        batch.commandBuffer.commit()
        batch.commandBuffer.waitUntilCompleted()
        return try finish(batch)[0]
    }

    /// Renders every request into its own target within one command buffer
    /// and resumes when the GPU completes, without blocking a thread. Maps
    /// come back in request order and are bit-identical to rendering each
    /// request alone: same pipeline, same vertex data, same uniforms.
    func render(
        _ requests: [DepthRenderRequest],
        intrinsics: simd_float3x3,
        width: Int,
        height: Int,
        near: Float = 0.05,
        far: Float = 5.0
    ) async throws -> [ExpectedDepthMap] {
        guard !requests.isEmpty else { return [] }
        let batch = try encode(requests, intrinsics: intrinsics, width: width, height: height, near: near, far: far)
        return try await withCheckedThrowingContinuation { continuation in
            batch.commandBuffer.addCompletedHandler { [self] _ in
                continuation.resume(with: Result { try finish(batch) })
            }
            batch.commandBuffer.commit()
        }
    }

    private struct EncodedBatch: @unchecked Sendable {
        let commandBuffer: MTLCommandBuffer
        let targets: [TargetPool.Target]
        let width: Int
        let height: Int
        let signpost: OSSignpostIntervalState
    }

    private func encode(
        _ requests: [DepthRenderRequest],
        intrinsics: simd_float3x3,
        width: Int,
        height: Int,
        near: Float,
        far: Float
    ) throws -> EncodedBatch {
        guard width > 0, height > 0 else { throw RendererError.renderFailed }
        for request in requests where request.geometry.vertexCount > 0 && request.geometry.buffer == nil {
            throw RendererError.renderFailed
        }
        let signpost = GeometrySignposts.signposter.beginInterval(
            "DepthRenderBatch", id: GeometrySignposts.signposter.makeSignpostID(), "\(requests.count) passes"
        )
        let targets = try requests.map { _ in try self.targets.acquire(device: device, width: width, height: height) }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            self.targets.release(targets)
            GeometrySignposts.signposter.endInterval("DepthRenderBatch", signpost)
            throw RendererError.renderFailed
        }
        for (request, target) in zip(requests, targets) {
            var uniforms = Uniforms(
                viewFromModel: request.viewFromModel,
                fx: intrinsics[0][0],
                fy: intrinsics[1][1],
                cx: intrinsics[2][0],
                cy: intrinsics[2][1],
                width: Float(width),
                height: Float(height),
                near: near,
                far: far
            )
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target.color
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = target.depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = request.surface == .farthest ? 0 : 1
            pass.depthAttachment.storeAction = .dontCare
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                self.targets.release(targets)
                GeometrySignposts.signposter.endInterval("DepthRenderBatch", signpost)
                throw RendererError.renderFailed
            }
            // Empty geometry still clears its target, so its map is all zeros.
            if let buffer = request.geometry.buffer, request.geometry.vertexCount > 0 {
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(request.surface == .farthest ? farthestDepthState : depthState)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: request.geometry.vertexCount)
            }
            encoder.endEncoding()
        }
        return EncodedBatch(commandBuffer: commandBuffer, targets: targets, width: width, height: height, signpost: signpost)
    }

    /// Reads a completed batch back and returns its targets to the pool.
    private func finish(_ batch: EncodedBatch) throws -> [ExpectedDepthMap] {
        defer {
            targets.release(batch.targets)
            GeometrySignposts.signposter.endInterval(
                "DepthRenderBatch", batch.signpost,
                "gpu_ms=\((batch.commandBuffer.gpuEndTime - batch.commandBuffer.gpuStartTime) * 1_000)"
            )
        }
        guard batch.commandBuffer.status == .completed else { throw RendererError.renderFailed }
        return batch.targets.map { target in
            var depth = [Float32](repeating: 0, count: batch.width * batch.height)
            depth.withUnsafeMutableBytes { bytes in
                target.color.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow: batch.width * MemoryLayout<Float32>.stride,
                    from: MTLRegionMake2D(0, 0, batch.width, batch.height),
                    mipmapLevel: 0
                )
            }
            return ExpectedDepthMap(depth: depth, width: batch.width, height: batch.height)
        }
    }
}

/// Reusable render targets, keyed by size. Verification renders at the
/// LiDAR depth grid every frame, so allocating two textures per render (as
/// the renderer used to) churned the allocator for nothing.
private final class TargetPool: @unchecked Sendable {
    struct Target {
        let color: MTLTexture
        let depth: MTLTexture
        let width: Int
        let height: Int
    }

    private struct Key: Hashable {
        let width: Int
        let height: Int
    }

    /// Enough for one full verifier batch plus a recovery pass in flight.
    private static let maximumIdlePerSize = 16
    private let lock = NSLock()
    private var idle: [Key: [Target]] = [:]

    func acquire(device: MTLDevice, width: Int, height: Int) throws -> Target {
        let key = Key(width: width, height: height)
        lock.lock()
        let reused = idle[key]?.popLast()
        lock.unlock()
        if let reused { return reused }

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDescriptor),
              let depth = device.makeTexture(descriptor: depthDescriptor) else {
            throw ExpectedDepthRenderer.RendererError.renderFailed
        }
        return Target(color: color, depth: depth, width: width, height: height)
    }

    func release(_ targets: [Target]) {
        lock.lock()
        defer { lock.unlock() }
        for target in targets {
            let key = Key(width: target.width, height: target.height)
            if idle[key, default: []].count < Self.maximumIdlePerSize {
                idle[key, default: []].append(target)
            }
        }
    }
}
