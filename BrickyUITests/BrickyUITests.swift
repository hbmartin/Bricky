import XCTest

final class BrickyUITests: XCTestCase {
    /// The Simulator has no LiDAR, so the app would show its unsupported
    /// screen; Debug builds accept a forced device-floor verdict.
    private func launch(floor: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-BrickyDeviceFloorOverride", floor]
        app.launch()
        return app
    }

    func testRecoveryFirstNavigationHasNoLegacySurfaces() {
        let app = launch(floor: "supported")
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Recovery"].exists)
        XCTAssertTrue(app.tabBars.buttons["Guide"].exists)
        XCTAssertTrue(app.tabBars.buttons["Storage"].exists)
        XCTAssertFalse(app.tabBars.buttons["Catalog"].exists)
        XCTAssertFalse(app.tabBars.buttons["Community"].exists)
        XCTAssertFalse(app.tabBars.buttons["Games"].exists)
    }

    func testDevicesBelowTheFloorSeeAnExplanationInsteadOfTheApp() {
        let app = launch(floor: "unsupportedModel")
        XCTAssertTrue(app.staticTexts["iPhone 17 Pro Required"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Library"].exists)
    }
}
