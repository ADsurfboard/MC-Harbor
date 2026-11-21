import XCTest

@MainActor final class HarborIOSUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    func testDeveloperCreditsShowAuthorAndPortLead() {
        let app = XCUIApplication()
        app.launch()
        openSettingsEntry("settings.credits", app: app)
        XCTAssertTrue(app.staticTexts["ADsurfboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Windows、Android 与 Linux 移植负责人"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "时咨月.").count, 1)
        capture("developers-and-contributors")
    }
    func testWorldEditorSavesRealNBTAndRestoresAfterRelaunch() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launchEnvironment["HARBOR_WORLD_FIXTURE"] = "1"; app.launch()
        func openWorld() {
            openSettingsEntry("settings.worlds", app: app)
            let instance = app.buttons["worlds.instance.fabric-example"]
            XCTAssertTrue(instance.waitForExistence(timeout: 10)); instance.tap()
            let world = app.buttons["worlds.folder.World QA"]
            XCTAssertTrue(world.waitForExistence(timeout: 10)); world.tap()
            XCTAssertTrue(app.textFields["worlds.field.name"].waitForExistence(timeout: 10))
        }
        openWorld()
        let name = app.textFields["worlds.field.name"], title = "Saved QA " + String(UUID().uuidString.prefix(6))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count)); name.typeText(title)
        waitForValue(title, in: name)
        let health = app.textFields["worlds.field.health"]
        for _ in 0..<7 { if health.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(health.isHittable); health.tap()
        health.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (health.value as? String ?? "").count)); health.typeText("7.5")
        waitForValue("7.5", in: health)
        let save = app.buttons["worlds.save"]
        XCTAssertTrue(save.isHittable); XCTAssertGreaterThanOrEqual(save.frame.height, 44); save.tap()
        let backup = app.buttons["分享本次原始元数据备份"]
        for _ in 0..<5 { if backup.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(backup.waitForExistence(timeout: 10)); capture("world-editor-backed-up-save")
        app.terminate(); app.launch(); openWorld()
        XCTAssertEqual(app.textFields["worlds.field.name"].value as? String, title)
        let restoredHealth = app.textFields["worlds.field.health"]
        for _ in 0..<7 { if restoredHealth.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(restoredHealth.value as? String, "7.5"); capture("world-editor-relaunch-persisted")
    }
    func testWallpaperLibraryUsesPreviewAndPersistsSelection() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launchEnvironment["HARBOR_WALLPAPER_FIXTURE"] = "1"; app.launch()
        func openLibrary() {
            openSettingsEntry("settings.wallpapers", app: app)
            XCTAssertTrue(app.buttons["wallpapers.import"].waitForExistence(timeout: 10))
        }
        openLibrary()
        XCTAssertGreaterThanOrEqual(app.buttons["wallpapers.import"].frame.height, 44)
        let identifier = "wallpapers.item.12345678-1234-4321-8765-123456789ABC"
        let item = app.buttons[identifier]
        for _ in 0..<5 { if item.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(item.waitForExistence(timeout: 10)); item.tap()
        let use = app.buttons["使用此壁纸"]
        XCTAssertTrue(use.waitForExistence(timeout: 10)); XCTAssertGreaterThanOrEqual(use.frame.height, 44); use.tap()
        XCTAssertTrue(app.buttons["正在使用"].waitForExistence(timeout: 10)); capture("wallpaper-preview-selected")
        app.terminate(); app.launch(); openLibrary()
        let restored = app.buttons[identifier]
        XCTAssertTrue(restored.waitForExistence(timeout: 10)); waitForValue("使用中", in: restored)
        let defaults = app.buttons["wallpapers.default"]; defaults.tap(); waitForValue("已选中", in: defaults)
        capture("wallpaper-default-restored")
        let video = app.buttons["wallpapers.item.22345678-1234-4321-8765-123456789ABC"]
        if !video.isHittable { app.swipeUp() }
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        video.tap()
        let play = app.buttons["播放视频预览"]
        let pause = app.buttons["暂停视频预览"]
        for _ in 0..<3 {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: play)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            play.tap()
            XCTAssertTrue(pause.waitForExistence(timeout: 10))
            pause.tap()
            XCTAssertTrue(play.waitForExistence(timeout: 10))
        }
        capture("wallpaper-video-preview-reopened")
    }
    func testWelcomeAudioListsFourOriginalVoicesAndPersistsChoice() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        openSettingsEntry("settings.welcome", app: app)
        XCTAssertTrue(app.staticTexts["welcome.resources.ready"].waitForExistence(timeout: 10))
        let picker = app.buttons["welcome.voice"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.tap()
        for title in ["女声 1 · Clara", "女声 2 · Clara", "男声 1 · Adam", "男声 2 · Morgan"] { XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5)) }
        app.buttons["男声 2 · Morgan"].tap()
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (picker.label + " " + (picker.value as? String ?? "")).contains("Morgan")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: 5), .completed)
        capture("welcome-four-voices")
        app.terminate(); app.launch(); openSettingsEntry("settings.welcome", app: app)
        let restored = app.buttons["welcome.voice"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10)); XCTAssertTrue((restored.label + " " + (restored.value as? String ?? "")).contains("Morgan"))
        restored.tap(); app.buttons["女声 1 · Clara"].tap()
    }
    func testLocalizationReadsRealLooseFixturesAndPersistsManualDraft() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launchEnvironment["HARBOR_LOCALIZATION_FIXTURE"] = "1"; app.launch()
        func openWorkspace() {
            let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "设置")).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
            let entry = app.buttons["settings.localization"]
            for _ in 0..<7 { if entry.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(entry.waitForExistence(timeout: 10)); XCTAssertTrue(entry.isHittable); entry.tap()
            let instance = app.buttons["localization.instance.fabric-example"]
            XCTAssertTrue(instance.waitForExistence(timeout: 10)); instance.tap()
        }
        openWorkspace()
        let scan = app.buttons["localization.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10)); XCTAssertGreaterThanOrEqual(scan.frame.height, 44); scan.tap()
        let original = app.staticTexts["Fixture tool %s"]
        for _ in 0..<5 { if original.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(original.waitForExistence(timeout: 15)); original.tap()
        let editor = app.textViews["中文译文"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap(); editor.typeText("Localized tool %s")
        waitForValue("Localized tool %s", in: editor)
        let save = app.buttons["保存译文"]
        for _ in 0..<4 { if save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap(); XCTAssertTrue(app.staticTexts["译文已保存。"].waitForExistence(timeout: 10))
        capture("localization-manual-draft")
        app.terminate(); app.launch(); openWorkspace()
        let restored = app.staticTexts["Localized tool %s"]
        for _ in 0..<5 { if restored.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(restored.waitForExistence(timeout: 10)); XCTAssertTrue(restored.isHittable)
        capture("localization-draft-restored")
    }
    func testManyFriendsRemainSeparatedAndNotesPersist() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launchEnvironment["HARBOR_FRIENDS_FIXTURE"] = "1"; app.launch()
        func openFriends() {
            let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "好友")).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 15)); tab.tap()
        }
        openFriends()
        let search = app.textFields["friends.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("36")
        let person = app.staticTexts["隔离测试好友 36"]
        for _ in 0..<4 { if person.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(person.waitForExistence(timeout: 10)); XCTAssertTrue(person.isHittable); person.tap()
        let note = app.textFields["friends.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap(); note.typeText("MobileQA36")
        let save = app.buttons["保存备注"]
        if !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); XCTAssertGreaterThanOrEqual(save.frame.height, 44); save.tap()
        capture("friends-48-fixture-note")
        app.terminate(); app.launch(); openFriends()
        let restoredSearch = app.textFields["friends.search"]
        XCTAssertTrue(restoredSearch.waitForExistence(timeout: 10)); restoredSearch.tap(); restoredSearch.typeText("MobileQA36")
        let restored = app.staticTexts["MobileQA36"]
        for _ in 0..<4 { if restored.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(restored.waitForExistence(timeout: 10)); XCTAssertTrue(restored.isHittable)
        capture("friends-48-fixture-note-restored")
    }
    func testResourceSearchControlsAndTranslationSettingsPersist() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        func openResources() {
            let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "资源")).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 15)); tab.tap()
        }
        openResources()
        let menu = app.buttons["resources.install.menu"]
        let settings = app.buttons["resources.settings"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(settings.isHittable); XCTAssertGreaterThanOrEqual(menu.frame.height, 44); XCTAssertGreaterThanOrEqual(settings.frame.height, 44)
        XCTAssertTrue(app.searchFields["中英文名称或关键词"].exists)
        settings.tap()
        let translate = app.switches["resources.translate"]
        XCTAssertTrue(translate.waitForExistence(timeout: 10))
        let original = translate.value as? String
        translate.tap()
        let saved = translate.value as? String
        XCTAssertNotEqual(saved, original)
        capture("resource-translation-settings")
        app.terminate(); app.launch(); openResources(); app.buttons["resources.settings"].tap()
        let restored = app.switches["resources.translate"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10)); XCTAssertEqual(restored.value as? String, saved)
        restored.tap(); XCTAssertEqual(restored.value as? String, original)
    }
    func testModFolderForegroundEmptyStateAndPersistence() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        func openFolders() {
            let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "模组夹")).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 15)); tab.tap()
        }
        openFolders()
        let create = app.buttons["folder.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); XCTAssertGreaterThanOrEqual(create.frame.height, 44); create.tap()
        let title = "Harbor QA " + String(UUID().uuidString.prefix(6))
        let name = app.textFields["folder.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText(title)
        waitForValue(title, in: name)
        XCTAssertEqual(name.value as? String, title)
        app.buttons["folder.editor.save"].tap()
        let folder = app.buttons["folder.open." + title]
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.tap()
        XCTAssertTrue(app.staticTexts["这个模组夹还是空的"].waitForExistence(timeout: 10))
        let add = app.buttons["添加模组"]
        XCTAssertTrue(add.isHittable); XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        capture("folder-empty-foreground-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
        XCTAssertTrue(add.waitForExistence(timeout: 5)); XCTAssertTrue(add.isHittable)
        capture("folder-empty-foreground-landscape")
        app.buttons["完成"].tap(); XCUIDevice.shared.orientation = .portrait
        app.terminate(); app.launch(); openFolders()
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        capture("folder-persisted-library")
    }
    func testCoverFlowSwipesSelectionAndRestoresList() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        defer {
            // Keep unrelated UI tests independent even when an assertion fails.
            XCUIDevice.shared.orientation = .portrait
            if app.buttons["安装或导入"].isHittable {
                app.buttons["安装或导入"].tap()
                if app.buttons["使用列表选择实例"].exists { app.buttons["使用列表选择实例"].tap() }
                else { app.tap() }
            }
        }
        let menu = app.buttons["安装或导入"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        if app.buttons["使用列表选择实例"].exists {
            app.buttons["使用列表选择实例"].tap()
            menu.tap()
        }
        app.buttons["使用封面流选择实例"].tap()
        let flow = app.collectionViews["library.coverflow"]
        XCTAssertTrue(flow.waitForExistence(timeout: 10))
        let previous = app.buttons["上一个实例"], next = app.buttons["下一个实例"]
        if app.staticTexts["library.coverflow.position"].label != "1 / 2" { previous.tap() }
        XCTAssertEqual(app.staticTexts["library.coverflow.position"].label, "1 / 2")
        // Move one physical cover pitch, independent of iPhone/iPad width.
        // The end hold removes fling ambiguity when a two-instance ring wraps.
        let centered = try XCTUnwrap(flow.cells.allElementsBoundByIndex.min { abs($0.frame.midX - flow.frame.midX) < abs($1.frame.midX - flow.frame.midX) })
        let travel = centered.frame.width * 0.90 / flow.frame.width
        flow.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.5)).press(forDuration: 0.08,
            thenDragTo: flow.coordinate(withNormalizedOffset: CGVector(dx: 0.80 - travel, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.3)
        let predicate = NSPredicate(format: "label == %@", "2 / 2")
        XCTAssertTrue(app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(previous.isEnabled)
        assertNeighborCovers(flow)
        capture("coverflow-horizontal-selection")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
        capture("coverflow-landscape-before-scroll")
        if !previous.isHittable { app.swipeUp() }
        capture("coverflow-landscape-after-scroll")
        XCTAssertTrue(previous.isHittable)
        assertNeighborCovers(flow)
        previous.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "1 / 2")).firstMatch.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .portrait
        menu.tap(); app.buttons["使用列表选择实例"].tap()
        XCTAssertTrue(app.buttons["instance.launch.fabric-example"].waitForExistence(timeout: 10))
        XCTAssertFalse(flow.exists)
        XCTAssertFalse(next.exists)
    }
    func testExclusiveOptimizationKeepsGlassAndPersists() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"
        app.launch()
        func openSettings() {
            let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "设置")).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 15))
            settings.tap()
        }
        func optimizationSwitch() -> XCUIElement {
            let toggle = app.switches["settings.performance.exclusive"]
            for _ in 0..<4 {
                if toggle.exists && toggle.isHittable { return toggle }
                app.swipeUp()
            }
            XCTAssertTrue(toggle.isHittable)
            return toggle
        }
        openSettings()
        let toggle = optimizationSwitch()
        if toggle.value as? String == "1" { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "0")
        capture("glass-full-effects-settings")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        // The label/blank area and the actual switch both remain actionable.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let status = app.staticTexts["settings.performance.material"]
        if #available(iOS 26.0, *) {
            XCTAssertTrue(status.exists)
            XCTAssertEqual(status.label, "Liquid Glass · 静态模式")
        }
        app.terminate()
        app.launch()
        openSettings()
        let restored = optimizationSwitch()
        XCTAssertEqual(restored.value as? String, "1")
        capture("glass-static-settings-restored")
        restored.tap()
        XCTAssertEqual(restored.value as? String, "0")
        let library = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "游戏")).firstMatch
        library.tap()
        let launch = app.buttons["instance.launch.fabric-example"]
        XCTAssertTrue(launch.waitForExistence(timeout: 10))
        XCTAssertTrue(launch.isHittable)
        XCTAssertGreaterThanOrEqual(launch.frame.height, 44)
        capture("glass-full-effects-library-restored")
    }
    func testPhoneAndTabletLibraryKeepLaunchButtonsReachable() throws {
        let app = XCUIApplication(); app.launchEnvironment["HARBOR_SMOKE_TEST"] = "1"; app.launch()
        let launch = app.buttons["instance.launch.fabric-example"]
        XCTAssertTrue(launch.waitForExistence(timeout: 15)); XCTAssertTrue(launch.isHittable)
        XCTAssertGreaterThanOrEqual(launch.frame.height, 44)
        XCTAssertTrue(app.staticTexts["触控验证 · Fabric"].exists)
        capture("library-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
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
        waitForValue("Harbor Touch QA", in: name)
        app.buttons["touch.save"].tap()
        XCTAssertTrue(touch.waitForExistence(timeout: 5)); touch.tap()
        XCTAssertEqual(app.textFields["touch.layout.name"].value as? String, "Harbor Touch QA")
        capture("touch-editor-restored")
    }
    private func openSettingsEntry(_ identifier: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "设置")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), file: file, line: line); settings.tap()
        let entry = app.buttons[identifier]
        for _ in 0..<8 { if entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), file: file, line: line); XCTAssertTrue(entry.isHittable, file: file, line: line); entry.tap()
    }
    private func waitForValue(_ expected: String, in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // Keep the exact-value assertion. Wait only for UIKit/SwiftUI to
        // publish the already-entered keys; never retype or accept truncation.
        let committed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 5), .completed, file: file, line: line)
    }
    private func waitForLandscape(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Device orientation requests are asynchronous. Wait for the actual
        // application viewport before measuring covers or recording evidence.
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 15), .completed, file: file, line: line)
    }
    private func capture(_ name: String) {
        // App-bounded captures can crop a rotated scene in its old portrait
        // coordinates. Capture the whole real simulator display instead.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print("HARBOR_CAPTURE \(name) viewport=\(XCUIApplication().frame) orientation=\(XCUIDevice.shared.orientation.rawValue)")
    }
    private func assertNeighborCovers(_ flow: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let viewport = flow.frame
        let visible = flow.cells.allElementsBoundByIndex.map(\.frame).filter { $0.intersection(viewport).width >= 12 }
        XCTAssertTrue(visible.contains { $0.midX < viewport.midX - 30 }, "A real cover must remain visible on the left", file: file, line: line)
        XCTAssertTrue(visible.contains { $0.midX > viewport.midX + 30 }, "A real cover must remain visible on the right", file: file, line: line)
        guard let center = visible.min(by: { abs($0.midX - viewport.midX) < abs($1.midX - viewport.midX) }),
              let left = visible.filter({ $0.midX < center.midX - 30 }).max(by: { $0.midX < $1.midX }),
              let right = visible.filter({ $0.midX > center.midX + 30 }).min(by: { $0.midX < $1.midX }) else {
            return XCTFail("The focused cover needs two visible neighbors", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(center.minX - left.maxX, 8, "Left cover needs breathing room", file: file, line: line)
        XCTAssertGreaterThanOrEqual(right.minX - center.maxX, 8, "Right cover needs breathing room", file: file, line: line)
        XCTAssertGreaterThanOrEqual(left.intersection(viewport).width, 24, file: file, line: line)
        XCTAssertGreaterThanOrEqual(right.intersection(viewport).width, 24, file: file, line: line)
        XCTAssertGreaterThan(left.midX, viewport.minX, file: file, line: line)
        XCTAssertLessThan(right.midX, viewport.maxX, file: file, line: line)
        if viewport.width >= 1200 {
            XCTAssertEqual(visible.filter { $0.midX < center.midX - 30 }.count, 3,
                           "Wide iPad needs the complete left fan", file: file, line: line)
            XCTAssertEqual(visible.filter { $0.midX > center.midX + 30 }.count, 3,
                           "Two-instance looping must also fill the right fan", file: file, line: line)
        }
    }
}
