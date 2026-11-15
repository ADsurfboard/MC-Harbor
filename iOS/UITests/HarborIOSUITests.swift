import XCTest

@MainActor final class HarborIOSUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
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
        app.buttons["touch.save"].tap()
        XCTAssertTrue(touch.waitForExistence(timeout: 5)); touch.tap()
        XCTAssertEqual(app.textFields["touch.layout.name"].value as? String, "Harbor Touch QA")
        capture("touch-editor-restored")
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
