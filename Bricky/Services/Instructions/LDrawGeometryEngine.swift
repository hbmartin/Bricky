import Foundation
import simd

struct LDrawGeometryBuffer: Sendable {
    let colorCode: Int
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]
}

struct InstructionGeometrySnapshot: Sendable {
    let buffers: [LDrawGeometryBuffer]
    let bounds: LDrawBounds?
}

/// Converts the instruction occurrence timeline into immutable geometry buffers.
/// The same snapshot is consumed by Guide previews, recovery boards, and AR.
actor LDrawGeometryEngine {
    private struct Triangle {
        let a: SIMD3<Float>
        let b: SIMD3<Float>
        let c: SIMD3<Float>
        let color: Int
    }

    private let sourceRoot: URL
    private let partPackRoot: URL
    private let maximumOperations: Int
    private let maximumTriangles: Int
    private var textCache: [String: String] = [:]
    private var flattenOperations = 0

    init(
        sourceRoot: URL,
        partPackRoot: URL,
        maximumOperations: Int = InstructionLimits.maximumGeometryOperations,
        maximumTriangles: Int = InstructionLimits.maximumGeometryTriangles
    ) {
        self.sourceRoot = sourceRoot
        self.partPackRoot = partPackRoot
        self.maximumOperations = maximumOperations
        self.maximumTriangles = maximumTriangles
    }

    func snapshot(placements: some Collection<PartPlacement>) throws -> InstructionGeometrySnapshot {
        var triangles: [Triangle] = []
        flattenOperations = 0
        for placement in placements {
            try flatten(
                reference: placement.partReference,
                transform: placement.transform,
                inheritedColor: placement.colorCode,
                invertWinding: false,
                depth: 0,
                triangles: &triangles
            )
        }

        let groups = Dictionary(grouping: triangles, by: \.color)
        let buffers = groups.keys.sorted().map { color -> LDrawGeometryBuffer in
            let group = groups[color, default: []]
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            positions.reserveCapacity(group.count * 3)
            normals.reserveCapacity(group.count * 3)
            for triangle in group {
                let normal = simd_normalize(simd_cross(triangle.b - triangle.a, triangle.c - triangle.a))
                positions.append(contentsOf: [triangle.a, triangle.b, triangle.c])
                normals.append(contentsOf: [normal, normal, normal])
            }
            return LDrawGeometryBuffer(
                colorCode: color,
                positions: positions,
                normals: normals,
                indices: positions.indices.map(UInt32.init)
            )
        }

        let allPositions = buffers.flatMap(\.positions)
        let bounds: LDrawBounds? = if let first = allPositions.first {
            allPositions.dropFirst().reduce(
                LDrawBounds(
                    minimum: [Double(first.x), Double(first.y), Double(first.z)],
                    maximum: [Double(first.x), Double(first.y), Double(first.z)]
                )
            ) { bounds, point in
                LDrawBounds(
                    minimum: zip(bounds.minimum, [Double(point.x), Double(point.y), Double(point.z)]).map(min),
                    maximum: zip(bounds.maximum, [Double(point.x), Double(point.y), Double(point.z)]).map(max)
                )
            }
        } else { nil }
        return InstructionGeometrySnapshot(buffers: buffers, bounds: bounds)
    }

    private func flatten(
        reference: String,
        transform: LDrawTransform,
        inheritedColor: Int,
        invertWinding: Bool,
        depth: Int,
        triangles: inout [Triangle]
    ) throws {
        guard depth <= InstructionLimits.maximumRecursionDepth else {
            throw InstructionImportError.limitExceeded("Part geometry recursion exceeds 64 levels.")
        }
        // A depth guard alone cannot stop exponential blow-up: a small DAG that
        // references each child twice per level performs ~2^depth expansions.
        flattenOperations += 1
        guard flattenOperations <= maximumOperations else {
            throw InstructionImportError.limitExceeded("Part geometry expansion exceeds \(maximumOperations) subfile operations.")
        }
        let normalized = try LDrawInstructionParser.normalizeReference(reference)
        let text = try loadText(reference: normalized)
        var pendingInvert = false
        var counterClockwise = true
        let mirrored = determinant(transform) < 0

        for line in LDrawInstructionParser.splitLines(text) {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let type = tokens.first else { continue }
            if type == "0", tokens.count >= 3, tokens[1].uppercased() == "BFC" {
                let values = tokens.dropFirst(2).map { $0.uppercased() }
                if values.contains("INVERTNEXT") { pendingInvert.toggle() }
                if values.contains("CCW") { counterClockwise = true }
                if values.contains("CW") { counterClockwise = false }
                continue
            }
            if type == "1", tokens.count >= 15,
               let color = LDrawInstructionParser.colorCode(tokens[1]),
               let child = Self.transform(tokens: tokens) {
                let childReference = tokens.dropFirst(14).joined(separator: " ")
                let childColor = color == 16 ? inheritedColor : color
                try flatten(
                    reference: childReference,
                    transform: transform.multiplied(by: child),
                    inheritedColor: childColor,
                    invertWinding: invertWinding != pendingInvert,
                    depth: depth + 1,
                    triangles: &triangles
                )
                pendingInvert = false
                continue
            }
            if type == "3", tokens.count >= 11,
               let color = LDrawInstructionParser.colorCode(tokens[1]),
               let a = Self.point(tokens, 2), let b = Self.point(tokens, 5), let c = Self.point(tokens, 8) {
                let flipped = (invertWinding != mirrored) != (!counterClockwise)
                try appendTriangle(a, b, c, color: color == 16 ? inheritedColor : color, transform: transform, flipped: flipped, to: &triangles)
            } else if type == "4", tokens.count >= 14,
                      let color = LDrawInstructionParser.colorCode(tokens[1]),
                      let a = Self.point(tokens, 2), let b = Self.point(tokens, 5),
                      let c = Self.point(tokens, 8), let d = Self.point(tokens, 11) {
                let resolved = color == 16 ? inheritedColor : color
                let flipped = (invertWinding != mirrored) != (!counterClockwise)
                try appendTriangle(a, b, c, color: resolved, transform: transform, flipped: flipped, to: &triangles)
                try appendTriangle(a, c, d, color: resolved, transform: transform, flipped: flipped, to: &triangles)
            }
        }
    }

    private func appendTriangle(
        _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
        color: Int, transform: LDrawTransform, flipped: Bool, to triangles: inout [Triangle]
    ) throws {
        guard triangles.count < maximumTriangles else {
            throw InstructionImportError.limitExceeded("Part geometry exceeds \(maximumTriangles) triangles.")
        }
        let pa = worldPoint(a, transform: transform)
        let pb = worldPoint(b, transform: transform)
        let pc = worldPoint(c, transform: transform)
        // `worldPoint` folds in a constant Y flip — a reflection (determinant
        // −1) that inverts handedness on top of the placement-matrix winding
        // decision. Emit the reversed vertex order in the nominal case so a
        // BFC-CCW source triangle stays counter-clockwise seen from outside
        // in world space, keeping single-sided materials front-facing.
        triangles.append(flipped ? Triangle(a: pa, b: pb, c: pc, color: color) : Triangle(a: pa, b: pc, c: pb, color: color))
    }

    private func loadText(reference: String) throws -> String {
        if let cached = textCache[reference] { return cached }
        let candidates = [
            sourceRoot.appendingPathComponent(reference),
            partPackRoot.appendingPathComponent("parts/\(reference)"),
            partPackRoot.appendingPathComponent("p/\(reference)"),
            partPackRoot.appendingPathComponent("models/\(reference)")
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw InstructionImportError.invalidDocument("LDraw geometry ‘\(reference)’ is missing from the imported source and pinned part pack.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw InstructionImportError.invalidDocument("LDraw geometry ‘\(reference)’ is not valid text.")
        }
        textCache[reference] = text
        return text
    }

    private func worldPoint(_ point: SIMD3<Double>, transform: LDrawTransform) -> SIMD3<Float> {
        // Fixed physical frame: 1 LDU = 0.4 mm, with LDraw Y inverted.
        SIMD3(
            Float(transform.a * point.x + transform.b * point.y + transform.c * point.z + transform.x) * 0.0004,
            Float(-(transform.d * point.x + transform.e * point.y + transform.f * point.z + transform.y)) * 0.0004,
            Float(transform.g * point.x + transform.h * point.y + transform.i * point.z + transform.z) * 0.0004
        )
    }

    private func determinant(_ t: LDrawTransform) -> Double {
        t.a * (t.e * t.i - t.f * t.h) - t.b * (t.d * t.i - t.f * t.g) + t.c * (t.d * t.h - t.e * t.g)
    }

    private static func transform(tokens: [String]) -> LDrawTransform? {
        guard let x = Double(tokens[2]), let y = Double(tokens[3]), let z = Double(tokens[4]),
              let a = Double(tokens[5]), let b = Double(tokens[6]), let c = Double(tokens[7]),
              let d = Double(tokens[8]), let e = Double(tokens[9]), let f = Double(tokens[10]),
              let g = Double(tokens[11]), let h = Double(tokens[12]), let i = Double(tokens[13]) else { return nil }
        return LDrawTransform(x: x, y: y, z: z, a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i)
    }

    private static func point(_ tokens: [String], _ start: Int) -> SIMD3<Double>? {
        guard let x = Double(tokens[start]), let y = Double(tokens[start + 1]), let z = Double(tokens[start + 2]) else { return nil }
        return SIMD3(x, y, z)
    }
}
