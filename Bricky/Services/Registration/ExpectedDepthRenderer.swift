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

/// The colour code of the surface each pixel sees, from the tag pass
/// (M3.1): LDraw code + 1, and `0` where no geometry projects. The offset
/// keeps LDraw 0 (Black) distinct from background.
struct ExpectedTagMap: Sendable {
    let tags: [UInt32]
    let width: Int
    let height: Int

    /// The LDraw colour code at `index`, or nil for background.
    func colourCode(at index: Int) -> Int? {
        tags[index] == 0 ? nil : Int(tags[index]) - 1
    }
}

/// Vertex data for one snapshot, uploaded to the GPU once and drawn by any
/// number of renders. Verification renders the same completed and delta
/// geometry on every frame, so re-packing and re-uploading it per render (as
/// the renderer used to) was pure overhead.
final class DepthGeometry: @unchecked Sendable {
    fileprivate let buffer: MTLBuffer?
    /// Per-vertex colour tags (code + 1) for the tag pass, built eagerly by
    /// `prepare(_:tagged: true)` so the geometry stays immutable.
    fileprivate let tagBuffer: MTLBuffer?
    let vertexCount: Int
    let isTagged: Bool

    fileprivate init(buffer: MTLBuffer?, vertexCount: Int, tagBuffer: MTLBuffer? = nil, isTagged: Bool = false) {
        self.buffer = buffer
        self.vertexCount = vertexCount
        self.tagBuffer = tagBuffer
        self.isTagged = isTagged
    }
}

/// One pass of a batch: which geometry, from which pose, keeping which
/// surface.
struct DepthRenderRequest: @unchecked Sendable {
    let geometry: DepthGeometry
    let viewFromModel: simd_float4x4
    var surface: ExpectedDepthRenderer.Surface = .nearest
    /// Vertex ranges to draw, each its own draw call in the same pass. Nil
    /// draws all of `geometry`, exactly as before ranges existed; an empty
    /// list draws nothing. Meaningful on geometry prepared from
    /// `SegmentedGeometry`, whose ranges are placements (M2.0).
    var ranges: [Range<Int>]? = nil
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
    /// Built beside the depth pipeline but never in its way: a tag shader
    /// that fails to compile fails tag renders only, not `init`.
    private let tagPipeline: Result<MTLRenderPipelineState, Error>
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

    /// The tag pass (M3.1): the same projection, writing each vertex's
    /// colour tag to an R32Uint target instead of depth. A separate library
    /// and pipeline, so the depth shader above and its outputs never change.
    private static let tagShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewFromModel;
        float fx, fy, cx, cy;
        float width, height, near, far;
    };

    struct TagVertexOut {
        float4 position [[position]];
        uint tag [[flat]];
    };

    vertex TagVertexOut expected_tag_vertex(
        const device packed_float3 *positions [[buffer(0)]],
        constant Uniforms &uniforms [[buffer(1)]],
        const device uint *tags [[buffer(2)]],
        uint vertexID [[vertex_id]]
    ) {
        float3 model = float3(positions[vertexID]);
        float4 cameraSpace = uniforms.viewFromModel * float4(model, 1.0);
        float depth = -cameraSpace.z;
        float u = uniforms.fx * cameraSpace.x / depth + uniforms.cx;
        float v = uniforms.fy * (-cameraSpace.y) / depth + uniforms.cy;
        float ndcX = (u / uniforms.width) * 2.0 - 1.0;
        float ndcY = 1.0 - (v / uniforms.height) * 2.0;
        float z01 = (depth - uniforms.near) / (uniforms.far - uniforms.near);
        TagVertexOut out;
        out.position = float4(ndcX * depth, ndcY * depth, z01 * depth, depth);
        out.tag = tags[vertexID];
        return out;
    }

    fragment uint expected_tag_fragment(TagVertexOut in [[stage_in]]) {
        return in.tag;
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
        tagPipeline = Result {
            let tagLibrary = try device.makeLibrary(source: Self.tagShaderSource, options: nil)
            let tagDescriptor = MTLRenderPipelineDescriptor()
            tagDescriptor.vertexFunction = tagLibrary.makeFunction(name: "expected_tag_vertex")
            tagDescriptor.fragmentFunction = tagLibrary.makeFunction(name: "expected_tag_fragment")
            tagDescriptor.colorAttachments[0].pixelFormat = .r32Uint
            tagDescriptor.depthAttachmentPixelFormat = .depth32Float
            return try device.makeRenderPipelineState(descriptor: tagDescriptor)
        }

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
        prepare(snapshot, tagged: false)
    }

    /// As `prepare(_:)`, and with `tagged` also uploads each vertex's colour
    /// tag (its buffer's code + 1) for the tag pass.
    func prepare(_ snapshot: InstructionGeometrySnapshot, tagged: Bool) -> DepthGeometry {
        let vertexCount = snapshot.buffers.reduce(0) { $0 + $1.positions.count }
        guard vertexCount > 0 else { return DepthGeometry(buffer: nil, vertexCount: 0, isTagged: tagged) }
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
        guard tagged else { return DepthGeometry(buffer: buffer, vertexCount: vertexCount) }
        var tags = [UInt32]()
        tags.reserveCapacity(vertexCount)
        for geometryBuffer in snapshot.buffers {
            tags.append(contentsOf: repeatElement(Self.tag(for: geometryBuffer.colorCode), count: geometryBuffer.positions.count))
        }
        return DepthGeometry(buffer: buffer, vertexCount: vertexCount, tagBuffer: makeTagBuffer(tags), isTagged: true)
    }

    /// Uploads segmented geometry in timeline order, so placement vertex
    /// ranges index straight into it. Only new per-placement code draws
    /// this layout: existing consumers keep colour-merged geometry, whose
    /// draw order they were validated on.
    func prepare(_ segments: SegmentedGeometry) -> DepthGeometry {
        prepare(segments, tagged: false)
    }

    /// As `prepare(_:)`, and with `tagged` also uploads each vertex's colour
    /// tag (its triangle's code + 1), so placement ranges draw tags too.
    func prepare(_ segments: SegmentedGeometry, tagged: Bool) -> DepthGeometry {
        guard segments.vertexCount > 0 else { return DepthGeometry(buffer: nil, vertexCount: 0, isTagged: tagged) }
        var packed = [Float32]()
        packed.reserveCapacity(segments.vertexCount * 3)
        for vertex in segments.positions {
            packed.append(vertex.x)
            packed.append(vertex.y)
            packed.append(vertex.z)
        }
        let buffer = device.makeBuffer(bytes: packed, length: packed.count * MemoryLayout<Float32>.stride)
        guard tagged else { return DepthGeometry(buffer: buffer, vertexCount: segments.vertexCount) }
        var tags = [UInt32]()
        tags.reserveCapacity(segments.vertexCount)
        for code in segments.triangleColours {
            tags.append(contentsOf: repeatElement(Self.tag(for: code), count: 3))
        }
        // Triangle soup: three vertices per triangle, so the counts agree;
        // pad defensively rather than read past the buffer.
        if tags.count < segments.vertexCount {
            tags.append(contentsOf: repeatElement(0, count: segments.vertexCount - tags.count))
        }
        return DepthGeometry(
            buffer: buffer, vertexCount: segments.vertexCount,
            tagBuffer: makeTagBuffer(Array(tags.prefix(segments.vertexCount))), isTagged: true
        )
    }

    /// Code + 1, so LDraw 0 (Black) is not background. Direct colours
    /// (`0x2RRGGBB`) fit; a negative code, which LDraw never assigns, reads
    /// as background rather than as a colour.
    static func tag(for colourCode: Int) -> UInt32 {
        colourCode < 0 ? 0 : UInt32(clamping: colourCode + 1)
    }

    private func makeTagBuffer(_ tags: [UInt32]) -> MTLBuffer? {
        device.makeBuffer(bytes: tags, length: tags.count * MemoryLayout<UInt32>.stride)
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

    /// Renders depth `requests` and colour-tag `tags` requests into one
    /// command buffer. The depth maps are bit-identical to rendering the
    /// depth requests alone: same pipeline, same data, own targets. Tag
    /// requests need geometry prepared with `tagged: true`.
    func render(
        _ requests: [DepthRenderRequest],
        tags: [DepthRenderRequest],
        intrinsics: simd_float3x3,
        width: Int,
        height: Int,
        near: Float = 0.05,
        far: Float = 5.0
    ) async throws -> (depth: [ExpectedDepthMap], tags: [ExpectedTagMap]) {
        guard !requests.isEmpty || !tags.isEmpty else { return ([], []) }
        let batch = try encode(requests, tagRequests: tags, intrinsics: intrinsics, width: width, height: height, near: near, far: far)
        return try await withCheckedThrowingContinuation { continuation in
            batch.commandBuffer.addCompletedHandler { [self] _ in
                continuation.resume(with: Result {
                    // Tags are read before `finish` returns every target to
                    // the pool, where another batch could reuse it.
                    let tags = batch.commandBuffer.status == .completed ? readTags(batch) : []
                    let depth = try finish(batch)
                    return (depth, tags)
                })
            }
            batch.commandBuffer.commit()
        }
    }

    private struct EncodedBatch: @unchecked Sendable {
        let commandBuffer: MTLCommandBuffer
        let targets: [TargetPool.Target]
        var tagTargets: [TargetPool.Target] = []
        let width: Int
        let height: Int
        let signpost: OSSignpostIntervalState
    }

    private func encode(
        _ requests: [DepthRenderRequest],
        tagRequests: [DepthRenderRequest] = [],
        intrinsics: simd_float3x3,
        width: Int,
        height: Int,
        near: Float,
        far: Float
    ) throws -> EncodedBatch {
        guard width > 0, height > 0 else { throw RendererError.renderFailed }
        for request in requests + tagRequests where request.geometry.vertexCount > 0 && request.geometry.buffer == nil {
            throw RendererError.renderFailed
        }
        // A tag request needs its tags uploaded.
        for request in tagRequests where !request.geometry.isTagged
            || (request.geometry.vertexCount > 0 && request.geometry.tagBuffer == nil) {
            throw RendererError.renderFailed
        }
        // A range outside the geometry would read past the vertex buffer.
        for request in requests + tagRequests {
            for range in request.ranges ?? [] where range.lowerBound < 0 || range.upperBound > request.geometry.vertexCount {
                throw RendererError.renderFailed
            }
        }
        let tagPipelineState: MTLRenderPipelineState? = tagRequests.isEmpty ? nil : try tagPipeline.get()
        let signpost = GeometrySignposts.signposter.beginInterval(
            "DepthRenderBatch", id: GeometrySignposts.signposter.makeSignpostID(), "\(requests.count + tagRequests.count) passes"
        )
        let targets = try requests.map { _ in try self.targets.acquire(device: device, width: width, height: height) }
        let tagTargets: [TargetPool.Target]
        do {
            tagTargets = try tagRequests.map { _ in
                try self.targets.acquire(device: device, width: width, height: height, format: .r32Uint)
            }
        } catch {
            self.targets.release(targets)
            GeometrySignposts.signposter.endInterval("DepthRenderBatch", signpost)
            throw error
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            self.targets.release(targets + tagTargets)
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
                self.targets.release(targets + tagTargets)
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
                if let ranges = request.ranges {
                    for range in ranges where !range.isEmpty {
                        encoder.drawPrimitives(type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count)
                    }
                } else {
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: request.geometry.vertexCount)
                }
            }
            encoder.endEncoding()
        }
        if let tagPipelineState {
            for (request, target) in zip(tagRequests, tagTargets) {
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
                    self.targets.release(targets + tagTargets)
                    GeometrySignposts.signposter.endInterval("DepthRenderBatch", signpost)
                    throw RendererError.renderFailed
                }
                if let buffer = request.geometry.buffer, let tagBuffer = request.geometry.tagBuffer,
                   request.geometry.vertexCount > 0 {
                    encoder.setRenderPipelineState(tagPipelineState)
                    encoder.setDepthStencilState(request.surface == .farthest ? farthestDepthState : depthState)
                    encoder.setCullMode(.none)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setVertexBuffer(tagBuffer, offset: 0, index: 2)
                    if let ranges = request.ranges {
                        for range in ranges where !range.isEmpty {
                            encoder.drawPrimitives(type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count)
                        }
                    } else {
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: request.geometry.vertexCount)
                    }
                }
                encoder.endEncoding()
            }
        }
        return EncodedBatch(
            commandBuffer: commandBuffer, targets: targets, tagTargets: tagTargets,
            width: width, height: height, signpost: signpost
        )
    }

    /// Reads a completed batch back and returns its targets to the pool.
    private func finish(_ batch: EncodedBatch) throws -> [ExpectedDepthMap] {
        defer {
            targets.release(batch.targets + batch.tagTargets)
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

    /// Reads a completed batch's tag targets; the caller reads them before
    /// `finish` releases them back to the pool.
    private func readTags(_ batch: EncodedBatch) -> [ExpectedTagMap] {
        batch.tagTargets.map { target in
            var tags = [UInt32](repeating: 0, count: batch.width * batch.height)
            tags.withUnsafeMutableBytes { bytes in
                target.color.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow: batch.width * MemoryLayout<UInt32>.stride,
                    from: MTLRegionMake2D(0, 0, batch.width, batch.height),
                    mipmapLevel: 0
                )
            }
            return ExpectedTagMap(tags: tags, width: batch.width, height: batch.height)
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
        let format: MTLPixelFormat
    }

    private struct Key: Hashable {
        let width: Int
        let height: Int
        /// Depth targets carry `.r32Float`, tag targets `.r32Uint`.
        let format: MTLPixelFormat
    }

    /// Enough for one full verifier batch plus a recovery pass in flight.
    private static let maximumIdlePerSize = 16
    private let lock = NSLock()
    private var idle: [Key: [Target]] = [:]

    func acquire(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat = .r32Float) throws -> Target {
        let key = Key(width: width, height: height, format: format)
        lock.lock()
        let reused = idle[key]?.popLast()
        lock.unlock()
        if let reused { return reused }

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
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
        return Target(color: color, depth: depth, width: width, height: height, format: format)
    }

    func release(_ targets: [Target]) {
        lock.lock()
        defer { lock.unlock() }
        for target in targets {
            let key = Key(width: target.width, height: target.height, format: target.format)
            if idle[key, default: []].count < Self.maximumIdlePerSize {
                idle[key, default: []].append(target)
            }
        }
    }
}
