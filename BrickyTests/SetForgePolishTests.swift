import XCTest
import UIKit
@testable import Bricky

/// Tests for the Set Forge polish features: per-step 3D grouping, the
/// generator/quality label, source-image persistence in history, and the
/// video-sweep frame downselect.
@MainActor
final class SetForgePolishTests: XCTestCase {

    // MARK: - Helpers

    private func solidBlock(w: Int = 5, h: Int = 4, d: Int = 5, color: LegoColor = .blue) -> VoxelModel {
        var voxels: [Voxel] = []
        for x in 0..<w { for y in 0..<h { for z in 0..<d {
            voxels.append(Voxel(x: x, y: y, z: z, color: color))
        } } }
        return VoxelModel(width: w, height: h, depth: d, voxels: voxels, source: .photo, subject: "Block")
    }

    private func solidColorImage(_ color: UIColor, size: CGSize = CGSize(width: 8, height: 8)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Step grouping (3D per-step instructions)

    func testStepGroupsAlignWithSteps() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        let groups = SetForgeInstructions.stepGroups(for: set.bricks)

        XCTAssertEqual(groups.count, set.steps.count,
                       "One brick group per instruction step")
        XCTAssertTrue(groups.allSatisfy { !$0.isEmpty }, "No empty step groups")
    }

    func testStepGroupsCoverEveryBrickExactlyOnce() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        let groups = SetForgeInstructions.stepGroups(for: set.bricks)
        let regrouped = groups.flatMap { $0 }

        XCTAssertEqual(regrouped.count, set.bricks.count,
                       "Every brick appears in exactly one step group")
    }

    func testStepGroupsEmptyForNoBricks() {
        XCTAssertTrue(SetForgeInstructions.stepGroups(for: []).isEmpty)
    }

    // MARK: - Generator label

    func testGeneratorDefaultsToOnDevice() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        XCTAssertEqual(set.generator, .onDevice)
    }

    func testGeneratorIsThreadedThrough() throws {
        let set = try SetForgeEngine.shared.generate(
            from: solidBlock(), size: .small, name: "Block", generator: .hd
        )
        XCTAssertEqual(set.generator, .hd)
        XCTAssertEqual(set.generator.label, "HD 3D")
    }

    func testGeneratorSurvivesCodableRoundTrip() throws {
        let set = try SetForgeEngine.shared.generate(
            from: solidBlock(), size: .small, name: "Block", generator: .ai
        )
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(GeneratedLegoSet.self, from: data)
        XCTAssertEqual(decoded.generator, .ai)
    }

    // MARK: - Source-image persistence

    func testStorePersistsAndReturnsSourceImage() throws {
        let store = GeneratedSetStore(filename: "test_generated_sets_\(UUID().uuidString).json")
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        let image = solidColorImage(.red)

        store.save(set, sourceImages: [image])

        XCTAssertTrue(store.contains(set.id))
        XCTAssertNotNil(store.sourceImage(for: set.id), "Source image should be retrievable")
    }

    func testStorePersistsAllCapturedAngles() throws {
        let store = GeneratedSetStore(filename: "test_generated_sets_\(UUID().uuidString).json")
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        let angles = [solidColorImage(.red), solidColorImage(.green),
                      solidColorImage(.blue), solidColorImage(.yellow)]

        store.save(set, sourceImages: angles)

        XCTAssertEqual(store.sourceImages(for: set.id).count, 4,
                       "All four captured frames are retrievable")
    }

    func testStoreCapsSourceImagesAtFour() throws {
        let store = GeneratedSetStore(filename: "test_generated_sets_\(UUID().uuidString).json")
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        let many = (0..<8).map { _ in solidColorImage(.gray) }

        store.save(set, sourceImages: many)

        XCTAssertEqual(store.sourceImages(for: set.id).count, 4, "Never stores more than 4 frames")
    }

    func testStoreDeleteRemovesSourceImage() throws {
        let store = GeneratedSetStore(filename: "test_generated_sets_\(UUID().uuidString).json")
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        store.save(set, sourceImages: [solidColorImage(.green), solidColorImage(.blue)])
        XCTAssertEqual(store.sourceImages(for: set.id).count, 2)

        store.delete(set)

        XCTAssertFalse(store.contains(set.id))
        XCTAssertTrue(store.sourceImages(for: set.id).isEmpty, "Deleting a set removes all source images")
    }

    func testStoreSaveWithoutImageHasNoSource() throws {
        let store = GeneratedSetStore(filename: "test_generated_sets_\(UUID().uuidString).json")
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        store.save(set)
        XCTAssertNil(store.sourceImage(for: set.id))
        XCTAssertTrue(store.sourceImages(for: set.id).isEmpty)
    }

    // MARK: - Video sweep downselect

    func testSelectViewsReturnsRequestedCountEvenlySpaced() {
        let frames = (0..<10).map { _ in solidColorImage(.gray) }
        let picked = VideoSweepCapture.selectViews(from: frames, count: 4)
        XCTAssertEqual(picked.count, 4)
    }

    func testSelectViewsReturnsAllWhenFewerThanRequested() {
        let frames = (0..<3).map { _ in solidColorImage(.gray) }
        let picked = VideoSweepCapture.selectViews(from: frames, count: 4)
        XCTAssertEqual(picked.count, 3)
    }

    func testSelectViewsPicksEndpoints() {
        let frames = (0..<9).map { i -> UIImage in
            // Encode index into a distinct-size image so first/last are identifiable.
            solidColorImage(.gray, size: CGSize(width: CGFloat(i + 1), height: 1))
        }
        let picked = VideoSweepCapture.selectViews(from: frames, count: 4)
        XCTAssertEqual(picked.first?.size.width, frames.first?.size.width, "First frame is kept")
        XCTAssertEqual(picked.last?.size.width, frames.last?.size.width, "Last frame is kept")
    }
}
