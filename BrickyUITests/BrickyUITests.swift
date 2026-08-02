import XCTest

final class BrickyUITests: XCTestCase {
    func testRecoveryFirstNavigationHasNoLegacySurfaces() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Recovery"].exists)
        XCTAssertTrue(app.tabBars.buttons["Guide"].exists)
        XCTAssertTrue(app.tabBars.buttons["Storage"].exists)
        XCTAssertFalse(app.tabBars.buttons["Catalog"].exists)
        XCTAssertFalse(app.tabBars.buttons["Community"].exists)
        XCTAssertFalse(app.tabBars.buttons["Games"].exists)
    }
}
