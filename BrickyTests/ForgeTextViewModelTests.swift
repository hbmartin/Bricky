import XCTest
@testable import Bricky

@MainActor
final class ForgeTextViewModelTests: XCTestCase {

    private func makeVM(pro: Bool) -> ForgeTextViewModel {
        ForgeTextViewModel(isProProvider: { pro })
    }

    /// Polls until generation finishes or times out.
    private func waitForResult(_ vm: ForgeTextViewModel, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.result == nil, vm.errorMessage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testInitialStateBlocksEmptyDescription() {
        let vm = makeVM(pro: true)
        XCTAssertFalse(vm.canGenerate, "Empty description can't generate")
    }

    func testCanGenerateWithDescription() {
        let vm = makeVM(pro: true)
        vm.description = "a red house"
        XCTAssertTrue(vm.canGenerate)
    }

    func testFreeUserLockedToSmall() {
        let vm = makeVM(pro: false)
        XCTAssertTrue(vm.isSizeUnlocked(.small))
        XCTAssertFalse(vm.isSizeUnlocked(.medium))
        XCTAssertFalse(vm.isSizeUnlocked(.large))
    }

    func testProUserUnlocksAllSizes() {
        let vm = makeVM(pro: true)
        XCTAssertTrue(vm.isSizeUnlocked(.medium))
        XCTAssertTrue(vm.isSizeUnlocked(.large))
    }

    func testGenerateProducesResult() async {
        let vm = makeVM(pro: true)
        vm.description = "a green tree"
        vm.generate()
        await waitForResult(vm)
        XCTAssertNotNil(vm.result, "Generation should produce a set")
        XCTAssertEqual(vm.matchedTemplateName, "Tree")
        XCTAssertGreaterThan(vm.result?.brickCount ?? 0, 0)
    }

    func testResultIsSavedToStore() async {
        let vm = makeVM(pro: true)
        vm.description = "a blue robot"
        vm.generate()
        await waitForResult(vm)
        guard let id = vm.result?.id else { return XCTFail("No result") }
        XCTAssertTrue(GeneratedSetStore.shared.contains(id))
    }
}
