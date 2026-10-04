import XCTest

@MainActor
final class AgentRuntimeDemoUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-simulation"]
        app.launch()
        XCTAssertTrue(app.staticTexts["simulationBanner"].waitForExistence(timeout: 10))
        waitForStatus("Ready", app: app)
        return app
    }

    private func waitForStatus(_ status: String, app: XCUIApplication) {
        let label = app.staticTexts["sessionStatus"]
        // AppKit static text exposes its content as value; UIKit uses label.
        let predicate = NSPredicate(format: "label == %@ OR value == %@", status, status)
        expectation(for: predicate, evaluatedWith: label)
        waitForExpectations(timeout: 10)
    }

    private func send(_ text: String, app: XCUIApplication) {
        let input = app.descendants(matching: .any)["messageInput"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.clickOrTap()
        input.typeText(text)
        app.buttons["send"].clickOrTap()
    }

    func testStreamingEndOnlyAndManifestTurnLimit() {
        let app = launch()
        XCTAssertFalse(app.buttons["send"].isEnabled)
        send("hello", app: app)
        XCTAssertTrue(app.staticTexts["Simulated reply 1: hello"].waitForExistence(timeout: 10))
        waitForStatus("Ready", app: app)
        send("final", app: app)
        XCTAssertTrue(app.staticTexts["Simulated reply 2: final"].waitForExistence(timeout: 10))
        for index in 3...6 {
            waitForStatus("Ready", app: app)
            send("turn \(index)", app: app)
            XCTAssertTrue(app.staticTexts["Simulated reply \(index): turn \(index)"].waitForExistence(timeout: 10))
        }
        waitForStatus("Turn limit reached · start a new conversation", app: app)
        XCTAssertFalse(app.buttons["send"].isEnabled)
        app.buttons["newConversation"].clickOrTap()
        waitForStatus("Ready", app: app)
        XCTAssertFalse(app.staticTexts["Simulated reply 6: turn 6"].exists)
        let turns = app.staticTexts["remainingTurns"]
        XCTAssertTrue(NSPredicate(format: "label == %@ OR value == %@", "6 turns left", "6 turns left")
            .evaluate(with: turns))
    }

    func testStopResetRepeatedSendAndSafeFailure() {
        let app = launch()
        send("slow", app: app)
        XCTAssertTrue(app.buttons["stop"].waitForExistence(timeout: 5))
        app.buttons["stop"].clickOrTap()
        waitForStatus("Interrupted · start a new conversation", app: app)
        app.buttons["newConversation"].clickOrTap()
        waitForStatus("Ready", app: app)
        send("slow", app: app)
        XCTAssertTrue(app.buttons["stop"].waitForExistence(timeout: 5))
        app.buttons["newConversation"].clickOrTap()
        waitForStatus("Ready", app: app)
        send("hello again", app: app)
        XCTAssertTrue(app.staticTexts["Simulated reply 1: hello again"].waitForExistence(timeout: 10))
        waitForStatus("Ready", app: app)
        XCTAssertFalse(app.staticTexts["Simulated reply 1: slow"].exists)
        send("fail", app: app)
        XCTAssertTrue(app.staticTexts["sessionError"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Private provider diagnostics must not be displayed"].exists)
        app.buttons["newConversation"].clickOrTap()
        waitForStatus("Ready", app: app)
    }

    func testUnavailableRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-simulation", "--demo-unavailable-first"]
        app.launch()
        waitForStatus("Model unavailable · open Connection", app: app)
        XCTAssertFalse(app.buttons["send"].isEnabled)
        XCTAssertTrue(app.staticTexts["sessionError"].exists)
        app.buttons["connection"].clickOrTap()
        app.buttons["connectSession"].clickOrTap()
        waitForStatus("Ready", app: app)
        send("recovered", app: app)
        XCTAssertTrue(app.staticTexts["Simulated reply 1: recovered"].waitForExistence(timeout: 10))
    }

    #if os(iOS)
    func testBackgroundInterruptsAndRecovers() {
        let app = launch()
        send("slow", app: app)
        XCTAssertTrue(app.buttons["stop"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForStatus("Interrupted · start a new conversation", app: app)
        app.buttons["newConversation"].clickOrTap()
        waitForStatus("Ready", app: app)
        send("after background", app: app)
        XCTAssertTrue(app.staticTexts["Simulated reply 1: after background"].waitForExistence(timeout: 10))
    }
    #endif

    func testNativeToolLibraryAndConnection() {
        let app = launch()
        send("save", app: app)
        waitForStatus("Ready", app: app)
        app.buttons["savedStories"].clickOrTap()
        XCTAssertTrue(app.staticTexts["A simulated story"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A small fox followed the moon home."].exists)
        app.buttons["Done"].clickOrTap()
        app.buttons["connection"].clickOrTap()
        XCTAssertTrue(app.secureTextFields["providerKey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["apple:foundation-models"].exists)
        app.buttons["connectSession"].clickOrTap()
        waitForStatus("Ready", app: app)
        XCTAssertFalse(app.staticTexts["Simulated reply 1: save"].exists)
    }
}

private extension XCUIElement {
    func clickOrTap() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }
}
