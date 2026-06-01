import Foundation

/// A placed plate run. `(x, y)` is the left-most stud; `length` runs along +X.
/// Faithful port of the backend `Brick` dataclass (`app/contracts.py`).
struct MosaicBrick: Equatable {
    let x: Int
    let y: Int
    let length: Int
    let color: String

    /// LDraw part id for this plate run, enforcing the Part Contract.
    var part: String { MosaicContract.part(forLength: length) }
}

/// Shared mosaic contracts (`app/contracts.py`): the length→part mapping and
/// LDraw scaling. These are the single source of truth pinning brick geometry.
enum MosaicContract {
    /// Plate length in studs → LDraw part id (DATA_CONTRACTS §7).
    static let partByLength: [Int: String] = [1: "3024", 2: "3023", 3: "3623", 4: "3710"]

    /// Lengths the packer may emit, greedy longest-first.
    static let allowedLengths: [Int] = [4, 3, 2, 1]

    /// 1 stud = 20 LDU (LDRAW_EXPORT §2).
    static let lduPerStud = 20

    static func part(forLength length: Int) -> String {
        // The packer only ever emits 1...4, so this is always present; fall
        // back to the 1x1 plate id rather than crashing on programmer error.
        partByLength[length] ?? "3024"
    }
}

/// Brick packing v1: row-based run-length tiling. Faithful port of the backend
/// `app/packing.py`.
///
/// For each row, consecutive same-color non-empty cells form a run; each run is
/// split into plates greedily, longest-allowed-first. Output is deterministic
/// (rows top→bottom, columns left→right) and satisfies the brick-list
/// invariants: full coverage, no overlap, color fidelity, part↔length
/// consistency.
enum MosaicPacker {

    /// Greedy longest-first split of a run length into allowed plate lengths.
    static func splitRun(_ length: Int) -> [Int] {
        var pieces: [Int] = []
        var remaining = length
        while remaining > 0 {
            for size in MosaicContract.allowedLengths where size <= remaining {
                pieces.append(size)
                remaining -= size
                break
            }
        }
        return pieces
    }

    /// Pack a color grid into an ordered list of plate bricks.
    static func pack(_ grid: MosaicColorGrid) -> [MosaicBrick] {
        var bricks: [MosaicBrick] = []
        for y in 0..<grid.height {
            let row = grid.cells[y]
            var x = 0
            while x < grid.width {
                guard let color = row[x] else {
                    x += 1
                    continue
                }
                // Extend the run while color matches.
                let runStart = x
                while x < grid.width, row[x] == color {
                    x += 1
                }
                let runLen = x - runStart
                var offset = runStart
                for piece in splitRun(runLen) {
                    bricks.append(MosaicBrick(x: offset, y: y, length: piece, color: color))
                    offset += piece
                }
            }
        }
        return bricks
    }
}
