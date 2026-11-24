import XCTest

final class AnimeHeavenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFullAppWalkthroughCapturesScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestDisableAutoScroll"]
        app.launch()

        // 1. Home (Schedule) — Liquid Glass Floating Tab Bar
        let scheduleTab = app.buttons["tab.schedule"]
        XCTAssertTrue(scheduleTab.waitForExistence(timeout: 15), "Schedule tab should appear on launch")
        XCTAssertTrue(app.buttons["tab.new"].exists)
        XCTAssertTrue(app.buttons["tab.popular"].exists)
        XCTAssertTrue(app.buttons["tab.bookmarks"].exists)
        let header = app.staticTexts["topbar.title"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.label, "For You")
        XCTAssertGreaterThan(header.frame.width, 48, "The Home title must not collapse into an icon-only tile.")
        XCTAssertTrue(app.staticTexts["Popular Today"].waitForExistence(timeout: 15), "Home Popular Today section should load")
        sleep(3)
        attachScreenshot(named: "01-ios-home-schedule")

        // 2. New Releases tab
        app.buttons["tab.new"].tap()
        _ = app.staticTexts["Latest Releases"].waitForExistence(timeout: 15)
        sleep(2)
        attachScreenshot(named: "02-ios-new")

        // 3. Popular tab
        app.buttons["tab.popular"].tap()
        _ = app.staticTexts["Ranked by Views"].waitForExistence(timeout: 15)
        sleep(2)
        attachScreenshot(named: "03-ios-popular")

        // 4. Bookmarks tab
        app.buttons["tab.bookmarks"].tap()
        sleep(1)
        attachScreenshot(named: "04-ios-bookmarks")

        // 5. Return to Schedule and open Search with full query (dismissing keyboard cleanly)
        scheduleTab.tap()
        sleep(1)
        let searchBtn = app.buttons["topbar.search"]
        XCTAssertTrue(searchBtn.waitForExistence(timeout: 10), "Search button should be visible")
        searchBtn.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10), "Search screen should open")
        let searchField = app.textFields["Search anime titles..."]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field should exist")
        searchField.tap()
        let keyboardContinue = app.buttons["Continue"]
        if keyboardContinue.waitForExistence(timeout: 2) {
            keyboardContinue.tap()
            sleep(1)
            searchField.tap()
        }
        searchField.typeText("frieren\n")
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }
        let frierenResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Frieren")).firstMatch
        _ = frierenResult.waitForExistence(timeout: 15)
        sleep(2)
        attachScreenshot(named: "05-ios-search-results")

        // Navigate back from Search
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scheduleTab.waitForExistence(timeout: 10))

        // 6. Settings (Default Cinema Dark)
        let settingsBtn = app.buttons["topbar.settings"]
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: 10), "Settings button should be visible")
        settingsBtn.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings screen should open")
        sleep(1)
        attachScreenshot(named: "06-ios-settings-dark")

        // 7. Switch Theme to Midnight Indigo
        let indigoTheme = app.buttons["theme.dark2"]
        XCTAssertTrue(indigoTheme.waitForExistence(timeout: 5), "Midnight Indigo theme button should exist")
        indigoTheme.tap()
        sleep(1)
        attachScreenshot(named: "07-ios-settings-indigo")

        // 8. Return to Home in Midnight Indigo
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scheduleTab.waitForExistence(timeout: 10))
        sleep(2)
        attachScreenshot(named: "08-ios-home-indigo")

        // 9. Switch Theme to Classic Light and verify Settings contrast
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: 10), "Settings button should be visible")
        settingsBtn.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings screen should open")
        let lightTheme = app.buttons["theme.light"]
        XCTAssertTrue(lightTheme.waitForExistence(timeout: 5), "Classic Light theme button should exist")
        if !lightTheme.isHittable {
            app.swipeUp()
        }
        lightTheme.tap()
        sleep(1)
        attachScreenshot(named: "09-ios-settings-light")

        // 10. Return to Home (Classic Light) and open Featured Anime Detail
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scheduleTab.waitForExistence(timeout: 10))
        let heroDetails = app.buttons["hero.details"].firstMatch
        XCTAssertTrue(heroDetails.waitForExistence(timeout: 10), "Hero Details button should exist")
        heroDetails.tap()
        let myListButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "My List")).firstMatch
        _ = myListButton.waitForExistence(timeout: 15)
        sleep(2)
        attachScreenshot(named: "10-ios-detail")
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
