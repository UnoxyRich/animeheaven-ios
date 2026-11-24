import XCTest

final class AnimeHeavenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndNavigateAllTabs() throws {
        let app = XCUIApplication()
        app.launch()

        let scheduleTab = app.tabBars.buttons["Schedule"]
        XCTAssertTrue(scheduleTab.waitForExistence(timeout: 15), "Schedule tab should appear on launch")
        XCTAssertTrue(app.tabBars.buttons["New"].exists)
        XCTAssertTrue(app.tabBars.buttons["Popular"].exists)
        XCTAssertTrue(app.tabBars.buttons["Bookmarks"].exists)

        attachScreenshot(named: "01-Home-Schedule")

        app.tabBars.buttons["New"].tap()
        app.tabBars.buttons["Popular"].tap()
        app.tabBars.buttons["Bookmarks"].tap()
        attachScreenshot(named: "02-Bookmarks")

        scheduleTab.tap()
    }

    @MainActor
    func testOpenSettingsSwitchThemeAndReturn() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsBtn = app.buttons["topbar.settings"]
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: 15), "Settings button should be visible")
        settingsBtn.tap()

        let navTitle = app.navigationBars["Settings"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 10), "Settings screen should open")

        let indigoTheme = app.buttons["Midnight Indigo"]
        if indigoTheme.waitForExistence(timeout: 5) {
            indigoTheme.tap()
        }
        attachScreenshot(named: "03-Settings")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.buttons["Schedule"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOpenSearchScreenAndTypeQuery() throws {
        let app = XCUIApplication()
        app.launch()

        let searchBtn = app.buttons["topbar.search"]
        XCTAssertTrue(searchBtn.waitForExistence(timeout: 15), "Search button should be visible")
        searchBtn.tap()

        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10), "Search screen should open")
        let searchField = app.textFields["Search anime titles..."]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Native search text field should exist")
        searchField.tap()
        searchField.typeText("frieren")
        attachScreenshot(named: "04-Search")

        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
