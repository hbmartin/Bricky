import Foundation

/// Turns a `VoxelModel` into an ordered list of placed 1×N bricks.
///
/// Algorithm (a 3D extension of the Mosaic run-length packer):
/// 1. **Per-layer tiling** — for each build layer `y`, walk each depth row `z`
///    left→right and merge consecutive same-colour voxels into runs, then split
///    each run greedily into the longest allowed brick lengths.
/// 2. **Seam staggering** — on alternating layers the greedy split leads with a
///    shorter first brick, so vertical seams don't stack between layers. This is
///    what makes the model interlock like real brickwork instead of
///    delaminating.
///
/// Output order is deterministic (layer bottom→top, row front→back, column
/// left→right), so LDraw export and instruction steps are reproducible.
enum VoxelPacker {

    /// Greedy longest-first split of a run into allowed brick lengths.
    /// When `stagger` is true and the run is longer than the smallest allowed
    /// brick, the first emitted brick is intentionally short (a 1-stud lead) so
    /// the seam pattern shifts relative to the neighbouring layer.
    static func splitRun(_ length: Int, stagger: Bool) -> [Int] {
        guard length > 0 else { return [] }
        var pieces: [Int] = []
        var remaining = length

        if stagger, length >= 2 {
            // Lead with a single stud to offset the seam, then pack the rest.
            pieces.append(1)
            remaining -= 1
        }

        while remaining > 0 {
            var placed = false
            for size in SetForgeContract.allowedLengths where size <= remaining {
                pieces.append(size)
                remaining -= size
                placed = true
                break
            }
            if !placed { break } // safety; allowedLengths always contains 1
        }
        return pieces
    }

    /// Pack a voxel model into an ordered brick list.
    static func pack(_ model: VoxelModel) -> [PlacedBrick] {
        guard !model.isEmpty else { return [] }

        // Index voxels by (y, z) row for fast row scans.
        var rows: [Int: [Int: LegoColor]] = [:] // key: y<<20 | z  ->  x -> color
        var maxX = 0, maxY = 0, maxZ = 0
        for v in model.voxels {
            rows[(v.y << 20) | (v.z & 0xFFFFF), default: [:]][v.x] = v.color
            maxX = max(maxX, v.x)
            maxY = max(maxY, v.y)
            maxZ = max(maxZ, v.z)
        }

        var bricks: [PlacedBrick] = []
        for y in 0...maxY {
            let stagger = (y % 2 == 1)
            for z in 0...maxZ {
                guard let row = rows[(y << 20) | (z & 0xFFFFF)] else { continue }
                var x = 0
                while x <= maxX {
                    guard let color = row[x] else { x += 1; continue }
                    // Extend the run while colour matches contiguously.
                    let runStart = x
                    while x <= maxX, row[x] == color { x += 1 }
                    let runLen = x - runStart

                    var offset = runStart
                    for piece in splitRun(runLen, stagger: stagger) {
                        bricks.append(PlacedBrick(
                            x: offset, y: y, z: z, length: piece, color: color
                        ))
                        offset += piece
                    }
                }
            }
        }
        return bricks
    }
}
