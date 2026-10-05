import Foundation
import simd

/// Where an authored placement sits on the stud lattice (M2.0).
struct LatticeCell: Hashable, Sendable {
    /// First stud column covered, in x and z, relative to the plan's grid.
    let minColumn: SIMD2<Int>
    /// Stud columns spanned in x and z.
    let footprint: SIMD2<Int>
    /// Bottom face, in plate heights (8 LDU) above the plan's grid.
    let bottomLevel: Int
    /// Yaw in quarter turns about the vertical axis, 0…3.
    let quarterTurns: Int
}

enum LatticeStatus: Hashable, Sendable {
    case onLattice(LatticeCell)
    /// No lattice hypothesis is ever generated for these: the safe default
    /// for parts the heuristics do not understand.
    case offLattice(OffLatticeReason)

    var cell: LatticeCell? {
        if case .onLattice(let cell) = self { return cell }
        return nil
    }
}

enum OffLatticeReason: String, Hashable, Sendable, Error {
    case noGeometry = "no_geometry"
    /// Rotated about a horizontal axis.
    case tilted
    /// Yawed by other than a quarter turn.
    case offAxisYaw = "off_axis_yaw"
    /// Not aligned with the plan's 20-LDU / 8-LDU grid.
    case offGrid = "off_grid"
}

/// What a plan's placements are, where, and what rests on what (M2.0): the
/// lattice status the build diff's ±1 stud hypotheses need, occupancy
/// columns, and the support graph a repair needs to know what must come off
/// before a buried part can be fixed.
///
/// Heuristic by design, from each placement's axis-aligned bounds:
/// - On the lattice means a quarter-turn yaw, the bounds' minimum corner on
///   the 20-LDU grid (the grid's phase taken from the first aligned
///   placement), whole-stud footprints, and a bottom on the 8-LDU grid, each
///   within 0.5 LDU. The corner, not the origin: a 1×2 brick's origin sits
///   between studs.
/// - Rests on: the lower part's top, or its top less one stud height
///   (4 LDU), meets the upper part's bottom within 1 LDU, over at least one
///   shared column.
struct PlacementGeometryIndex: Sendable {
    static let studLDU: Double = 20
    static let plateLDU: Double = 8
    static let studHeightLDU: Double = 4
    static let gridTolerance: Double = 0.5
    static let contactTolerance: Double = 1

    let status: [LatticeStatus]
    /// Each placement's origin in the engine's model frame (metres, y up):
    /// the point a builder turns the part about.
    let origins: [SIMD3<Float>]
    /// Placements covering each stud column.
    let occupancy: [SIMD2<Int>: [Int]]
    /// `supports[p]`: placements resting directly on p.
    let supports: [[Int]]
    /// `supportedBy[q]`: placements q rests directly on.
    let supportedBy: [[Int]]

    /// Everything resting on `placement`, directly or through others,
    /// ascending: what has to come off before it can be fixed.
    func blockers(of placement: Int) -> [Int] {
        guard supports.indices.contains(placement) else { return [] }
        var seen = Set<Int>()
        var frontier = supports[placement]
        while let next = frontier.popLast() {
            guard seen.insert(next).inserted else { continue }
            frontier.append(contentsOf: supports[next])
        }
        return seen.sorted()
    }

    struct Bounds {
        /// LDU, x and z as LDraw has them, y measured upward.
        let minimum: SIMD3<Double>
        let maximum: SIMD3<Double>
    }

    static func build(plan: InstructionPlan, segments: SegmentedGeometry) -> PlacementGeometryIndex {
        build(transforms: plan.placementTimeline.map(\.transform), segments: segments)
    }

    static func build(transforms: [LDrawTransform], segments: SegmentedGeometry) -> PlacementGeometryIndex {
        let count = min(transforms.count, segments.placementCount)
        let boxes: [Bounds?] = (0..<count).map { bounds(of: segments, placement: $0) }
        let turns: [Result<Int, OffLatticeReason>] = transforms.prefix(count).map(quarterTurns)

        // The grid's phase: the first placement with a quarter-turn yaw.
        var phase = SIMD3<Double>(0, 0, 0)
        if let anchor = (0..<count).first(where: { boxes[$0] != nil && (try? turns[$0].get()) != nil }),
           let anchorBounds = boxes[anchor] {
            phase = SIMD3(
                positiveRemainder(anchorBounds.minimum.x, studLDU),
                positiveRemainder(anchorBounds.minimum.y, plateLDU),
                positiveRemainder(anchorBounds.minimum.z, studLDU)
            )
        }

        var status: [LatticeStatus] = []
        var occupancy: [SIMD2<Int>: [Int]] = [:]
        for placement in 0..<count {
            guard let box = boxes[placement] else {
                status.append(.offLattice(.noGeometry))
                continue
            }
            let quarter: Int
            switch turns[placement] {
            case .success(let value): quarter = value
            case .failure(let reason):
                status.append(.offLattice(reason))
                continue
            }
            guard let columnX = gridIndex(box.minimum.x - phase.x, studLDU),
                  let columnZ = gridIndex(box.minimum.z - phase.z, studLDU),
                  let level = gridIndex(box.minimum.y - phase.y, plateLDU),
                  let spanX = gridIndex(box.maximum.x - box.minimum.x, studLDU),
                  let spanZ = gridIndex(box.maximum.z - box.minimum.z, studLDU),
                  spanX > 0, spanZ > 0 else {
                status.append(.offLattice(.offGrid))
                continue
            }
            let cell = LatticeCell(
                minColumn: SIMD2(columnX, columnZ), footprint: SIMD2(spanX, spanZ),
                bottomLevel: level, quarterTurns: quarter
            )
            status.append(.onLattice(cell))
            for x in columnX..<(columnX + spanX) {
                for z in columnZ..<(columnZ + spanZ) {
                    occupancy[SIMD2(x, z), default: []].append(placement)
                }
            }
        }

        var supports = [[Int]](repeating: [], count: count)
        var supportedBy = [[Int]](repeating: [], count: count)
        var pairs = Set<SIMD2<Int>>()
        for placements in occupancy.values where placements.count > 1 {
            for lower in placements {
                for upper in placements where upper != lower {
                    guard let lowerBox = boxes[lower], let upperBox = boxes[upper] else { continue }
                    let bottom = upperBox.minimum.y
                    let top = lowerBox.maximum.y
                    let rests = abs(bottom - top) <= contactTolerance
                        || abs(bottom - (top - studHeightLDU)) <= contactTolerance
                    if rests, pairs.insert(SIMD2(lower, upper)).inserted {
                        supports[lower].append(upper)
                        supportedBy[upper].append(lower)
                    }
                }
            }
        }
        return PlacementGeometryIndex(
            status: status,
            origins: transforms.prefix(count).map { SIMD3(Float($0.x), Float(-$0.y), Float($0.z)) * 0.0004 },
            occupancy: occupancy,
            supports: supports.map { $0.sorted() },
            supportedBy: supportedBy.map { $0.sorted() }
        )
    }

    /// A placement's bounds in LDU, y up, from its segment's vertices.
    static func bounds(of segments: SegmentedGeometry, placement: Int) -> Bounds? {
        let range = segments.vertexRange(placement)
        guard !range.isEmpty else { return nil }
        var minimum = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for vertex in segments.positions[range] {
            // The engine's world frame: 0.4 mm per LDU, Y already up.
            let point = SIMD3<Double>(Double(vertex.x), Double(vertex.y), Double(vertex.z)) / 0.0004
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        return Bounds(minimum: minimum, maximum: maximum)
    }

    /// The yaw of an LDraw rotation in quarter turns, or why it is not one.
    static func quarterTurns(_ transform: LDrawTransform) -> Result<Int, OffLatticeReason> {
        func near(_ value: Double, _ target: Double) -> Bool { abs(value - target) < 1e-6 }
        // Vertical stays vertical: no tilt.
        guard near(transform.b, 0), near(transform.d, 0), near(transform.f, 0), near(transform.h, 0),
              near(transform.e, 1) else { return .failure(.tilted) }
        switch (transform.a, transform.c, transform.g, transform.i) {
        case let (a, c, g, i) where near(a, 1) && near(c, 0) && near(g, 0) && near(i, 1): return .success(0)
        case let (a, c, g, i) where near(a, 0) && near(c, 1) && near(g, -1) && near(i, 0): return .success(1)
        case let (a, c, g, i) where near(a, -1) && near(c, 0) && near(g, 0) && near(i, -1): return .success(2)
        case let (a, c, g, i) where near(a, 0) && near(c, -1) && near(g, 1) && near(i, 0): return .success(3)
        default: return .failure(.offAxisYaw)
        }
    }

    /// `value / pitch` when it is within `gridTolerance` LDU of a whole
    /// number, else nil.
    private static func gridIndex(_ value: Double, _ pitch: Double) -> Int? {
        let steps = (value / pitch).rounded()
        guard abs(value - steps * pitch) <= gridTolerance else { return nil }
        return Int(steps)
    }

    private static func positiveRemainder(_ value: Double, _ pitch: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: pitch)
        return remainder < 0 ? remainder + pitch : remainder
    }
}
