import Foundation
import simd

/// How a part looks after quarter turns about its own vertical axis (M2.0),
/// the rotation a builder makes by placing it the wrong way round. A
/// symmetric rotation is not a mistake, so the build diff only tests
/// rotations a part does not survive.
///
/// Measured on the part's triangles in its own frame, rotated about its
/// origin (where LDraw puts the centre of a brick's footprint):
/// - `chamferMetres[k − 1]`: the two-sided mean distance from each surface
///   sample to the nearest sample of the turned surface, after k turns.
///   Samples sit on a barycentric grid of at most 0.5 mm spacing, so this
///   approximates the point-to-surface Chamfer distance.
/// - `topDownIdentical[k − 1]`: whether the turned part's top-down height
///   field (0.5 mm cells) matches, i.e. whether depth from above could tell.
struct RotationalSymmetry: Sendable, Equatable {
    static let symmetricThreshold: Float = 0.0005
    static let sampleSpacing: Float = 0.0005
    static let heightCell: Float = 0.0005
    /// Nearest-sample searches look one grid cell around the query; a
    /// sample with nothing that close counts as this far away. Symmetric
    /// surfaces sit near zero, asymmetric ones well above the threshold, so
    /// the cap only flattens distances that are already decisive.
    static let distanceCap: Float = 0.003
    static let searchCell: Float = 0.001

    let chamferMetres: [Float]
    let topDownIdentical: [Bool]

    func isSymmetric(quarterTurns: Int) -> Bool {
        let turns = ((quarterTurns % 4) + 4) % 4
        return turns == 0 || chamferMetres[turns - 1] < Self.symmetricThreshold
    }

    func isTopDownIdentical(quarterTurns: Int) -> Bool {
        let turns = ((quarterTurns % 4) + 4) % 4
        return turns == 0 || topDownIdentical[turns - 1]
    }

    /// `positions` is a triangle soup, three vertices per triangle.
    static func measure(positions: [SIMD3<Float>]) -> RotationalSymmetry {
        let samples = surfaceSamples(positions)
        guard !samples.isEmpty else {
            return RotationalSymmetry(chamferMetres: [0, 0, 0], topDownIdentical: [true, true, true])
        }
        let grid = SampleGrid(samples, cell: searchCell)
        let heights = heightField(samples)
        var chamfer: [Float] = []
        var topDown: [Bool] = []
        for turns in 1...3 {
            let turned = samples.map { rotate($0, quarterTurns: turns) }
            let turnedGrid = SampleGrid(turned, cell: searchCell)
            let forward = turned.reduce(Float(0)) { $0 + grid.nearestDistance(to: $1) } / Float(turned.count)
            let backward = samples.reduce(Float(0)) { $0 + turnedGrid.nearestDistance(to: $1) } / Float(samples.count)
            chamfer.append((forward + backward) / 2)
            topDown.append(heightFieldsMatch(heights, heightField(turned)))
        }
        return RotationalSymmetry(chamferMetres: chamfer, topDownIdentical: topDown)
    }

    static func rotate(_ point: SIMD3<Float>, quarterTurns: Int) -> SIMD3<Float> {
        // LDraw's yaw convention, x' = cos·x + sin·z, z' = −sin·x + cos·z,
        // in exact quarter steps.
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: SIMD3(point.z, point.y, -point.x)
        case 2: SIMD3(-point.x, point.y, -point.z)
        case 3: SIMD3(-point.z, point.y, point.x)
        default: point
        }
    }

    /// Points on a barycentric grid over every triangle, no farther apart
    /// than `sampleSpacing` along any edge. Deterministic, so a symmetric
    /// mesh samples to a symmetric point set.
    static func surfaceSamples(_ positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var samples: [SIMD3<Float>] = []
        var triangle = 0
        while triangle + 2 < positions.count {
            let a = positions[triangle], b = positions[triangle + 1], c = positions[triangle + 2]
            let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
            let divisions = max(1, Int((longest / sampleSpacing).rounded(.up)))
            for i in 0...divisions {
                for j in 0...(divisions - i) {
                    let u = Float(i) / Float(divisions)
                    let v = Float(j) / Float(divisions)
                    samples.append(a + (b - a) * u + (c - a) * v)
                }
            }
            triangle += 3
        }
        return samples
    }

    private struct CellKey: Hashable {
        let x: Int, y: Int, z: Int
    }

    private static func heightField(_ samples: [SIMD3<Float>]) -> [SIMD2<Int>: Float] {
        var heights: [SIMD2<Int>: Float] = [:]
        for sample in samples {
            let cell = SIMD2(Int((sample.x / heightCell).rounded(.down)), Int((sample.z / heightCell).rounded(.down)))
            heights[cell] = max(heights[cell] ?? -.greatestFiniteMagnitude, sample.y)
        }
        return heights
    }

    /// Identical when at least 98% of the cells either field occupies hold
    /// both, within 0.5 mm of height: sampling leaves ragged borders.
    private static func heightFieldsMatch(_ lhs: [SIMD2<Int>: Float], _ rhs: [SIMD2<Int>: Float]) -> Bool {
        let cells = Set(lhs.keys).union(rhs.keys)
        guard !cells.isEmpty else { return true }
        let agreeing = cells.reduce(0) { count, cell in
            guard let l = lhs[cell], let r = rhs[cell] else { return count }
            return count + (abs(l - r) <= heightCell ? 1 : 0)
        }
        return Float(agreeing) / Float(cells.count) >= 0.98
    }

    /// Uniform hash grid for nearest-sample queries within `distanceCap`.
    private struct SampleGrid {
        let cell: Float
        let buckets: [CellKey: [SIMD3<Float>]]

        init(_ points: [SIMD3<Float>], cell: Float) {
            self.cell = cell
            var buckets: [CellKey: [SIMD3<Float>]] = [:]
            for point in points {
                buckets[Self.key(point, cell), default: []].append(point)
            }
            self.buckets = buckets
        }

        static func key(_ point: SIMD3<Float>, _ cell: Float) -> CellKey {
            CellKey(
                x: Int((point.x / cell).rounded(.down)),
                y: Int((point.y / cell).rounded(.down)),
                z: Int((point.z / cell).rounded(.down))
            )
        }

        func nearestDistance(to point: SIMD3<Float>) -> Float {
            let center = Self.key(point, cell)
            var best = RotationalSymmetry.distanceCap
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        guard let bucket = buckets[CellKey(x: center.x + dx, y: center.y + dy, z: center.z + dz)] else { continue }
                        for candidate in bucket {
                            best = min(best, simd_distance(point, candidate))
                        }
                    }
                }
            }
            return best
        }
    }
}
