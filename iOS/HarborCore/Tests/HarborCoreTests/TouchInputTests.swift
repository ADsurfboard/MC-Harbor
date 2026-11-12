import XCTest
@testable import HarborCore

final class TouchInputTests: XCTestCase {
    func testTwoFingersOwningOneKeyReleaseOnlyAfterLastFinger() {
        var router = TouchInputRouter(); let a = UUID(), b = UUID()
        XCTAssertEqual(router.replace(owner: a, inputs: [.key(87)]), [.press(.key(87))])
        XCTAssertEqual(router.replace(owner: b, inputs: [.key(87)]), [])
        XCTAssertEqual(router.release(owner: a), [])
        XCTAssertEqual(router.heldInputs, [.key(87)])
        XCTAssertEqual(router.release(owner: b), [.release(.key(87))])
        XCTAssertTrue(router.heldInputs.isEmpty)
    }
    func testEightDirectionsAndCenterDoNotLeaveStuckKeys() {
        var router = TouchInputRouter(); let finger = UUID()
        var settings = TouchSettings(); settings.autoSprint = false
        let cases: [(Double, Double, Set<GameInput>)] = [
            (0,-1,[.key(87)]), (1,-1,[.key(87),.key(68)]), (1,0,[.key(68)]), (1,1,[.key(68),.key(83)]),
            (0,1,[.key(83)]), (-1,1,[.key(83),.key(65)]), (-1,0,[.key(65)]), (-1,-1,[.key(65),.key(87)]), (0,0,[])
        ]
        for (x,y,expected) in cases {
            _ = router.moveJoystick(owner: finger, x: x, y: y, settings: settings)
            XCTAssertEqual(router.heldInputs, expected, "direction \(x),\(y)")
        }
        XCTAssertEqual(router.releaseAll(), [])
    }
    func testMovementAndAttackRemainIndependentDuringMultiTouch() {
        var router = TouchInputRouter(); let joystick = UUID(), attack = UUID(), jump = UUID()
        var settings = TouchSettings(); settings.autoSprint = false
        _ = router.moveJoystick(owner: joystick, x: 0, y: -1, settings: settings)
        _ = router.press(button: .init(action: .attack, x: 1, y: 1), touch: attack)
        _ = router.press(button: .init(action: .jump, x: 1, y: 1), touch: jump)
        XCTAssertEqual(router.heldInputs, [.key(87),.key(32),.mouseButton(0)])
        _ = router.release(owner: attack)
        XCTAssertEqual(router.heldInputs, [.key(87),.key(32)])
        XCTAssertEqual(router.releaseAll().count, 2)
        XCTAssertTrue(router.heldInputs.isEmpty)
    }
    func testBackgroundCancellationAlsoResetsToggleState() {
        var router = TouchInputRouter(); let button = TouchButton(action: .sneak, x: 1, y: 1, toggle: true)
        let touch = UUID()
        XCTAssertEqual(router.press(button: button, touch: touch), [.press(.key(340))])
        XCTAssertEqual(router.release(owner: touch), [])
        XCTAssertEqual(router.releaseAll(), [.release(.key(340))])
        XCTAssertEqual(router.press(button: button, touch: UUID()), [.press(.key(340))])
        XCTAssertEqual(router.press(button: button, touch: UUID()), [.release(.key(340))])
    }
    func testAutoSprintThresholdAndInvalidCoordinatesReleaseMovement() {
        var router = TouchInputRouter(); let id = UUID(); let settings = TouchSettings()
        _ = router.moveJoystick(owner: id, x: 0, y: -0.8, settings: settings)
        XCTAssertEqual(router.heldInputs, [.key(87)])
        _ = router.moveJoystick(owner: id, x: 0, y: -1, settings: settings)
        XCTAssertEqual(router.heldInputs, [.key(87), .key(341)])
        _ = router.moveJoystick(owner: id, x: .infinity, y: 0, settings: settings)
        XCTAssertTrue(router.heldInputs.isEmpty)
        _ = router.moveJoystick(owner: id, x: 0.05, y: 0, settings: settings)
        XCTAssertTrue(router.heldInputs.isEmpty)
    }
    func testAllMinecraftActionsMapToValidDistinctBindings() {
        let bindings = ControlAction.allCases.map(TouchInputRouter.binding)
        XCTAssertEqual(bindings.count, Set(bindings).count)
        XCTAssertEqual(TouchInputRouter.binding(.hotbar1), .key(49))
        XCTAssertEqual(TouchInputRouter.binding(.hotbar9), .key(57))
        XCTAssertEqual(TouchInputRouter.binding(.pause), .key(256))
    }
    func testCameraSensitivityInversionAndNonFiniteInput() {
        var settings = TouchSettings(); settings.cameraSensitivity = 2; settings.invertCameraY = true
        XCTAssertEqual(TouchInputRouter.look(dx: 12, dy: -5, settings: settings), [.look(24,10)])
        XCTAssertEqual(TouchInputRouter.look(dx: .nan, dy: 0, settings: settings), [])
        XCTAssertEqual(TouchInputRouter.look(dx: 10_000, dy: 0, settings: settings), [.look(1200,0)])
    }
}
