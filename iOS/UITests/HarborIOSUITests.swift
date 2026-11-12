import XCTest

final class HarborIOSUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testPhoneAndTabletLibraryKeepLaunchButtonsReachable() throws {
        let app = XCUIApplication(); app.launch()
        let launch = app.buttons["instance.launch.fabric-example"]
        XCTAssertTrue(launch.waitForExistence(timeout: 15)); XCTAssertTrue(launch.isHittable)
        XCTAssertGreaterThanOrEqual(launch.frame.height, 44)
        XCTAssertTrue(app.staticTexts["触控验证 · Fabric"].exists)
        capture("library-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(launch.waitForExistence(timeout: 5)); XCTAssertTrue(launch.isHittable)
        capture("library-landscape")
        XCUIDevice.shared.orientation = .portrait
    }
    func testTouchEditorPersistsSettingsAndAlwaysKeepsPause() throws {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["设置"].tap()
        let touch = app.buttons["settings.touch"]; XCTAssertTrue(touch.waitForExistence(timeout: 10)); touch.tap()
        XCTAssertTrue(app.navigationBars["触控与摇杆"].waitForExistence(timeout: 10))
        capture("touch-editor")
        let name = app.textFields["布局名称"]; XCTAssertTrue(name.exists); name.tap()
        if let old = name.value as? String { name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        name.typeText("夜间触控测试")
        app.buttons["touch.save"].tap()
        XCTAssertTrue(touch.waitForExistence(timeout: 5)); touch.tap()
        XCTAssertEqual(app.textFields["布局名称"].value as? String, "夜间触控测试")
        capture("touch-editor-restored")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
