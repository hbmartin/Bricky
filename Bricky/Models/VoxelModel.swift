import Foundation

/// A single occupied cell in a 3D brick-model grid.
///
/// Coordinate system (studs / brick layers):
/// - `x` runs left→right (grid width)
/// - `y` runs bottom→top (build layers; `y = 0` is the base plate row)
/// - `z` runs front→back (grid depth)
struct Voxel: Equatable, Hashable, Codable {
    var x: Int
    var y: Int
    var z: Int
    var color: LegoColor
}

/// The canonical intermediate representation for Set Forge: a colored 3D voxel
/// grid. Both input adapters — `VoxelShapeLibrary` (describe-to-set) and
/// `PhotoVoxelizer` (scan-to-set) — produce a `VoxelModel`, which the shared
/// on-device `SetForgeEngine` turns into a buildable brick set.
///
/// The model is deliberately *sparse* (only occupied cells are stored) and
/// carries its bounding grid size so downstream stages can reason about layers
/// and footprints without scanning every cell.
struct VoxelModel: Equatable, Codable {
    /// Target build size, controlling grid resolution and the brick budget.
    enum Size: String, Codable, CaseIterable, Identifiable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"

        var id: String { rawValue }

        /// Longest grid dimension in studs. Scales all procedural generators
        /// and the photo voxelizer.
        var maxDimension: Int {
            switch self {
            case .small: return 20
            case .medium: return 36
            case .large: return 56
            }
        }

        /// Soft ceiling on total bricks. The engine auto-downsamples inputs that
        /// would blow past this so part counts stay sane.
        var brickBudget: Int {
            switch self {
            case .small: return 2_000
            case .medium: return 6_000
            case .large: return 14_000
            }
        }

        var subtitle: String {
            switch self {
            case .small: return "Quick build · up to ~2,000 pieces"
            case .medium: return "Balanced detail · up to ~6,000 pieces"
            case .large: return "Most detail · up to ~14,000 pieces"
            }
        }

        var iconName: String {
            switch self {
            case .small: return "square"
            case .medium: return "square.grid.2x2"
            case .large: return "square.grid.3x3"
            }
        }
    }

    /// How the model was created — drives copy and analytics, never fabricated.
    enum Source: String, Codable {
        case text
        case photo
    }

    /// Grid extents (in studs / layers). `voxels` are bounded to `0..<width`,
    /// `0..<height`, `0..<depth`.
    var width: Int
    var height: Int
    var depth: Int
    var voxels: [Voxel]
    var source: Source
    /// The user's original subject text (a described subject, or a caption for a
    /// scanned photo). Used only for naming/labelling.
    var subject: String

    init(
        width: Int,
        height: Int,
        depth: Int,
        voxels: [Voxel],
        source: Source,
        subject: String
    ) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.depth = max(0, depth)
        self.voxels = voxels
        self.source = source
        self.subject = subject
    }

    var isEmpty: Bool { voxels.isEmpty }

    /// Fast occupancy lookup set keyed by packed coordinates.
    var occupancy: Set<Int> {
        Set(voxels.map { Self.key($0.x, $0.y, $0.z) })
    }

    static func key(_ x: Int, _ y: Int, _ z: Int) -> Int {
        // Bounded well within Int for any realistic grid (≤ a few hundred /axis).
        ((x &+ 512) << 20) | ((y &+ 512) << 10) | (z &+ 512)
    }

    /// Total occupied cells (an upper bound on brick count before merging).
    var voxelCount: Int { voxels.count }

    /// Number of non-empty build layers.
    var layerCount: Int {
        Set(voxels.map(\.y)).count
    }

    // MARK: - Structural hygiene

    /// Remove voxels that float with no occupied cell directly beneath them,
    /// pulling each unsupported column down until it rests on a support or the
    /// base. Guarantees the "no floating bricks" invariant by construction so
    /// every produced model is physically buildable.
    ///
    /// Operates column-by-column in `(x, z)`: within a column, occupied `y`
    /// values are compacted downward so there are no vertical gaps and the
    /// lowest cell sits on the base (`y = 0`). This is a gravity/settle pass.
    func gravitySettled() -> VoxelModel {
        var byColumn: [Int: [Voxel]] = [:]
        for v in voxels {
            byColumn[(v.x << 16) | (v.z & 0xFFFF), default: []].append(v)
        }
        var settled: [Voxel] = []
        settled.reserveCapacity(voxels.count)
        var maxY = 0
        for (_, columnVoxels) in byColumn {
            // Preserve color order from bottom to top, then compact to 0-based.
            let ordered = columnVoxels.sorted { $0.y < $1.y }
            for (newY, v) in ordered.enumerated() {
                settled.append(Voxel(x: v.x, y: newY, z: v.z, color: v.color))
                maxY = max(maxY, newY)
            }
        }
        return VoxelModel(
            width: width,
            height: maxY + 1,
            depth: depth,
            voxels: settled,
            source: source,
            subject: subject
        )
    }

    /// Downsample the grid by an integer factor so a too-dense model fits the
    /// brick budget. A cell in the reduced grid is occupied if *any* source
    /// cell in its block was occupied; its color is the most common among them.
    func downsampled(by factor: Int) -> VoxelModel {
        guard factor > 1 else { return self }
        var buckets: [Int: [LegoColor]] = [:]
        for v in voxels {
            let nx = v.x / factor
            let ny = v.y / factor
            let nz = v.z / factor
            buckets[Self.key(nx, ny, nz), default: []].append(v.color)
        }
        var reduced: [Voxel] = []
        reduced.reserveCapacity(buckets.count)
        var mx = 0, my = 0, mz = 0
        for v in voxels {
            _ = v // keep bounds calc below simple
        }
        for (packed, colors) in buckets {
            // Unpack the same scheme used in `key`.
            let z = (packed & 0x3FF) - 512
            let y = ((packed >> 10) & 0x3FF) - 512
            let x = ((packed >> 20) & 0x3FF) - 512
            let color = Self.mode(of: colors)
            reduced.append(Voxel(x: x, y: y, z: z, color: color))
            mx = max(mx, x); my = max(my, y); mz = max(mz, z)
        }
        return VoxelModel(
            width: mx + 1,
            height: my + 1,
            depth: mz + 1,
            voxels: reduced,
            source: source,
            subject: subject
        )
    }

    private static func mode(of colors: [LegoColor]) -> LegoColor {
        var counts: [LegoColor: Int] = [:]
        for c in colors { counts[c, default: 0] += 1 }
        // Deterministic tie-break by raw value so output is reproducible.
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key.rawValue > b.key.rawValue
        }?.key ?? colors.first ?? .gray
    }
}
