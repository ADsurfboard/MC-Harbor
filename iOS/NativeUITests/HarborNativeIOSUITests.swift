import XCTest

/// Targets the installed full JVM/graphics App, never the fixture harness.
@MainActor final class HarborNativeIOSUITests: XCTestCase {
    func testRealProfileEditorCancelAndSaveFromSwiftUI() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "net.morben.harbor.ios")
        app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"
        app.launch()
        let more = app.buttons["instance.more.(Default)"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        app.buttons["实例管理"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replace(field, with: "Cancelled Native QA")
        app.buttons["native.profile.cancel"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Cancelled Native QA"].exists)
        more.tap()
        app.buttons["实例管理"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replace(field, with: "Harbor Native QA")
        app.buttons["native.profile.save"].tap()
        XCTAssertTrue(app.buttons["instance.launch.Harbor Native QA"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "complete-native-profile-save"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["instance.launch.Harbor Native QA"].waitForExistence(timeout: 20))
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        if let old = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
    }
}
