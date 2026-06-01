import Foundation
import UIKit

/// The finished, on-device mosaic build. Carries everything the UI and export
/// flow need — no network URLs, no server round-trip.
struct MosaicEngineOutput {
    let grid: MosaicColorGrid
    let bricks: [MosaicBrick]
    let parts: MosaicPartsList
    let ldrText: String
    let thumbnail: UIImage
    let pdfData: Data
    let brickCount: Int
    let studCount: Int

    /// The snapped grid size, in the shape the view model already publishes.
    var snappedGrid: MosaicJobGrid { MosaicJobGrid(width: grid.width, height: grid.height) }
}

/// End-to-end mosaic generation, fully on-device. Replaces the
/// `services/lego-model-gen` Python backend and the networked
/// `MosaicGenerationService`, satisfying Bricky's offline-first principle.
///
/// Pipeline (mirrors the backend `app/pipeline.py`):
/// `vision → packing → LDraw export → parts aggregation → instructions PDF`.
/// The deterministic middle stages are locked byte-for-byte against the backend
/// golden fixtures; the vision stage is a best-effort on-device equivalent.
struct MosaicEngine {

    static let shared = MosaicEngine()

    enum EngineError: LocalizedError {
        case invalidGridSize(Int, Int)

        var errorDescription: String? {
            switch self {
            case let .invalidGridSize(w, h):
                return "Invalid mosaic grid size \(w)×\(h)."
            }
        }
    }

    /// Generate a complete mosaic from a source image.
    ///
    /// - Parameter progress: fractional progress `0...1`, reported as stages
    ///   complete. Invoked on the calling thread (use a `@Sendable` closure that
    ///   hops to the main actor if it updates UI).
    func generate(
        image: UIImage,
        width: Int,
        height: Int,
        paletteId: String = MosaicPalette.defaultPaletteId,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> MosaicEngineOutput {
        guard width > 0, height > 0 else {
            throw EngineError.invalidGridSize(width, height)
        }

        let palette = try MosaicPalette.load(paletteId)
        progress(0.05)

        // 1. Vision: image → quantized color grid.
        let grid = MosaicVision.buildGrid(
            image: image,
            width: width,
            height: height,
            palette: palette
        )
        progress(0.35)

        // 2. Packing: grid → ordered brick list.
        let bricks = MosaicPacker.pack(grid)
        progress(0.55)

        // 3. LDraw export.
        let ldrText = MosaicLDRExporter.export(bricks, palette: palette)
        progress(0.65)

        // 4. Parts aggregation.
        let parts = MosaicPartsAggregator.aggregate(bricks, palette: palette)
        progress(0.72)

        // 5. Thumbnail + instructions PDF.
        let thumbnail = MosaicInstructionsRenderer.renderThumbnail(grid: grid, palette: palette)
        progress(0.8)
        let pdfData = MosaicInstructionsRenderer.buildInstructionsPDF(
            grid: grid,
            parts: parts,
            palette: palette,
            brickCount: bricks.count
        )
        progress(1.0)

        return MosaicEngineOutput(
            grid: grid,
            bricks: bricks,
            parts: parts,
            ldrText: ldrText,
            thumbnail: thumbnail,
            pdfData: pdfData,
            brickCount: bricks.count,
            studCount: grid.studCount
        )
    }
}
