import XCTest
@testable import Bricky

/// Tests for the iPhone bottom tab strip (`MainTabView.Tab`), verifying the
/// four primary destinations — Home, Sets, Feed, and Games — their order,
/// titles, icons, and identity.
@MainActor
final class MainTabViewTests: XCTestCase {

    func testTabCasesAndOrder() {
        let allTabs = MainTabView.Tab.allCases
        XCTAssertEqual(allTabs.count, 4, "Bottom tab strip should have 4 tabs")
        XCTAssertEqual(allTabs, [.home, .sets, .feed, .games],
                       "Tabs should be ordered Home, Sets, Feed, Games")
    }

    func testTabTitles() {
        XCTAssertEqual(MainTabView.Tab.home.title, "Home")
        XCTAssertEqual(MainTabView.Tab.sets.title, "Sets")
        XCTAssertEqual(MainTabView.Tab.feed.title, "Feed")
        XCTAssertEqual(MainTabView.Tab.games.title, "Games")
    }

    func testTabTitlesAreTitleCase() {
        for tab in MainTabView.Tab.allCases {
            let first = tab.title.first
            XCTAssertNotNil(first)
            XCTAssertTrue(first!.isUppercase, "Tab title \(tab.title) should be Title Case")
        }
    }

    func testTabIcons() {
        XCTAssertEqual(MainTabView.Tab.home.icon, "house.fill")
        XCTAssertEqual(MainTabView.Tab.sets.icon, "shippingbox.fill")
        XCTAssertEqual(MainTabView.Tab.feed.icon, "rectangle.stack.fill")
        XCTAssertEqual(MainTabView.Tab.games.icon, "puzzlepiece.fill")
    }

    func testTabIconsAreUnique() {
        let icons = MainTabView.Tab.allCases.map(\.icon)
        XCTAssertEqual(Set(icons).count, icons.count, "Each tab should have a unique icon")
    }

    func testTabIdentity() {
        XCTAssertEqual(MainTabView.Tab.home.id, "home")
        XCTAssertEqual(MainTabView.Tab.games.id, "games")
    }
}
