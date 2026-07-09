import Foundation

/// A finished, buildable brick set produced by Set Forge. Fully on-device — no
/// network URLs. Carries everything the result UI, the 3D preview, the parts
/// list, the instructions, and export/share need.
struct GeneratedLegoSet: Identifiable, Codable, Equatable {
    /// How the model geometry was produced (drives an honest quality badge).
    enum Generator: String, Codable {
        /// True 3D from a hosted mesh model (photo/multiview/text → mesh) or an
        /// imported 3D model.
        case hd
        /// AI voxel authoring (GPT text → voxel DSL).
        case ai
        /// On-device procedural template or photo relief.
        case onDevice

        var label: String {
            switch self {
            case .hd: return "HD 3D"
            case .ai: return "AI"
            case .onDevice: return "On-Device"
            }
        }

        var systemImage: String {
            switch self {
            case .hd: return "cube.transparent.fill"
            case .ai: return "sparkles"
            case .onDevice: return "iphone"
            }
        }
    }

    let id: UUID
    /// User-facing name (derived from the subject).
    var name: String
    /// The original subject text (a description, or a photo caption).
    var subject: String
    var source: VoxelModel.Source
    var sizeLabel: String
    /// Which pipeline produced the geometry.
    var generator: Generator

    /// Placed bricks for the 3D preview and counts.
    var bricks: [PlacedBrick]
    /// Bill of materials.
    var parts: [SetForgePartsAggregator.Part]
    /// Layer-by-layer build steps.
    var steps: [BuildStep]
    /// LDraw model text for export.
    var ldrText: String

    var brickCount: Int
    var layerCount: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        subject: String,
        source: VoxelModel.Source,
        sizeLabel: String,
        generator: Generator = .onDevice,
        bricks: [PlacedBrick],
        parts: [SetForgePartsAggregator.Part],
        steps: [BuildStep],
        ldrText: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subject = subject
        self.source = source
        self.sizeLabel = sizeLabel
        self.generator = generator
        self.bricks = bricks
        self.parts = parts
        self.steps = steps
        self.ldrText = ldrText
        self.brickCount = bricks.count
        self.layerCount = Set(bricks.map(\.y)).count
        self.createdAt = createdAt
    }

    /// Total number of individual studs across all bricks (a rough size metric).
    var studCount: Int { bricks.reduce(0) { $0 + $1.length } }

    /// Estimated difficulty from the raw brick count.
    var difficulty: Difficulty {
        switch brickCount {
        case ..<120: return .beginner
        case ..<400: return .easy
        case ..<1_000: return .medium
        case ..<2_500: return .hard
        default: return .expert
        }
    }

    /// The shared `RequiredPiece` list, so a forged set can be matched against
    /// the user's inventory exactly like a catalog project.
    var requiredPieces: [RequiredPiece] {
        SetForgePartsAggregator.requiredPieces(parts)
    }

    /// Bridge to the app's catalog `LegoProject` so forged sets can reuse the
    /// existing build-instructions screen and inventory-match logic.
    func asLegoProject() -> LegoProject {
        LegoProject(
            id: id,
            name: name,
            description: "A custom brick model forged from \(source == .text ? "your description" : "a photo").",
            difficulty: difficulty,
            category: .art,
            estimatedTime: "\(max(10, brickCount / 15)) min",
            requiredPieces: requiredPieces,
            instructions: steps,
            imageSystemName: source == .text ? "text.bubble" : "camera.viewfinder",
            funFact: nil
        )
    }
}
