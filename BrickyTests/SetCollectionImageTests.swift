import XCTest
import UIKit
@testable import Bricky

final class SetCollectionImageTests: XCTestCase {
    private let setNumber = "60431-test"

    override func tearDown() {
        SetCollectionStore.shared.removeSet(setNumber)
        super.tearDown()
    }

    private func jpeg() -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return r.image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
            .jpegData(compressionQuality: 0.8)!
    }

    func testSaveAndLoadImage() {
        XCTAssertFalse(SetCollectionStore.shared.hasImage(for: setNumber))
        SetCollectionStore.shared.saveImage(jpeg(), for: setNumber)
        XCTAssertTrue(SetCollectionStore.shared.hasImage(for: setNumber))
        XCTAssertNotNil(SetCollectionStore.shared.image(for: setNumber))
    }

    func testMissingImageReturnsNil() {
        XCTAssertNil(SetCollectionStore.shared.image(for: "no-such-set-xyz"))
    }
}
