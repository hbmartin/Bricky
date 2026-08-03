import Foundation
import UIKit
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

    func testRejectsUnsteppedRoot() throws {
        let data = try invalidFixture(named: "unstepped.ldr")
        XCTAssertThrowsError(try LDrawInstructionParser().parse(
            files: [.init(relativePath: "unstepped.ldr", data: data)],
            rootRelativePath: "unstepped.ldr"
        )) { XCTAssertEqual($0 as? InstructionImportError, .noAuthoredSteps) }
    }

    func testRejectsTraversal() throws {
        let data = try invalidFixture(named: "path-traversal.ldr")
        XCTAssertThrowsError(try LDrawInstructionParser().parse(
            files: [.init(relativePath: "path-traversal.ldr", data: data)],
            rootRelativePath: "path-traversal.ldr"
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

    func testRejectsCycle() throws {
        let data = try invalidFixture(named: "cycle.mpd")
        XCTAssertThrowsError(try LDrawInstructionParser().parse(
            files: [.init(relativePath: "cycle.mpd", data: data)],
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

    func testBOMCountsEachInstanceOfARepeatedSteppedSubmodel() throws {
        let source = """
        0 FILE main.ldr
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 module.ldr
        0 STEP
        1 1 100 0 0 1 0 0 0 1 0 0 0 1 module.ldr
        0 STEP
        0 FILE module.ldr
        1 16 10 0 0 1 0 0 0 1 0 0 0 1 3005.dat
        0 STEP
        """
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "repeated.mpd", data: Data(source.utf8))],
            rootRelativePath: "repeated.mpd"
        )

        XCTAssertEqual(document.billOfMaterials, [
            BOMEntry(partReference: "3005.dat", colorCode: 1, quantity: 1),
            BOMEntry(partReference: "3005.dat", colorCode: 4, quantity: 1)
        ])
    }

    func testDirectColourPlacementImportsWithoutDiagnostics() throws {
        let source = "1 0x2FF0000 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat\n0 STEP\n"
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "direct.ldr", data: Data(source.utf8))],
            rootRelativePath: "direct.ldr"
        )

        XCTAssertEqual(document.diagnostics, [])
        XCTAssertEqual(document.rootSection?.steps.first?.directPlacements.first?.colorCode, 0x2FF0000)
        XCTAssertEqual(document.billOfMaterials, [BOMEntry(partReference: "3005.dat", colorCode: 0x2FF0000, quantity: 1)])
    }

    func testDirectColourBypassesPaletteAndUsesLow24Bits() {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(LDrawPalette.color(0x2FF8800).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 1, accuracy: 0.001)
        XCTAssertEqual(green, CGFloat(0x88) / 255, accuracy: 0.001)
        XCTAssertEqual(blue, 0, accuracy: 0.001)
        XCTAssertEqual(alpha, 1)
    }

    func testRejectsNegativeOversizedAndMalformedColourTokens() throws {
        for token in ["-1", "9999999999", "0x5000000", "0xFFFFFFFF"] {
            let source = "1 \(token) 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat\n0 STEP\n"
            let document = try LDrawInstructionParser().parse(
                files: [.init(relativePath: "invalid-color.ldr", data: Data(source.utf8))],
                rootRelativePath: "invalid-color.ldr"
            )
            XCTAssertEqual(document.diagnostics.first?.code, "invalid-type-1", "Token should fail: \(token)")
            XCTAssertTrue(document.billOfMaterials.isEmpty)
        }
    }

    func testCRLFSourceReportsSameLineNumbersAsLF() throws {
        let lines = [
            "0 FILE main.ldr",
            "1 4 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat",
            "1 4 invalid placement",
            "0 STEP"
        ]
        let unixDocument = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "model.mpd", data: Data(lines.joined(separator: "\n").utf8))],
            rootRelativePath: "model.mpd"
        )
        let windowsDocument = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "model.mpd", data: Data(lines.joined(separator: "\r\n").utf8))],
            rootRelativePath: "model.mpd"
        )

        XCTAssertEqual(windowsDocument.diagnostics.map(\.lineNumber), unixDocument.diagnostics.map(\.lineNumber))
        XCTAssertEqual(windowsDocument.diagnostics.first?.lineNumber, 3)
        XCTAssertEqual(
            windowsDocument.rootSection?.steps.map { [$0.sourceStartLine, $0.sourceEndLine] },
            unixDocument.rootSection?.steps.map { [$0.sourceStartLine, $0.sourceEndLine] }
        )
        XCTAssertEqual(windowsDocument.rootSection?.steps.first?.directPlacements.first?.sourceLine, 2)
    }

    func testCommentOnlyPreambleAboveFirstFileDirectiveDoesNotBecomeRoot() throws {
        let source = """
        0 Licensed under CC BY 4.0

        0 FILE main.ldr
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat
        0 STEP
        """
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "licensed.mpd", data: Data(source.utf8))],
            rootRelativePath: "licensed.mpd"
        )

        XCTAssertEqual(document.rootSectionName, "main.ldr")
        XCTAssertEqual(document.rootSection?.steps.count, 1)
    }

    private func invalidFixture(named name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/InstructionPipeline/fixtures/invalid/\(name)")
        return try XCTUnwrap(
            FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil,
            "Missing invalid fixture at \(url.path)",
            file: file,
            line: line
        )
    }
}
