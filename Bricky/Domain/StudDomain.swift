import Foundation
import simd

/// Which way a stud primitive faces: a top stud is what the next brick
/// grips and what a camera sees on a finished layer; an underside tube is
/// inside the brick and is never a keypoint.
enum StudRole: String, Sendable, Codable {
    case top
    case underside
}

/// Classifies LDraw stud primitives by file name (iOS 27 Phase 4). The
/// names follow the official library's `p/` primitives; their titles say
/// which are studs on top ("Stud", "Stud Open", the logo, truncated, Scala,
/// Duplo and patterned studs) and which are tubes underneath ("Stud Tube …",
/// "Stud Underside Cross", Duplo tubes). Group files (`stug…`) are recursed
/// into and their leaves classified, so they are never instances. Anything
/// unlisted is not a stud: the label exporter would rather miss a stud than
/// invent one. `8/` and `48/` are the low- and high-resolution copies of
/// the same primitives.
enum StudPrimitiveCatalog {
    enum Kind: Equatable, Sendable {
        case stud(StudRole)
        /// A group of studs (`stug…`), recursed into.
        case group
        /// Known, deliberately not a keypoint: a draw placeholder or an
        /// ambiguous Duplo tube-and-stud.
        case excluded
        /// An old name moved into `8/`, which resolves to the real file.
        case moved
    }

    static let top: Set<String> = [
        "stud", "studa", "stud2", "stud2a", "stud5", "stud6", "stud6a", "stud7", "stud7a", "stud9", "stud10",
        "stud13", "stud14", "stud15", "stud17", "stud17a", "stud19", "stud20", "stud24", "stud26", "studel",
        "studh", "studhl", "studhr", "studp01", "studx", "studxa",
    ]
    static let underside: Set<String> = [
        "stud3", "stud3a", "stud8", "stud8a", "stud8s2", "stud11", "stud12", "stud12a", "stud12s", "stud16", "stud16a", "stud16od",
        "stud18a", "stud21a", "stud22a", "stud23", "stud23d", "stud25", "stud2s", "stud2s2", "stud2s2e",
    ]
    static let excluded: Set<String> = ["studline", "stud27", "stud27a", "stud28", "stud28a"]

    /// The kind of a normalised reference (`p/8/stud.dat`, `stud4f1n.dat`,
    /// `8\stud.dat` lowercased), or nil when it is not a stud primitive.
    static func kind(of reference: String) -> Kind? {
        var name = reference.lowercased().replacingOccurrences(of: "\\", with: "/")
        if name.hasPrefix("p/") { name.removeFirst(2) }
        for prefix in ["8/", "48/"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        guard name.hasSuffix(".dat") else { return nil }
        name.removeLast(4)
        if name.hasPrefix("stug") { return .group }
        if name.hasPrefix("stu2") { return .moved }
        if top.contains(name) || name.hasPrefix("stud-logo") || name.hasPrefix("stud2-logo") { return .stud(.top) }
        if underside.contains(name) || name.hasPrefix("stud4") { return .stud(.underside) }
        if excluded.contains(name) { return .excluded }
        return nil
    }

    /// The role of a stud instance, or nil for anything else.
    static func role(of reference: String) -> StudRole? {
        if case .stud(let role) = kind(of: reference) { return role }
        return nil
    }
}

/// One stud in a flattened placement timeline.
struct StudInstance: Sendable, Equatable {
    /// Index into the placements the geometry was built from.
    let placement: Int
    /// The primitive's normalised name, e.g. `stud.dat`.
    let primitive: String
    let role: StudRole
    /// The keypoint in world metres: a top stud's top face centre (4 LDU
    /// above its base), or an underside tube's base centre.
    let keypoint: SIMD3<Float>
    /// Unit vector out of the stud, in world space: up for an upright top
    /// stud.
    let axis: SIMD3<Float>
    /// The primitive's scale along its axis; 1 for an ordinary stud.
    let scale: Float
    let colourCode: Int

    /// Studs drawn at another size (Duplo, Scala, decorative) are not the
    /// 8 mm lattice's studs.
    var isScaled: Bool { abs(scale - 1) > 1e-3 }
}

/// Every stud of a flattened timeline, and which triangles each one drew,
/// aligned with `SegmentedGeometry`'s triangles: 0 for a triangle that is
/// no stud's, else the stud's index plus one. That alignment is what lets
/// the tag pass render a stud-ID map from the same draw (ADR 0006).
struct StudIndex: Sendable, Equatable {
    let studs: [StudInstance]
    let triangleStud: [UInt32]

    var topStuds: [StudInstance] { studs.filter { $0.role == .top } }

    /// Studs owned by `placements`.
    func studs(in placements: Range<Int>) -> [StudInstance] {
        studs.filter { placements.contains($0.placement) }
    }
}
