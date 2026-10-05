import Foundation
import simd

/// One flatten of an authored placement timeline that keeps placement
/// identity (M2.0). Triangles stay in timeline order, three vertices each,
/// and each placement owns one contiguous run of them. A step's cumulative
/// geometry is then a prefix, its delta a subrange, and "everything except
/// placement p" two ranges, all without flattening again.
///
/// Existing consumers keep colour-merged geometry, because the surface
/// sampler and draw-order depth ties both depend on buffer order:
/// `mergedByColour` rebuilds exactly what `LDrawGeometryEngine.snapshot`
/// would have produced for the same placements, bit for bit.
struct SegmentedGeometry: Sendable {
    /// Three per triangle, in timeline order.
    let positions: [SIMD3<Float>]
    /// The triangle's flat normal, repeated for its three vertices.
    let normals: [SIMD3<Float>]
    /// Resolved colour code, one per triangle.
    let triangleColours: [Int]
    /// Triangle offset where each placement starts, plus a final entry for
    /// the end: `placementCount + 1` values.
    let placementTriangleStarts: [Int]

    var placementCount: Int { placementTriangleStarts.count - 1 }
    var vertexCount: Int { positions.count }

    init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], triangleColours: [Int], placementTriangleStarts: [Int]) {
        self.positions = positions
        self.normals = normals
        self.triangleColours = triangleColours
        self.placementTriangleStarts = placementTriangleStarts
    }

    /// From per-placement buffers, as tests and synthetic edits build them.
    /// Each inner array is one placement; its buffers' triangles keep their
    /// order, buffer by buffer.
    init(segments: [[LDrawGeometryBuffer]]) {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colours: [Int] = []
        var starts = [0]
        for buffers in segments {
            for buffer in buffers {
                let triangles = buffer.positions.count / 3
                positions.append(contentsOf: buffer.positions.prefix(triangles * 3))
                normals.append(contentsOf: buffer.normals.prefix(triangles * 3))
                colours.append(contentsOf: repeatElement(buffer.colorCode, count: triangles))
            }
            starts.append(colours.count)
        }
        self.init(positions: positions, normals: normals, triangleColours: colours, placementTriangleStarts: starts)
    }

    /// Placement indices are clamped, the way `cumulativePlacements` clamps
    /// step indices, so an out-of-range request is empty, not a trap.
    private func clamped(_ placements: Range<Int>) -> Range<Int> {
        let lower = min(max(0, placements.lowerBound), placementCount)
        let upper = min(max(lower, placements.upperBound), placementCount)
        return lower..<upper
    }

    /// Vertices of placements `placements`, contiguous by construction.
    func vertexRange(_ placements: Range<Int>) -> Range<Int> {
        let range = clamped(placements)
        return placementTriangleStarts[range.lowerBound] * 3..<placementTriangleStarts[range.upperBound] * 3
    }

    func vertexRange(_ placement: Int) -> Range<Int> {
        vertexRange(placement..<(placement + 1))
    }

    /// Vertices of `placements` without `excluded`: at most two ranges, the
    /// empty ones dropped.
    func vertexRanges(_ placements: Range<Int>, excluding excluded: Int) -> [Range<Int>] {
        let range = clamped(placements)
        guard range.contains(excluded) else {
            let whole = vertexRange(range)
            return whole.isEmpty ? [] : [whole]
        }
        return [vertexRange(range.lowerBound..<excluded), vertexRange((excluded + 1)..<range.upperBound)]
            .filter { !$0.isEmpty }
    }

    /// The first `count` placements, merged by colour exactly as the engine
    /// merges a snapshot of the same placements.
    func mergedByColour(prefix count: Int) -> InstructionGeometrySnapshot {
        mergedByColour(0..<count)
    }

    /// Placements `placements`, merged by colour exactly as the engine
    /// merges a snapshot of the same placements: groups in ascending colour
    /// order, timeline order within each group.
    func mergedByColour(_ placements: Range<Int>) -> InstructionGeometrySnapshot {
        let range = clamped(placements)
        let triangles = placementTriangleStarts[range.lowerBound]..<placementTriangleStarts[range.upperBound]
        var order: [Int: [Int]] = [:]
        for triangle in triangles {
            order[triangleColours[triangle], default: []].append(triangle)
        }
        let buffers = order.keys.sorted().map { colour -> LDrawGeometryBuffer in
            let group = order[colour, default: []]
            var groupPositions: [SIMD3<Float>] = []
            var groupNormals: [SIMD3<Float>] = []
            groupPositions.reserveCapacity(group.count * 3)
            groupNormals.reserveCapacity(group.count * 3)
            for triangle in group {
                let first = triangle * 3
                groupPositions.append(contentsOf: positions[first..<(first + 3)])
                groupNormals.append(contentsOf: normals[first..<(first + 3)])
            }
            return LDrawGeometryBuffer(
                colorCode: colour,
                positions: groupPositions,
                normals: groupNormals,
                indices: groupPositions.indices.map(UInt32.init)
            )
        }
        return InstructionGeometrySnapshot(buffers: buffers, bounds: LDrawGeometryEngine.bounds(of: buffers))
    }
}
