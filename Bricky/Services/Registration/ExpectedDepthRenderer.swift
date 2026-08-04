import Foundation
import Metal
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

/// Rasterizes an `InstructionGeometrySnapshot` to linear depth at LiDAR
/// resolution. This is the one Metal render pass the registration and
/// verification stack is allowed (ADR 0006 amendment): RealityKit exposes no
/// depth readback, so expected depth must be produced directly — and the
/// same pass renders the synthetic evaluation corpus, keeping app and eval
/// depth generation a single code path (ADR 0009).
///
/// Camera convention matches ARKit: camera space +X right, +Y up, -Z
/// forward; intrinsics are in (already depth-scaled) pixels with image y
/// down. Depth is distance along -Z, not ray length — the same convention as
/// `ARDepthData`.
final class ExpectedDepthRenderer {
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

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    /// The shader is compiled from source at init so the identical pass can
    /// be linked into the iOS app and the macOS synthetic-scene CLI without
    /// duplicating a .metal build phase per target.
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
    }

    /// Renders the snapshot's linear depth from the given camera pose.
    /// `viewFromModel` maps model-frame points into ARKit camera space;
    /// `intrinsics` must already be scaled to `width x height` (the relay
    /// delivers them that way).
    func render(
        snapshot: InstructionGeometrySnapshot,
        viewFromModel: simd_float4x4,
        intrinsics: simd_float3x3,
        width: Int,
        height: Int,
        near: Float = 0.05,
        far: Float = 5.0
    ) throws -> ExpectedDepthMap {
        var vertices: [SIMD3<Float>] = []
        for buffer in snapshot.buffers {
            vertices.append(contentsOf: buffer.positions)
        }
        guard !vertices.isEmpty else {
            return ExpectedDepthMap(depth: .init(repeating: 0, count: width * height), width: width, height: height)
        }

        // packed_float3 layout: 12-byte stride, unlike SIMD3's 16.
        var packed = [Float32]()
        packed.reserveCapacity(vertices.count * 3)
        for vertex in vertices {
            packed.append(vertex.x)
            packed.append(vertex.y)
            packed.append(vertex.z)
        }

        guard let vertexBuffer = device.makeBuffer(
            bytes: packed,
            length: packed.count * MemoryLayout<Float32>.stride
        ) else { throw RendererError.renderFailed }

        var uniforms = Uniforms(
            viewFromModel: viewFromModel,
            fx: intrinsics[0][0],
            fy: intrinsics[1][1],
            cx: intrinsics[2][0],
            cy: intrinsics[2][1],
            width: Float(width),
            height: Float(height),
            near: near,
            far: far
        )

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
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor),
              let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
            throw RendererError.renderFailed
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.renderFailed
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw RendererError.renderFailed }

        var depth = [Float32](repeating: 0, count: width * height)
        depth.withUnsafeMutableBytes { bytes in
            colorTexture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float32>.stride,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return ExpectedDepthMap(depth: depth, width: width, height: height)
    }
}
