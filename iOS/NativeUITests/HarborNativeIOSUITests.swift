import XCTest
import CoreGraphics

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
        // Native preference fields align text to the right. A centre tap can
        // leave the caret before the old name, so move to the visible end first.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        if let old = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    func testResourceImportOpensRealJarPicker() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "net.morben.harbor.ios")
        app.launch()
        let resources = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "资源")).firstMatch
        XCTAssertTrue(resources.waitForExistence(timeout: 15))
        resources.tap()
        let jar = app.buttons["native.page.import"]
        XCTAssertTrue(jar.waitForExistence(timeout: 10))
        XCTAssertTrue(jar.isHittable)
        jar.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 30))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "complete-native-jar-picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testLocalModpackImportOpensFilesAndCanCancel() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "net.morben.harbor.ios")
        app.launch()
        let resources = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "资源")).firstMatch
        XCTAssertTrue(resources.waitForExistence(timeout: 15))
        resources.tap()
        let importer = app.buttons["native.page.importPack"]
        XCTAssertTrue(importer.waitForExistence(timeout: 10))
        XCTAssertTrue(importer.isHittable)
        importer.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 30))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "complete-native-modpack-files-picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(importer.waitForExistence(timeout: 10))
    }
}
