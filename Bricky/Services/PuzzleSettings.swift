import Foundation

/// Grid sizes for the mosaic-style puzzle reveal. Mirrors `MosaicGridPreset`
/// (32/48/64/96) plus a 128×128 option unique to puzzles.
enum PuzzleGridPreset: Int, CaseIterable, Identifiable {
    case small = 32
    case medium = 48
    case large = 64
    case huge = 96
    case max = 128

    var id: Int { rawValue }
    var studs: Int { rawValue }
    var label: String { "\(rawValue) × \(rawValue)" }
}

/// User-configurable settings for the Puzzle section. Squares revealed per hint
/// are tied to the grid: gridSize / 4 (e.g. 64 grid → 16 squares per hint).
final class PuzzleSettings: ObservableObject {
    static let shared = PuzzleSettings()

    private let gridKey = "puzzle.gridSize"

    @Published var gridSize: Int {
        didSet { UserDefaults.standard.set(gridSize, forKey: gridKey) }
    }

    /// Squares to reveal with each hint: grid size divided by four.
    var revealPerHint: Int { max(1, gridSize / 4) }

    /// Total cells in the puzzle mosaic.
    var totalCells: Int { gridSize * gridSize }

    var preset: PuzzleGridPreset {
        get { PuzzleGridPreset(rawValue: gridSize) ?? .medium }
        set { gridSize = newValue.rawValue }
    }

    private init() {
        let stored = UserDefaults.standard.integer(forKey: gridKey)
        gridSize = PuzzleGridPreset(rawValue: stored)?.rawValue ?? PuzzleGridPreset.medium.rawValue
    }
}
