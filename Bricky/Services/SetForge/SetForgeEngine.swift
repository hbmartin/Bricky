import Foundation

/// End-to-end, fully on-device Set Forge generation: a `VoxelModel` becomes a
/// buildable `GeneratedLegoSet` (bricks, parts list, instructions, LDraw).
///
/// Pipeline mirrors `MosaicEngine`:
/// `settle → budget-fit → pack → LDraw → parts → instructions`.
/// Deterministic and offline; if the input is empty it throws rather than
/// fabricating a result.
struct SetForgeEngine {

    static let shared = SetForgeEngine()

    enum EngineError: LocalizedError {
        case emptyModel

        var errorDescription: String? {
            switch self {
            case .emptyModel:
                return "There wasn't enough shape to build a model. Try a different description or photo."
            }
        }
    }

    /// Generate a complete set from a voxel model.
    ///
    /// - Parameters:
    ///   - model: The colored voxel grid from an input adapter.
    ///   - size: Target size preset, used for the brick budget.
    ///   - name: Display name for the set (usually derived from the subject).
    ///   - progress: Fractional progress `0...1`, reported as stages complete.
    func generate(
        from model: VoxelModel,
        size: VoxelModel.Size,
        name: String,
        generator: GeneratedLegoSet.Generator = .onDevice,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> GeneratedLegoSet {
        guard !model.isEmpty else { throw EngineError.emptyModel }
        progress(0.05)

        // 1. Structural hygiene: settle columns so nothing floats.
        var settled = model.gravitySettled()
        progress(0.2)

        // 2. Budget fit: downsample until the voxel count is under budget.
        //    (Voxel count is an upper bound on brick count.)
        var factor = 2
        while settled.voxelCount > size.brickBudget, factor <= 6 {
            settled = model.gravitySettled().downsampled(by: factor)
            factor += 1
        }
        guard !settled.isEmpty else { throw EngineError.emptyModel }
        progress(0.4)

        // 3. Pack layers into bricks.
        let bricks = VoxelPacker.pack(settled)
        guard !bricks.isEmpty else { throw EngineError.emptyModel }
        progress(0.6)

        // 4. LDraw export.
        let ldr = SetForgeLDRExporter.export(bricks, subject: name)
        progress(0.75)

        // 5. Parts aggregation.
        let parts = SetForgePartsAggregator.aggregate(bricks)
        progress(0.85)

        // 6. Instructions.
        let steps = SetForgeInstructions.steps(for: bricks)
        progress(1.0)

        return GeneratedLegoSet(
            name: name,
            subject: model.subject,
            source: model.source,
            sizeLabel: size.rawValue,
            generator: generator,
            bricks: bricks,
            parts: parts,
            steps: steps,
            ldrText: ldr
        )
    }
}
