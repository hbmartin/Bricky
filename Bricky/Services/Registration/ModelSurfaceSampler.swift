import Foundation
import simd

/// Converts a cumulative geometry snapshot (triangle soup in meters) into the
/// oriented point sample ICP fits against: area-weighted samples on every
/// triangle, deduplicated on a voxel grid at the target spacing, capped by
/// stratified thinning. Sampling is deterministic — a golden-ratio
/// low-discrepancy sequence seeded by triangle index — so the same snapshot
/// always yields the same sample, which keeps tracker behavior reproducible
/// in tests and evaluation.
enum ModelSurfaceSampler {
    static let defaultSpacing: Float = 0.003
    static let defaultMaxPoints = 12_000

    static func sample(
        _ snapshot: InstructionGeometrySnapshot,
        stepIndex: Int,
        targetSpacing: Float = defaultSpacing,
        maxPoints: Int = defaultMaxPoints
    ) -> ModelSurfaceSample {
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colorCodes: [Int] = []
        var occupied = Set<VoxelKey>()
        let inverseSpacing = 1 / targetSpacing
        let densityPerArea = inverseSpacing * inverseSpacing

        var triangleIndex = 0
        for buffer in snapshot.buffers {
            var vertex = 0
            while vertex + 2 < buffer.positions.count {
                let a = buffer.positions[vertex]
                let b = buffer.positions[vertex + 1]
                let c = buffer.positions[vertex + 2]
                let normal = buffer.normals[vertex]
                vertex += 3
                triangleIndex += 1

                let area = length(cross(b - a, c - a)) / 2
                guard area > 0 else { continue }
                // At least one sample per triangle so thin geometry (tiles,
                // panels) is never dropped entirely.
                let count = max(1, Int((area * densityPerArea).rounded()))
                let phase = Float(triangleIndex % 1024) / 1024

                for sampleIndex in 0..<count {
                    let sequence = Float(sampleIndex + 1)
                    let r1 = (sequence * 0.7548776662 + phase).truncatingRemainder(dividingBy: 1)
                    let r2 = (sequence * 0.5698402910 + phase).truncatingRemainder(dividingBy: 1)
                    // sqrt trick: uniform barycentric coordinates.
                    let su = sqrt(r1)
                    let u = 1 - su
                    let v = r2 * su
                    let point = a * u + b * v + c * (1 - u - v)
                    guard let key = VoxelKey(point: point, inverseSpacing: inverseSpacing) else { continue }
                    guard occupied.insert(key).inserted else { continue }
                    points.append(point)
                    normals.append(normal)
                    colorCodes.append(buffer.colorCode)
                }
            }
        }

        if points.count > maxPoints {
            // Stratified thinning preserves spatial spread because insertion
            // order interleaves triangles across the whole model.
            let stride = Float(points.count) / Float(maxPoints)
            var thinnedPoints: [SIMD3<Float>] = []
            var thinnedNormals: [SIMD3<Float>] = []
            var thinnedColors: [Int] = []
            thinnedPoints.reserveCapacity(maxPoints)
            thinnedNormals.reserveCapacity(maxPoints)
            thinnedColors.reserveCapacity(maxPoints)
            for index in 0..<maxPoints {
                let source = Int(Float(index) * stride)
                thinnedPoints.append(points[source])
                thinnedNormals.append(normals[source])
                thinnedColors.append(colorCodes[source])
            }
            points = thinnedPoints
            normals = thinnedNormals
            colorCodes = thinnedColors
        }

        return ModelSurfaceSample(
            points: points,
            normals: normals,
            colorCodes: colorCodes,
            stepIndex: stepIndex
        )
    }

    private struct VoxelKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32

        init?(point: SIMD3<Float>, inverseSpacing: Float) {
            guard let x = Self.index(point.x * inverseSpacing),
                  let y = Self.index(point.y * inverseSpacing),
                  let z = Self.index(point.z * inverseSpacing) else { return nil }
            self.x = x
            self.y = y
            self.z = z
        }

        /// Non-finite coordinates cannot key a voxel; finite extremes clamp
        /// to the representable grid instead of trapping the conversion.
        private static func index(_ scaled: Float) -> Int32? {
            guard scaled.isFinite else { return nil }
            let floored = scaled.rounded(.down)
            if floored < Float(Int32.min) { return Int32.min }
            // The largest Float below 2^31; anything above overflows Int32.
            if floored > 2_147_483_520 { return Int32.max }
            return Int32(floored)
        }
    }
}
