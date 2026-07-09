import Foundation
import ModelIO
import simd

/// Turns a 3D mesh into a colored `VoxelModel` for Set Forge.
///
/// This is the shared adapter for *every* real-3D source: Apple Object Capture
/// output (USDZ), hosted image/text-to-3D API meshes (glTF/USDZ), or a user's
/// own imported model. Any of them → `MeshVoxelizer` → `SetForgeEngine`.
///
/// Algorithm: **solid voxelization by vertical ray parity.** For each `(x, z)`
/// grid column, we intersect a vertical ray against every triangle (using
/// barycentric coordinates in the X–Z projection), sort the hit heights, and
/// fill the voxels between entry/exit pairs. This yields a *solid* model (not a
/// hollow shell), so it survives the engine's gravity-settle pass and is
/// physically buildable. Colors are interpolated from the triangle's vertex
/// colors at the entry hit and snapped to the LEGO palette.
enum MeshVoxelizer {

    enum VoxelizeError: LocalizedError {
        case emptyMesh
        case unreadableAsset
        case noSolid

        var errorDescription: String? {
            switch self {
            case .emptyMesh, .noSolid:
                return "That model didn't contain a solid shape to build."
            case .unreadableAsset:
                return "That 3D model couldn't be read. Try a .usdz or .obj file."
            }
        }
    }

    /// A single mesh triangle with per-vertex RGB colors (components 0…1).
    struct Triangle {
        var p0: SIMD3<Float>
        var p1: SIMD3<Float>
        var p2: SIMD3<Float>
        var c0: SIMD3<Float>
        var c1: SIMD3<Float>
        var c2: SIMD3<Float>
    }

    // MARK: - Core (pure, testable)

    /// Voxelize a triangle soup into a colored model.
    static func voxelize(
        triangles: [Triangle],
        size: VoxelModel.Size,
        subject: String,
        source: VoxelModel.Source = .photo
    ) throws -> VoxelModel {
        guard !triangles.isEmpty else { throw VoxelizeError.emptyMesh }

        // 1. Bounds.
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for t in triangles {
            for p in [t.p0, t.p1, t.p2] {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        let extent = hi - lo
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        guard maxExtent > 0 else { throw VoxelizeError.noSolid }

        // 2. Grid resolution: longest axis == size.maxDimension.
        let maxDim = size.maxDimension
        let voxel = maxExtent / Float(maxDim)
        let gw = max(1, Int((extent.x / voxel).rounded(.up)))
        let gh = max(1, Int((extent.y / voxel).rounded(.up)))
        let gd = max(1, Int((extent.z / voxel).rounded(.up)))

        // 3. Solid voxelization per (x, z) column.
        struct Hit { let y: Float; let color: SIMD3<Float> }
        var voxels: [Voxel] = []
        voxels.reserveCapacity(gw * gd * 4)

        for ix in 0..<gw {
            let wx = lo.x + (Float(ix) + 0.5) * voxel
            for iz in 0..<gd {
                let wz = lo.z + (Float(iz) + 0.5) * voxel

                var hits: [Hit] = []
                for t in triangles {
                    if let hit = columnHit(wx: wx, wz: wz, t: t) {
                        hits.append(Hit(y: hit.y, color: hit.color))
                    }
                }
                guard hits.count >= 2 else { continue }
                hits.sort { $0.y < $1.y }

                // Merge coincident hits (e.g. two triangles sharing a face edge,
                // or coplanar faces) so ray parity stays correct.
                var merged: [Hit] = []
                let mergeEps = voxel * 0.5
                for h in hits {
                    if let last = merged.last, abs(h.y - last.y) < mergeEps { continue }
                    merged.append(h)
                }
                guard merged.count >= 2 else { continue }

                // Fill spans between consecutive entry/exit pairs.
                var pair = 0
                while pair + 1 < merged.count {
                    let entry = merged[pair]
                    let exit = merged[pair + 1]
                    let jLo = Int(((entry.y - lo.y) / voxel).rounded(.down))
                    let jHi = Int(((exit.y - lo.y) / voxel).rounded(.down))
                    if jHi >= jLo {
                        let color = legoColor(entry.color)
                        for j in max(0, jLo)...min(gh - 1, jHi) where j >= 0 {
                            voxels.append(Voxel(x: ix, y: j, z: iz, color: color))
                        }
                    }
                    pair += 2
                }
            }
        }

        guard !voxels.isEmpty else { throw VoxelizeError.noSolid }

        // Deduplicate coincident voxels (overlapping spans).
        var seen = Set<Int>()
        var unique: [Voxel] = []
        unique.reserveCapacity(voxels.count)
        for v in voxels {
            let key = VoxelModel.key(v.x, v.y, v.z)
            if seen.insert(key).inserted { unique.append(v) }
        }

        return VoxelModel(
            width: gw, height: gh, depth: gd,
            voxels: unique, source: source, subject: subject
        )
    }

    // MARK: - ModelIO loader

    /// Voxelize a 3D model file (`.usdz`, `.obj`, `.ply`, …) via Model I/O.
    static func voxelize(
        assetURL: URL,
        size: VoxelModel.Size,
        subject: String
    ) throws -> VoxelModel {
        let asset = MDLAsset(url: assetURL)
        let triangles = extractTriangles(from: asset)
        guard !triangles.isEmpty else { throw VoxelizeError.unreadableAsset }
        return try voxelize(triangles: triangles, size: size, subject: subject)
    }

    // MARK: - Geometry helpers

    /// Vertical-ray/triangle intersection using barycentric coordinates in the
    /// X–Z projection. Returns the hit height and interpolated color, or nil if
    /// the column misses the triangle (or it is edge-on).
    private static func columnHit(
        wx: Float, wz: Float, t: Triangle
    ) -> (y: Float, color: SIMD3<Float>)? {
        let ax = t.p0.x, az = t.p0.z
        let bx = t.p1.x, bz = t.p1.z
        let cx = t.p2.x, cz = t.p2.z

        let denom = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        if abs(denom) < 1e-9 { return nil } // edge-on triangle

        let u = ((bz - cz) * (wx - cx) + (cx - bx) * (wz - cz)) / denom
        let v = ((cz - az) * (wx - cx) + (ax - cx) * (wz - cz)) / denom
        let w = 1 - u - v
        let eps: Float = -1e-4
        guard u >= eps, v >= eps, w >= eps else { return nil }

        let y = u * t.p0.y + v * t.p1.y + w * t.p2.y
        let color = u * t.c0 + v * t.c1 + w * t.c2
        return (y, color)
    }

    private static func legoColor(_ rgb: SIMD3<Float>) -> LegoColor {
        let r = UInt8(max(0, min(255, rgb.x * 255)))
        let g = UInt8(max(0, min(255, rgb.y * 255)))
        let b = UInt8(max(0, min(255, rgb.z * 255)))
        return LegoColor.closest(r: r, g: g, b: b, excludeTransparent: true)?.color ?? .gray
    }

    /// Extract world-space triangles (with best-available vertex colors) from an
    /// MDLAsset. Falls back to each submesh's material base colour, then gray.
    private static func extractTriangles(from asset: MDLAsset) -> [Triangle] {
        var triangles: [Triangle] = []
        asset.loadTextures()

        for index in 0..<asset.count {
            guard let mesh = asset.object(at: index) as? MDLMesh else { continue }
            appendTriangles(from: mesh, into: &triangles)
            // Also descend into children (USDZ scene graphs nest meshes).
            collectChildMeshes(mesh, into: &triangles)
        }
        return triangles
    }

    private static func collectChildMeshes(_ object: MDLObject, into triangles: inout [Triangle]) {
        for child in object.children.objects {
            if let mesh = child as? MDLMesh {
                appendTriangles(from: mesh, into: &triangles)
            }
            collectChildMeshes(child, into: &triangles)
        }
    }

    private static func appendTriangles(from mesh: MDLMesh, into triangles: inout [Triangle]) {
        guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition) else {
            return
        }
        let vertexCount = mesh.vertexCount
        let stride = positions.stride
        let base = positions.dataStart

        func position(_ i: Int) -> SIMD3<Float> {
            let ptr = base.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
            return SIMD3<Float>(ptr[0], ptr[1], ptr[2])
        }

        // Optional per-vertex color.
        let colorData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeColor)
        func color(_ i: Int, fallback: SIMD3<Float>) -> SIMD3<Float> {
            guard let colorData else { return fallback }
            let ptr = colorData.dataStart.advanced(by: i * colorData.stride)
                .assumingMemoryBound(to: Float.self)
            return SIMD3<Float>(ptr[0], ptr[1], ptr[2])
        }

        guard let submeshes = mesh.submeshes as? [MDLSubmesh] else { return }
        for submesh in submeshes {
            let fallback = baseColor(of: submesh.material) ?? SIMD3<Float>(0.6, 0.6, 0.6)
            let indexCount = submesh.indexCount
            guard indexCount >= 3 else { continue }
            let buffer = submesh.indexBuffer.map().bytes

            func vertexIndex(_ i: Int) -> Int {
                switch submesh.indexType {
                case .uInt16:
                    return Int(buffer.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee)
                case .uInt32:
                    return Int(buffer.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee)
                case .uInt8:
                    return Int(buffer.advanced(by: i).assumingMemoryBound(to: UInt8.self).pointee)
                default:
                    return Int(buffer.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee)
                }
            }

            var i = 0
            while i + 2 < indexCount {
                let a = vertexIndex(i), b = vertexIndex(i + 1), c = vertexIndex(i + 2)
                if a < vertexCount, b < vertexCount, c < vertexCount {
                    triangles.append(Triangle(
                        p0: position(a), p1: position(b), p2: position(c),
                        c0: color(a, fallback: fallback),
                        c1: color(b, fallback: fallback),
                        c2: color(c, fallback: fallback)
                    ))
                }
                i += 3
            }
        }
    }

    private static func baseColor(of material: MDLMaterial?) -> SIMD3<Float>? {
        guard let property = material?.property(with: .baseColor) else { return nil }
        if property.type == .float3 {
            let c = property.float3Value
            return SIMD3<Float>(c.x, c.y, c.z)
        }
        if property.type == .color, let cg = property.color,
           let comps = cg.components, comps.count >= 3 {
            return SIMD3<Float>(Float(comps[0]), Float(comps[1]), Float(comps[2]))
        }
        return nil
    }
}
