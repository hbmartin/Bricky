import XCTest
@testable import Bricky

final class InstructionParserTests: XCTestCase {
    func testParsesMPDSectionsStepsRotationAndOrphan() throws {
        let source = """
        0 FILE main.ldr
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 child.ldr
        0 STEP
        1 1 40 0 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 ROTSTEP 0 90 0 ADD
        0 FILE child.ldr
        1 14 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat
        0 STEP
        0 FILE orphan.ldr
        1 2 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat
        0 STEP
        """
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "model.mpd", data: Data(source.utf8))],
            rootRelativePath: "model.mpd"
        )
        XCTAssertEqual(document.rootSectionName, "main.ldr")
        XCTAssertEqual(document.rootSection?.steps.count, 2)
        XCTAssertEqual(document.rootSection?.steps[1].rotationCue?.mode, .additive)
        XCTAssertEqual(document.orphanSectionNames, ["orphan.ldr"])
    }

    func testRejectsUnsteppedRoot() {
        let source = "1 4 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat\n"
        XCTAssertThrowsError(try LDrawInstructionParser().parse(
            files: [.init(relativePath: "model.ldr", data: Data(source.utf8))],
            rootRelativePath: "model.ldr"
        )) { XCTAssertEqual($0 as? InstructionImportError, .noAuthoredSteps) }
    }

    func testRejectsTraversal() {
        let source = "1 4 0 0 0 1 0 0 0 1 0 0 0 1 ../child.ldr\n0 STEP\n"
        XCTAssertThrowsError(try LDrawInstructionParser().parse(
            files: [.init(relativePath: "model.ldr", data: Data(source.utf8))],
            rootRelativePath: "model.ldr"
        ))
    }

    func testRejectsAbsoluteReferencesBeforeCanonicalization() {
        for reference in ["/private/custom.ldr", "\\private\\custom.ldr", "C:\\custom.ldr"] {
            let source = "1 4 0 0 0 1 0 0 0 1 0 0 0 1 \(reference)\n0 STEP\n"
            XCTAssertThrowsError(try LDrawInstructionParser().parse(
                files: [.init(relativePath: "model.ldr", data: Data(source.utf8))],
                rootRelativePath: "model.ldr"
            ), "Reference should be rejected: \(reference)")
        }
    }

    func testRejectsCycle() {
        let source = """
        0 FILE main.ldr
        1 16 0 0 0 1 0 0 0 1 0 0 0 1 child.ldr
        0 STEP
        0 FILE child.ldr
        1 16 0 0 0 1 0 0 0 1 0 0 0 1 main.ldr
        0 STEP
        """
        XCTAssertThrowsError(try LDrawInstructionParser().parse(
            files: [.init(relativePath: "cycle.mpd", data: Data(source.utf8))],
            rootRelativePath: "cycle.mpd"
        ))
    }

    func testUnsteppedEmbeddedGeometryRemainsAnAtomicCustomPart() throws {
        let source = """
        0 FILE main.ldr
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 custom.dat
        0 STEP
        0 FILE custom.dat
        3 16 0 0 0 10 0 0 0 10 0
        """
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "custom.mpd", data: Data(source.utf8))],
            rootRelativePath: "custom.mpd"
        )

        XCTAssertEqual(document.sections.map(\.normalizedName), ["main.ldr"])
        XCTAssertEqual(document.orphanSectionNames, [])
        XCTAssertEqual(document.rootSection?.steps[0].directPlacements[0].partReference, "custom.dat")
        XCTAssertTrue(document.rootSection?.steps[0].directPlacements[0].isSubmodelReference == true)
    }

    func testMalformedPlacementProducesSourceDiagnostic() throws {
        let source = "1 4 invalid placement\n0 STEP\n"
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "malformed.ldr", data: Data(source.utf8))],
            rootRelativePath: "malformed.ldr"
        )

        XCTAssertTrue(document.hasErrors)
        XCTAssertEqual(document.diagnostics.first?.code, "invalid-type-1")
        XCTAssertEqual(document.diagnostics.first?.lineNumber, 1)
    }

    func testRejectsUnresolvedModelReference() {
        let source = "1 4 0 0 0 1 0 0 0 1 0 0 0 1 missing.ldr\n0 STEP\n"
        XCTAssertThrowsError(try LDrawInstructionParser().parse(
            files: [.init(relativePath: "model.ldr", data: Data(source.utf8))],
            rootRelativePath: "model.ldr"
        )) { error in
            guard case InstructionImportError.unresolvedReference("missing.ldr", section: "model.ldr", line: 1) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsLinesOver64KB() {
        let source = String(repeating: "0", count: InstructionLimits.maximumLineBytes + 1) + "\n"
        XCTAssertThrowsError(try LDrawInstructionParser().parse(
            files: [.init(relativePath: "oversized.ldr", data: Data(source.utf8))],
            rootRelativePath: "oversized.ldr"
        )) { error in
            XCTAssertEqual(error as? InstructionImportError, .lineTooLong(file: "oversized.ldr", line: 1))
        }
    }
}
