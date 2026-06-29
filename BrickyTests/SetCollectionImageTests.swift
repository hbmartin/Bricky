import XCTest
import UIKit
@testable import Bricky

final class SetCollectionImageTests: XCTestCase {
    private let setNumber = "60431-test"

    override func tearDown() {
        SetCollectionStore.shared.removeSet(setNumber)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let img = docs.appendingPathComponent("setImages/\(setNumber).jpg")
        try? FileManager.default.removeItem(at: img)
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

    func testThumbnailCountTracksSavedImages() {
        let store = SetCollectionStore.shared
        store.addSet(setNumber)
        store.saveImage(jpeg(), for: setNumber)
        XCTAssertTrue(store.thumbnailCount >= 1)
        XCTAssertTrue(store.collection.filter { store.hasImage(for: $0.setNumber) }.count >= 1)
    }

    func testAutoDownloadThumbnailsPersists() {
        let store = SetCollectionStore.shared
        let original = store.autoDownloadThumbnails
        store.autoDownloadThumbnails = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "setCollection.autoDownloadThumbnails"))
        store.autoDownloadThumbnails = original
    }
}
