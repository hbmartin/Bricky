import simd
import XCTest
@testable import Bricky

/// The colour term's authority over the verifier, on ideal colour painted
/// from a tag render of the physical scene (mechanics only; ADR 0014).
/// Shadow changes nothing, Block only takes a complete away, Full may only
/// corroborate a marginal delta that depth alone calls present, and colour
/// never completes anything depth does not support.
final class ColourTermJudgeTests: XCTestCase {
    private let width = 256
    private let height = 192
    private let red = 4, yellow = 14, blue = 1, grey = 71

    private var intrinsics: simd_float3x3 {
        var matrix = matrix_identity_float3x3
        matrix[0][0] = 210
        matrix[1][1] = 210
        matrix[2][0] = 128
        matrix[2][1] = 96
        return matrix
    }

    private var table: ColourTable {
        ColourTable(definitions: [
            red: .init(code: red, name: "Red", rgb: 0xC91A09, edgeRGB: nil, alpha: 255, finish: .plastic),
            yellow: .init(code: yellow, name: "Yellow", rgb: 0xF2CD37, edgeRGB: nil, alpha: 255, finish: .plastic),
            blue: .init(code: blue, name: "Blue", rgb: 0x0055BF, edgeRGB: nil, alpha: 255, finish: .plastic),
            grey: .init(code: grey, name: "Grey", rgb: 0xA0A5A9, edgeRGB: nil, alpha: 255, finish: .plastic)
        ])
    }

    private func box(_ minimum: SIMD3<Float>, _ maximum: SIMD3<Float>, colour: Int) -> LDrawGeometryBuffer {
        var positions: [SIMD3<Float>] = []
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            positions.append(contentsOf: [a, b, c, a, c, d])
        }
        let (x0, y0, z0) = (minimum.x, minimum.y, minimum.z)
        let (x1, y1, z1) = (maximum.x, maximum.y, maximum.z)
        face(SIMD3(x0, y1, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1))
        face(SIMD3(x0, y0, z0), SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y0, z0))
        face(SIMD3(x0, y0, z1), SIMD3(x0, y1, z1), SIMD3(x1, y1, z1), SIMD3(x1, y0, z1))
        face(SIMD3(x0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x0, y1, z0))
        face(SIMD3(x1, y0, z0), SIMD3(x1, y0, z1), SIMD3(x1, y1, z1), SIMD3(x1, y1, z0))
        face(SIMD3(x0, y0, z0), SIMD3(x0, y1, z0), SIMD3(x0, y1, z1), SIMD3(x0, y0, z1))
        return LDrawGeometryBuffer(
            colorCode: colour, positions: positions,
            normals: Array(repeating: SIMD3(0, 1, 0), count: positions.count),
            indices: Array(0..<UInt32(positions.count))
        )
    }

    /// The built base: red on the left half, yellow on the right.
    private var base: [LDrawGeometryBuffer] {
        [
            box(SIMD3(0, 0, 0), SIMD3(0.064, 0.0384, 0.064), colour: red),
            box(SIMD3(0.064, 0, 0), SIMD3(0.128, 0.0384, 0.064), colour: yellow)
        ]
    }

    /// The step's delta, spanning both base colours. A 1.92 cm brick is
    /// strongly detectable; a 3 mm sliver (a plate) is marginal from here.
    private func delta(height: Float = 0.0192, colour: Int? = nil) -> LDrawGeometryBuffer {
        box(SIMD3(0.048, 0.0384, 0.016), SIMD3(0.080, 0.0384 + height, 0.048), colour: colour ?? blue)
    }

    private var tableTop: LDrawGeometryBuffer {
        LDrawGeometryBuffer(
            colorCode: grey,
            positions: [
                SIMD3(-0.25, 0, -0.25), SIMD3(0.4, 0, -0.25), SIMD3(0.4, 0, 0.4),
                SIMD3(-0.25, 0, -0.25), SIMD3(0.4, 0, 0.4), SIMD3(-0.25, 0, 0.4)
            ],
            normals: Array(repeating: SIMD3(0, 1, 0), count: 6), indices: [0, 1, 2, 3, 4, 5]
        )
    }

    private var worldFromCamera: simd_float4x4 {
        let eye = SIMD3<Float>(0.28, 0.40, 0.42), target = SIMD3<Float>(0.064, 0.02, 0.032)
        let zAxis = -normalize(target - eye)
        let xAxis = normalize(cross(SIMD3(0, 1, 0), zAxis))
        let yAxis = cross(zAxis, xAxis)
        return simd_float4x4(columns: (SIMD4(xAxis, 0), SIMD4(yAxis, 0), SIMD4(zAxis, 0), SIMD4(eye, 1)))
    }

    private func registration() -> ModelRegistration {
        ModelRegistration(
            alignmentID: UUID(), worldFromModel: matrix_identity_float4x4, state: .locked,
            quality: RegistrationQuality(rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 2.0),
            fittedStepIndex: 1, timestamp: 0
        )
    }

    private func makeRenderer() throws -> ExpectedDepthRenderer {
        do { return try ExpectedDepthRenderer() } catch { throw XCTSkip("Metal unavailable in this test environment") }
    }

    /// Depth from `depthScene`; colour painted from a tag render of
    /// `colourScene` (defaults to the same physical scene).
    private func frame(
        depthScene: [LDrawGeometryBuffer], colourScene: [LDrawGeometryBuffer]? = nil, timestamp: TimeInterval
    ) async throws -> RegistrationFrameInput {
        let renderer = try makeRenderer()
        let view = worldFromCamera.inverse
        let depthSnapshot = InstructionGeometrySnapshot(buffers: depthScene + [tableTop], bounds: nil)
        let colourSnapshot = InstructionGeometrySnapshot(buffers: (colourScene ?? depthScene) + [tableTop], bounds: nil)
        let rendered = try await renderer.render(
            [DepthRenderRequest(geometry: renderer.prepare(depthSnapshot), viewFromModel: view)],
            tags: [DepthRenderRequest(geometry: renderer.prepare(colourSnapshot, tagged: true), viewFromModel: view)],
            intrinsics: intrinsics, width: width, height: height
        )
        let table = self.table
        var colour = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            let rgb = rendered.tags[0].colourCode(at: index).flatMap { table.entry(for: $0).linear } ?? SIMD3(0.2, 0.2, 0.2)
            for channel in 0..<3 { colour[index * 3 + channel] = Self.encode(rgb[channel]) }
        }
        let depth = rendered.depth[0].depth
        var input = RegistrationFrameInput(
            depth: depth, confidence: .init(repeating: 2, count: width * height),
            rawDepth: depth, rawConfidence: .init(repeating: 2, count: width * height),
            width: width, height: height, depthIntrinsics: intrinsics,
            worldFromCamera: worldFromCamera, timestamp: timestamp
        )
        input.colour = colour
        return input
    }

    private static func encode(_ linear: Float) -> UInt8 {
        let clamped = min(max(linear, 0), 1)
        let srgb = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * Float(pow(Double(clamped), 1 / 2.4)) - 0.055
        return UInt8((srgb * 255).rounded())
    }

    private func geometry(delta: LDrawGeometryBuffer) -> StepGeometry {
        let completed = InstructionGeometrySnapshot(buffers: base, bounds: nil)
        let deltaSnapshot = InstructionGeometrySnapshot(buffers: [delta], bounds: nil)
        let segments = SegmentedGeometry(segments: [base, [delta]])
        return StepGeometry(
            completedSnapshot: completed, deltaSnapshot: deltaSnapshot, segments: segments,
            index: PlacementGeometryIndex.build(transforms: [LDrawTransform(), LDrawTransform()], segments: segments),
            completedPlacements: 0..<1, deltaPlacements: 1..<2
        )
    }

    private func fields(_ v: StepVerification) -> [String] {
        [
            v.stepID, "\(v.verdict)", "\(v.detectability)", "\(v.deltaPixels)", "\(v.framesUsed)",
            "\(v.completeFraction.bitPattern)", "\(v.incompleteFraction.bitPattern)", "\(v.timestamp)",
            "\(String(describing: v.worldFromModel))", "\(String(describing: v.worldFromCamera))"
        ]
    }

    /// Runs `judges` on identical frames and returns each judge's verdicts.
    private func run(
        _ judges: [any StepJudging], authored: LDrawGeometryBuffer,
        depthScene: [LDrawGeometryBuffer], colourScene: [LDrawGeometryBuffer]? = nil, frames: Int = 10
    ) async throws -> [[StepVerification]] {
        for judge in judges { await judge.begin(stepID: "<root>#2", geometry: geometry(delta: authored)) }
        var results = Array(repeating: [StepVerification](), count: judges.count)
        for index in 0..<frames {
            let input = try await frame(depthScene: depthScene, colourScene: colourScene, timestamp: TimeInterval(index) * 0.1)
            for (slot, judge) in judges.enumerated() {
                results[slot].append(try await judge.ingest(frame: input, registration: registration()))
            }
        }
        return results
    }

    private func judge(_ mode: ColourTermMode) throws -> ColourTermJudge {
        try ColourTermJudge(mode: mode, table: table, renderer: makeRenderer())
    }

    func testShadowColourTermIsBitIdenticalFrameByFrame() async throws {
        let renderer = try makeRenderer()
        let shadow = try judge(.shadow)
        for scene in [base + [delta()], base, base + [delta(colour: yellow)]] {
            let results = try await run(
                [try GeometricStepVerifier(renderer: renderer), shadow], authored: delta(), depthScene: scene
            )
            XCTAssertEqual(results[0].map(fields), results[1].map(fields))
        }
        let assessment = await shadow.lastAssessment
        XCTAssertNotNil(assessment, "shadow still assesses")
    }

    func testBlockOnlyTurnsWrongColourCompleteIntoIncomplete() async throws {
        let renderer = try makeRenderer()
        let block = try judge(.blockOnly)
        let shadow = try judge(.shadow)
        let results = try await run(
            [try GeometricStepVerifier(renderer: renderer), shadow, block],
            authored: delta(), depthScene: base + [delta(colour: yellow)]
        )
        XCTAssertEqual(results[0].last?.verdict, .complete, "depth sees the brick")
        XCTAssertEqual(results[1].last?.verdict, .complete, "shadow never changes a verdict")
        XCTAssertEqual(results[2].last?.verdict, .incomplete, "the colour is another one the model uses")
        let assessment = await block.lastAssessment
        XCTAssertEqual(assessment?.status, .disagrees(nearestCode: yellow))

        // The authored colour passes through untouched.
        let right = try await run([try judge(.blockOnly)], authored: delta(), depthScene: base + [delta()])
        XCTAssertEqual(right[0].last?.verdict, .complete)
    }

    func testFullCorroboratesOnlyMarginalDepthPresent() async throws {
        let renderer = try makeRenderer()
        let sliver = delta(height: 0.0030)
        let full = try judge(.full)
        let present = try await run(
            [try GeometricStepVerifier(renderer: renderer), full], authored: sliver, depthScene: base + [sliver]
        )
        let inner = try XCTUnwrap(present[0].last)
        XCTAssertEqual(inner.detectability, .marginal)
        XCTAssertNotEqual(inner.verdict, .complete, "depth alone never completes a marginal delta")
        XCTAssertEqual(present[1].last?.verdict, .complete, "the authored colour corroborates it")

        // Absent: depth cannot tell a 3 mm sliver from the base below,
        // but the colour there is the base's, so nothing corroborates.
        let absent = try await run([try judge(.full)], authored: sliver, depthScene: base)
        XCTAssertNotEqual(absent[0].last?.verdict, .complete)
    }

    func testColourNeverCompletesWithoutDepth() async throws {
        // The brick is missing, but the colour plane shows it as built.
        let results = try await run(
            [try judge(.full)], authored: delta(), depthScene: base, colourScene: base + [delta()]
        )
        XCTAssertNotEqual(results[0].last?.verdict, .complete)
        XCTAssertEqual(results[0].last?.verdict, .incomplete)
    }

    func testModesApplyOnlyTheirAuthority() {
        let verification = StepVerification(
            stepID: "s", verdict: .uncertain(.insufficientEvidence), detectability: .marginal, deltaPixels: 50,
            framesUsed: 10, completeFraction: 0.9, incompleteFraction: 0,
            registrationQuality: RegistrationQuality(rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 2.0), timestamp: 0
        )
        let agrees = ColourAssessment(status: .agrees, groups: [], framesWithColour: 3, framesCalibrated: 3)
        XCTAssertEqual(ColourTermJudge.apply(.shadow, to: verification, assessment: agrees, depthPresentUnderMarginal: true).verdict,
                       .uncertain(.insufficientEvidence))
        XCTAssertEqual(ColourTermJudge.apply(.blockOnly, to: verification, assessment: agrees, depthPresentUnderMarginal: true).verdict,
                       .uncertain(.insufficientEvidence))
        XCTAssertEqual(ColourTermJudge.apply(.full, to: verification, assessment: agrees, depthPresentUnderMarginal: true).verdict,
                       .complete)
        XCTAssertEqual(ColourTermJudge.apply(.full, to: verification, assessment: agrees, depthPresentUnderMarginal: false).verdict,
                       .uncertain(.insufficientEvidence), "agreement without depth presence is nothing")
    }
}
