import XCTest
import Combine
import UIKit
@testable import Bricky

/// Tests for `MosaicGeneratorViewModel`, which drives mosaic generation entirely
/// on-device via `MosaicEngine` — there is no backend and no network stubbing.
@MainActor
final class MosaicGeneratorViewModelTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func solidImage(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeViewModel(isPro: Bool = true) -> MosaicGeneratorViewModel {
        MosaicGeneratorViewModel(isProProvider: { isPro })
    }

    /// Wait until the view model reaches `.completed` or `.failed`.
    private func awaitTerminalPhase(_ viewModel: MosaicGeneratorViewModel) async {
        let expectation = expectation(description: "terminal phase")
        viewModel.$phase
            .sink { phase in
                switch phase {
                case .completed, .failed:
                    expectation.fulfill()
                default:
                    break
                }
            }
            .store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 20)
    }

    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertFalse(vm.canGenerate)
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.result)
        XCTAssertNil(vm.thumbnail)
        XCTAssertNil(vm.partsList)
    }

    func testCanGenerateRequiresSourceImage() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.canGenerate)
        vm.sourceImage = solidImage(.red)
        XCTAssertTrue(vm.canGenerate)
    }

    func testGenerateProducesCompletedResult() async throws {
        let vm = makeViewModel()
        vm.selectedPreset = .small
        vm.sourceImage = solidImage(
            UIColor(red: 0xC9 / 255.0, green: 0x1A / 255.0, blue: 0x09 / 255.0, alpha: 1)
        )

        vm.generate()
        await awaitTerminalPhase(vm)

        XCTAssertEqual(vm.phase, .completed)
        let result = try XCTUnwrap(vm.result)
        XCTAssertGreaterThan(result.brickCount, 0)
        XCTAssertEqual(result.studCount, MosaicGridPreset.small.studs * MosaicGridPreset.small.studs)
        XCTAssertNotNil(vm.thumbnail)
        XCTAssertEqual(vm.snappedGrid?.width, MosaicGridPreset.small.studs)

        let parts = try XCTUnwrap(vm.partsList)
        XCTAssertEqual(parts.paletteId, "mvp-v1")
    }

    func testArtifactFilesAreWrittenToDisk() async throws {
        let vm = makeViewModel()
        vm.selectedPreset = .small
        vm.sourceImage = solidImage(.blue)

        vm.generate()
        await awaitTerminalPhase(vm)

        let ldr = await vm.prepareArtifactFile(kind: .ldraw)
        let pdf = await vm.prepareArtifactFile(kind: .pdf)
        let ldrURL = try XCTUnwrap(ldr)
        let pdfURL = try XCTUnwrap(pdf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ldrURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertEqual(ldrURL.lastPathComponent, "model.ldr")
        XCTAssertEqual(pdfURL.lastPathComponent, "instructions.pdf")
    }

    func testPrepareArtifactFileReturnsNilWithoutResult() async {
        let vm = makeViewModel()
        let url = await vm.prepareArtifactFile(kind: .ldraw)
        XCTAssertNil(url)
    }

    func testResetClearsState() async {
        let vm = makeViewModel()
        vm.selectedPreset = .small
        vm.sourceImage = solidImage(.green)
        vm.generate()
        await awaitTerminalPhase(vm)

        vm.reset()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.sourceImage)
        XCTAssertNil(vm.result)
        XCTAssertNil(vm.thumbnail)
        XCTAssertNil(vm.partsList)
        XCTAssertNil(vm.snappedGrid)
    }
}
