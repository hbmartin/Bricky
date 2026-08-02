import XCTest
@testable import Bricky

final class SwiftParityTests: XCTestCase {
    func testNativeParserMatchesNormalizedPyLDrawSchemaV1() throws {
        for fixture in ["simple", "nested-rotstep", "lpub-camera"] {
            try assertParity(fixture)
        }
    }

    private func assertParity(_ fixture: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Tools/InstructionPipeline/fixtures/valid")
        let sourceURL = ["ldr", "mpd"].map { fixtures.appendingPathComponent("\(fixture).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }!
        let oracleURL = root.appendingPathComponent("Tools/InstructionPipeline/golden/\(fixture)/manifest.json")
        let oracle = try JSONDecoder().decode(OracleManifest.self, from: Data(contentsOf: oracleURL))
        XCTAssertEqual(oracle.schemaVersion, 1, file: file, line: line)
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: sourceURL.lastPathComponent, data: try Data(contentsOf: sourceURL))],
            rootRelativePath: sourceURL.lastPathComponent
        )

        XCTAssertEqual(document.rootSectionName, oracle.rootSection.lowercased(), file: file, line: line)
        XCTAssertEqual(document.orphanSectionNames, oracle.orphanSections.map { $0.lowercased() }, file: file, line: line)
        XCTAssertEqual(document.sections.map(\.normalizedName), oracle.sections.map { $0.name.lowercased() }, file: file, line: line)

        for (nativeSection, oracleSection) in zip(document.sections, oracle.sections) {
            XCTAssertEqual(nativeSection.isRoot, oracleSection.isRoot, file: file, line: line)
            XCTAssertEqual(nativeSection.references, oracleSection.references.map { $0.lowercased() }, file: file, line: line)
            XCTAssertEqual(nativeSection.steps.count, oracleSection.steps.count, file: file, line: line)

            for (nativeStep, oracleStep) in zip(nativeSection.steps, oracleSection.steps) {
                XCTAssertEqual(nativeStep.number, oracleStep.number, file: file, line: line)
                XCTAssertEqual([nativeStep.sourceStartLine, nativeStep.sourceEndLine], oracleStep.sourceLines, file: file, line: line)
                XCTAssertEqual(nativeStep.directPlacements.count, oracleStep.directPlacements.count, file: file, line: line)
                for (native, expected) in zip(nativeStep.directPlacements, oracleStep.directPlacements) {
                    XCTAssertEqual(native.partReference, expected.reference.lowercased(), file: file, line: line)
                    XCTAssertEqual(native.colorCode, expected.colour.code, file: file, line: line)
                    XCTAssertEqual(native.sourceSection, expected.sourceSection.lowercased(), file: file, line: line)
                    XCTAssertEqual(native.sourceLine, expected.sourceLine, file: file, line: line)
                    XCTAssertEqual([native.transform.x, native.transform.y, native.transform.z], expected.position, file: file, line: line)
                    XCTAssertEqual(
                        [[native.transform.a, native.transform.b, native.transform.c],
                         [native.transform.d, native.transform.e, native.transform.f],
                         [native.transform.g, native.transform.h, native.transform.i]],
                        expected.matrix,
                        file: file,
                        line: line
                    )
                }
                assertRotation(nativeStep.rotationCue, oracleStep.rotation, file: file, line: line)
                assertCamera(nativeStep.cameraCue, oracleStep.camera, file: file, line: line)
            }
        }
    }

    private func assertRotation(
        _ native: RotationCue?,
        _ oracle: OracleRotation?,
        file: StaticString,
        line: UInt
    ) {
        guard let oracle else {
            XCTAssertNil(native, file: file, line: line)
            return
        }
        XCTAssertEqual([native?.x, native?.y, native?.z].compactMap { $0 }, oracle.angles, file: file, line: line)
        let mode: String? = switch native?.mode {
        case .relative: "REL"
        case .absolute: "ABS"
        case .additive: "ADD"
        case .end: "END"
        case nil: nil
        }
        XCTAssertEqual(mode, oracle.mode, file: file, line: line)
    }

    private func assertCamera(
        _ nativeValue: CameraCue?,
        _ oracle: OracleCamera,
        file: StaticString,
        line: UInt
    ) {
        let native = nativeValue ?? CameraCue()
        XCTAssertEqual(native.anglePreset, oracle.anglePreset, file: file, line: line)
        XCTAssertEqual(native.angles, oracle.angles, file: file, line: line)
        XCTAssertEqual(native.position, oracle.position, file: file, line: line)
        XCTAssertEqual(native.target, oracle.target, file: file, line: line)
        XCTAssertEqual(native.upVector, oracle.upVector, file: file, line: line)
        XCTAssertEqual(native.distance, oracle.distance, file: file, line: line)
        XCTAssertEqual(native.fieldOfView, oracle.fieldOfView, file: file, line: line)
        XCTAssertEqual(native.name, oracle.name, file: file, line: line)
        XCTAssertEqual(native.orthographic, oracle.orthographic, file: file, line: line)
        XCTAssertEqual(native.nearClip, oracle.nearClip, file: file, line: line)
        XCTAssertEqual(native.farClip, oracle.farClip, file: file, line: line)
    }
}

private struct OracleManifest: Decodable {
    let schemaVersion: Int
    let rootSection: String
    let orphanSections: [String]
    let sections: [OracleSection]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rootSection = "root_section"
        case orphanSections = "orphan_sections"
        case sections
    }
}

private struct OracleSection: Decodable {
    let isRoot: Bool
    let name: String
    let references: [String]
    let steps: [OracleStep]

    enum CodingKeys: String, CodingKey {
        case isRoot = "is_root"
        case name, references, steps
    }
}

private struct OracleStep: Decodable {
    let number: Int
    let sourceLines: [Int]
    let directPlacements: [OraclePlacement]
    let rotation: OracleRotation?
    let camera: OracleCamera

    enum CodingKeys: String, CodingKey {
        case number
        case sourceLines = "source_lines"
        case directPlacements = "direct_placements"
        case rotation, camera
    }
}

private struct OraclePlacement: Decodable {
    struct Colour: Decodable { let code: Int }
    let colour: Colour
    let matrix: [[Double]]
    let position: [Double]
    let reference: String
    let sourceLine: Int
    let sourceSection: String

    enum CodingKeys: String, CodingKey {
        case colour, matrix, position, reference
        case sourceLine = "source_line"
        case sourceSection = "source_section"
    }
}

private struct OracleRotation: Decodable {
    let mode: String
    let angles: [Double]
}

private struct OracleCamera: Decodable {
    let anglePreset: String?
    let angles: [Double]?
    let position: [Double]?
    let target: [Double]?
    let upVector: [Double]?
    let distance: Double?
    let fieldOfView: Double?
    let name: String?
    let orthographic: Bool?
    let nearClip: Double?
    let farClip: Double?

    enum CodingKeys: String, CodingKey {
        case anglePreset = "angle_preset"
        case angles, position, target, distance, name, orthographic
        case upVector = "up_vector"
        case fieldOfView = "fov"
        case nearClip = "z_near"
        case farClip = "z_far"
    }
}
