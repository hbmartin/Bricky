import XCTest
@testable import Bricky

@MainActor
final class ForgeTextViewModelTests: XCTestCase {

    /// Stub cloud service so view-model tests never touch the network.
    private struct StubForgeService: SetForgeTextService {
        let result: Result<VoxelModel, SetForgeTextError>
        func generateModel(prompt: String, size: VoxelModel.Size, entitlementToken: String) async throws -> VoxelModel {
            try result.get()
        }
    }

    private func solidModel(color: LegoColor = .green) -> VoxelModel {
        var voxels: [Voxel] = []
        for x in 0..<3 { for y in 0..<2 { for z in 0..<3 {
            voxels.append(Voxel(x: x, y: y, z: z, color: color))
        } } }
        return VoxelModel(width: 3, height: 2, depth: 3, voxels: voxels, source: .text, subject: "Cloud")
    }

    /// Default VM: no cloud service, so it always uses the on-device library.
    private func makeVM(pro: Bool) -> ForgeTextViewModel {
        ForgeTextViewModel(isProProvider: { pro }, cloudService: nil, entitlementProvider: { nil })
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

    func testCloudPathUsedWhenEntitled() async {
        let vm = ForgeTextViewModel(
            isProProvider: { true },
            cloudService: StubForgeService(result: .success(solidModel())),
            entitlementProvider: { "tok" }
        )
        vm.description = "a detailed monkey"
        vm.generate()
        await waitForResult(vm)
        XCTAssertNotNil(vm.result)
        XCTAssertEqual(vm.matchedTemplateName, "AI-generated",
                       "An entitled cloud generation should be labelled AI-generated")
    }

    func testFallsBackToTemplateWhenCloudFails() async {
        let vm = ForgeTextViewModel(
            isProProvider: { true },
            cloudService: StubForgeService(result: .failure(.offline)),
            entitlementProvider: { "tok" }
        )
        vm.description = "a green tree"
        vm.generate()
        await waitForResult(vm)
        XCTAssertNotNil(vm.result, "Cloud failure must fall back to the on-device model")
        XCTAssertEqual(vm.matchedTemplateName, "Tree")
    }

    func testNoEntitlementUsesTemplate() async {
        let vm = ForgeTextViewModel(
            isProProvider: { true },
            cloudService: StubForgeService(result: .success(solidModel())),
            entitlementProvider: { nil } // no token → skip cloud
        )
        vm.description = "a green tree"
        vm.generate()
        await waitForResult(vm)
        XCTAssertEqual(vm.matchedTemplateName, "Tree")
    }
}
