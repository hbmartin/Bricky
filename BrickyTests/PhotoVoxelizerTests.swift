import XCTest
import UIKit
@testable import Bricky

final class PhotoVoxelizerTests: XCTestCase {

    /// A solid-colour image with no distinct subject falls back to whole-image
    /// voxelization and still yields a buildable model.
    private func solidImage(color: UIColor, size: CGSize = CGSize(width: 120, height: 120)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testVoxelizeSolidImageProducesModel() throws {
        let image = solidImage(color: UIColor(red: 0.79, green: 0.10, blue: 0.04, alpha: 1)) // ~LEGO red
        let model = try PhotoVoxelizer.voxelize(image: image, size: .small, subject: "Red")
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.source, .photo)
        XCTAssertTrue(model.voxels.allSatisfy { $0.color == .red }, "Solid red image should map to red bricks")
    }

    func testVoxelizeThenForgeProducesBuildableSet() throws {
        let image = solidImage(color: .systemBlue)
        let model = try PhotoVoxelizer.voxelize(image: image, size: .small, subject: "Blue")
        let set = try SetForgeEngine.shared.generate(from: model, size: .small, name: "Blue")
        XCTAssertGreaterThan(set.brickCount, 0)
        XCTAssertFalse(set.parts.isEmpty)
        XCTAssertFalse(set.steps.isEmpty)
    }

    func testGridRespectsSizePreset() throws {
        let image = solidImage(color: .green, size: CGSize(width: 200, height: 200))
        let small = try PhotoVoxelizer.voxelize(image: image, size: .small, subject: "G")
        let large = try PhotoVoxelizer.voxelize(image: image, size: .large, subject: "G")
        XCTAssertGreaterThanOrEqual(large.width, small.width)
        XCTAssertLessThanOrEqual(small.width, VoxelModel.Size.small.maxDimension)
    }
}
