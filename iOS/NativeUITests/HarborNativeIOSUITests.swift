import XCTest
import CoreGraphics

/// Targets the installed full JVM/graphics App, never the fixture harness.
@MainActor final class HarborNativeIOSUITests: XCTestCase {
    func testNativeWorldEditorSavesRealMetadataAndBackup() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "net.morben.harbor.ios")
        app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "设置")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        let entry = app.buttons["settings.worlds"]
        for _ in 0..<10 { if entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        let instance = app.buttons["worlds.instance.(Default)"]
        XCTAssertTrue(instance.waitForExistence(timeout: 10)); instance.tap()
        let world = app.buttons["worlds.folder.Harbor Data QA"]
        XCTAssertTrue(world.waitForExistence(timeout: 10)); world.tap()
        let name = app.textFields["worlds.field.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); replace(name, with: "Native world edited")
        let health = app.textFields["worlds.field.health"]
        for _ in 0..<7 { if health.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(health.isHittable); replace(health, with: "7.5")
        let save = app.buttons["worlds.save"]
        XCTAssertTrue(save.isHittable); XCTAssertGreaterThanOrEqual(save.frame.height, 44); save.tap()
        let backup = app.buttons["分享本次原始元数据备份"]
        for _ in 0..<6 { if backup.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "complete-native-world-backed-up-save"; shot.lifetime = .keepAlways; add(shot)
    }
    func testNativeCompressedDatapackReadsEditsAndAppliesWithBackup() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "net.morben.harbor.ios")
        app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "设置")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        let entry = app.buttons["settings.localization"]
        for _ in 0..<9 { if entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        let instance = app.buttons["localization.instance.(Default)"]
        XCTAssertTrue(instance.waitForExistence(timeout: 10)); instance.tap()
        let scan = app.buttons["localization.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10)); scan.tap()
        let original = app.staticTexts["Native ZIP QA title"]
        XCTAssertTrue(original.waitForExistence(timeout: 20))
        for _ in 0..<6 { if original.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(original.isHittable); original.tap()
        let editor = app.textViews["中文译文"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap(); editor.typeText("Localized native ZIP QA")
        let save = app.buttons["保存译文"]
        for _ in 0..<4 { if save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.staticTexts["译文已保存。"].waitForExistence(timeout: 10))
        app.navigationBars["对照编辑"].buttons.firstMatch.tap()
        let menu = app.buttons["汉化操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        app.buttons["备份并应用任务 / 数据包译文"].tap()
        let confirm = app.buttons["备份并应用"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        let complete = app.staticTexts["已应用 1 个任务 / 数据包文本；原文件备份已保留。"]
        XCTAssertTrue(complete.waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "complete-native-compressed-datapack-applied"; shot.lifetime = .keepAlways; add(shot)
    }
    func testExclusiveOptimizationPersistsInCompleteNativeApp() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "net.morben.harbor.ios")
        app.launch()
        func openSettings() {
            let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "设置")).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 15))
            settings.tap()
        }
        func setting() -> XCUIElement {
            let toggle = app.switches["settings.performance.exclusive"]
            for _ in 0..<4 {
                if toggle.exists && toggle.isHittable { return toggle }
                app.swipeUp()
            }
            XCTAssertTrue(toggle.isHittable)
            return toggle
        }
        openSettings()
        let toggle = setting()
        if toggle.value as? String == "1" { toggle.tap() }
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.terminate()
        app.launch()
        openSettings()
        let restored = setting()
        XCTAssertEqual(restored.value as? String, "1")
        restored.tap()
        XCTAssertEqual(restored.value as? String, "0")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "complete-native-glass-and-optimization"
        shot.lifetime = .keepAlways
        add(shot)
    }
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
        let menu = app.buttons["resources.install.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); XCTAssertTrue(menu.isHittable); menu.tap()
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
        let menu = app.buttons["resources.install.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); XCTAssertTrue(menu.isHittable); menu.tap()
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
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); XCTAssertTrue(menu.isHittable); menu.tap()
        XCTAssertTrue(importer.waitForExistence(timeout: 10))
    }
}
