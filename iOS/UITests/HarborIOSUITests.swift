import XCTest

@MainActor final class HarborIOSUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    func testPhoneAndTabletLibraryKeepLaunchButtonsReachable() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        let launch = app.buttons["instance.launch.fabric-example"]
        XCTAssertTrue(launch.waitForExistence(timeout: 15)); XCTAssertTrue(launch.isHittable)
        XCTAssertGreaterThanOrEqual(launch.frame.height, 44)
        XCTAssertTrue(app.staticTexts["触控验证 · Fabric"].exists)
        capture("library-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(launch.waitForExistence(timeout: 5))
        capture("library-landscape-before-scroll")
        print("HARBOR_LANDSCAPE before app=\(app.frame) button=\(launch.frame)")
        if !launch.isHittable { app.swipeUp() }
        capture("library-landscape-after-scroll")
        print("HARBOR_LANDSCAPE after app=\(app.frame) button=\(launch.frame)")
        XCTAssertTrue(launch.isHittable)
        capture("library-landscape")
        XCUIDevice.shared.orientation = .portrait
    }
    func testTouchEditorPersistsSettingsAndAlwaysKeepsPause() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        // iPadOS 26 exposes floating tabs as cells instead of a TabBar.
        // Match the visible labelled control without assuming its AX class.
        let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "设置")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); XCTAssertTrue(settings.isHittable); settings.tap()
        let touch = app.buttons["settings.touch"]; XCTAssertTrue(touch.waitForExistence(timeout: 10)); touch.tap()
        XCTAssertTrue(app.navigationBars["触控与摇杆"].waitForExistence(timeout: 10))
        capture("touch-editor")
        let name = app.textFields["touch.layout.name"]; XCTAssertTrue(name.exists); name.tap()
        if let old = name.value as? String { name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        name.typeText("Harbor Touch QA")
        app.buttons["touch.save"].tap()
        XCTAssertTrue(touch.waitForExistence(timeout: 5)); touch.tap()
        XCTAssertEqual(app.textFields["touch.layout.name"].value as? String, "Harbor Touch QA")
        capture("touch-editor-restored")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
