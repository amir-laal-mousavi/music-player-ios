import XCTest

final class MusicPlayerFlowUITests: XCTestCase {
    private let firstSongID: Int64 = 103
    private let secondSongID: Int64 = 102

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testImportSelectionThenPlayFromLibrary() throws {
        let app = launch()

        signIn(app)

        let chat = element(app, "chat.row.1001")
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        chat.tap()

        let firstRow = element(app, "browse.row.\(firstSongID)")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20))
        firstRow.tap()
        element(app, "browse.row.\(secondSongID)").tap()

        let selectionCount = app.staticTexts["browse.selectionCount"]
        XCTAssertTrue(selectionCount.waitForExistence(timeout: 5))
        XCTAssertEqual(selectionCount.label, "2 songs selected")

        app.buttons["browse.import"].tap()

        let status = app.staticTexts["import.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        expectation(
            for: NSPredicate(format: "label == %@", "Import complete"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 90)

        app.buttons["import.done"].tap()
        app.tabBars.buttons["Library"].tap()

        let track = element(app, "library.row.\(firstSongID)")
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        track.tap()

        XCTAssertTrue(app.staticTexts["player.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.sliders["player.scrubber"].exists)
        XCTAssertTrue(app.buttons["player.playPause"].exists)
        XCTAssertTrue(app.buttons["player.next"].exists)
    }

    func testEmptyLibraryExplainsHowToImport() throws {
        let app = launch()

        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Telegram"].exists)
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        // Sign-in lives on the Telegram tab; the library is the default tab.
        let telegramTab = app.tabBars.buttons["Telegram"]
        XCTAssertTrue(telegramTab.waitForExistence(timeout: 20))
        telegramTab.tap()

        let phone = app.textFields["login.phone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 20))
        phone.tap()
        phone.typeText("+15550101234")
        app.buttons["login.submit"].tap()

        let code = app.textFields["login.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        code.tap()
        code.typeText("12345")
        app.buttons["login.submit"].tap()
    }

    /// Row identifiers can land on a button or a cell depending on the list style.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
