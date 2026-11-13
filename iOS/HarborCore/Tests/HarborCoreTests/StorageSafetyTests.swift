import XCTest
@testable import HarborCore

final class StorageSafetyTests: XCTestCase {
    func testControlsRemainInsideSmallAndLargeSafeAreas() {
        for width in [320.0, 568, 667, 844, 1024, 1366] {
            for height in [220.0, 320, 390, 768, 1024] {
                for point in [NormalizedPoint(x: 0, y: 0), .init(x: 1, y: 1), .init(x: 0.5, y: 0.5)] {
                    let frame = ControlFrame.fit(center: point, diameter: 160, availableWidth: width, availableHeight: height)
                    XCTAssertGreaterThanOrEqual(frame.x, 0); XCTAssertGreaterThanOrEqual(frame.y, 0)
                    XCTAssertLessThanOrEqual(frame.x + frame.width, width); XCTAssertLessThanOrEqual(frame.y + frame.height, height)
                    XCTAssertGreaterThanOrEqual(frame.width, 44)
                }
            }
        }
    }
    func testSanitizationPreservesEscapeRouteAndAccessibleTargets() throws {
        var layout = TouchLayout(name: "   ", buttons: [.init(action: .jump, x: -10, y: 5, diameter: 1, opacity: 0)])
        layout.settings.cameraSensitivity = .nan
        try layout.sanitize()
        XCTAssertEqual(layout.name, "我的触控布局")
        XCTAssertEqual(layout.buttons[0].diameter, 44)
        XCTAssertEqual(layout.buttons[0].center, .init(x: 0, y: 1))
        XCTAssertEqual(layout.settings.cameraSensitivity, 1)
        XCTAssertTrue(layout.buttons.contains { $0.action == .pause && $0.visible })
        let before = layout
        layout.mirrorHorizontally(); layout.mirrorHorizontally()
        XCTAssertEqual(layout, before)
    }
    func testPauseCannotBecomeAModKeyAndMirroringPreservesCameraChoice() throws {
        var layout = TouchLayout.standard()
        let index = try XCTUnwrap(layout.buttons.firstIndex { $0.action == .pause })
        layout.buttons[index].customKey = 65; layout.buttons[index].toggle = true
        layout.settings.invertCameraX = true
        try layout.sanitize()
        XCTAssertEqual(TouchInputRouter.binding(layout.buttons[index]), .key(256))
        XCTAssertFalse(layout.buttons[index].toggle)
        let before = layout
        layout.mirrorHorizontally(); layout.mirrorHorizontally()
        XCTAssertEqual(layout, before)
    }
    func testMalformedLayoutsAndFutureVersionsAreRejected() throws {
        var layout = TouchLayout.standard(); layout.schemaVersion = 99
        XCTAssertThrowsError(try TouchLayout.decode(JSONEncoder().encode(layout))) { XCTAssertEqual($0 as? TouchLayoutError, .unsupportedVersion(99)) }
        layout = .standard(); layout.buttons.append(layout.buttons[0])
        XCTAssertThrowsError(try layout.sanitize())
        XCTAssertThrowsError(try TouchLayout.decode(Data(repeating: 32, count: 128 * 1024 + 1)))
        XCTAssertThrowsError(try TouchLayout.decode(Data("{invalid}".utf8)))
    }
    func testImportedProfilesAreIndependentAndAtomicRoundTripsWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarborTouch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TouchLayoutStore(directory: root)
        let original = TouchLayout.standard(); try await store.save(original)
        let data = try await store.exportLayout(original)
        let imported = try await store.importLayout(data)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertEqual(imported.buttons, original.buttons)
        let layouts = try await store.layouts(); XCTAssertEqual(layouts.count, 2)
        try await store.delete(imported.id)
        let after = try await store.layouts(); XCTAssertEqual(after, [original])
    }
    func testZipSlipSymlinksCaseAliasesAndExpansionBombsRejected() {
        for path in ["../account.json", "/etc/hosts", "mods/../../secret", "C:/Windows/file", "mods\\evil.jar", "a//file", "a/./file", "a/\0file"] {
            XCTAssertThrowsError(try ArchiveSafety.validate([.init(path: path, compressedBytes: 1, expandedBytes: 1)], availableBytes: 4_000_000_000), path)
        }
        XCTAssertThrowsError(try ArchiveSafety.validate([.init(path: "mods/a", compressedBytes: 1, expandedBytes: 1, symbolicLink: true)], availableBytes: 4_000_000_000))
        XCTAssertThrowsError(try ArchiveSafety.validate([.init(path: "mods/A.jar", compressedBytes: 1, expandedBytes: 1), .init(path: "mods/a.jar", compressedBytes: 1, expandedBytes: 1)], availableBytes: 4_000_000_000))
        XCTAssertThrowsError(try ArchiveSafety.validate([.init(path: "bomb.json", compressedBytes: 10, expandedBytes: 100_000_000)], availableBytes: 4_000_000_000))
        XCTAssertThrowsError(try ArchiveSafety.validate([.init(path: "large.jar", compressedBytes: 400_000_000, expandedBytes: 400_000_000)], availableBytes: 500_000_000))
    }
    func testRealisticModpackDirectoryEntriesRemainValid() throws {
        try ArchiveSafety.validate([
            .init(path: "mods/", compressedBytes: 0, expandedBytes: 0),
            .init(path: "mods/sodium.jar", compressedBytes: 1_000_000, expandedBytes: 1_100_000),
            .init(path: "config/选项.json", compressedBytes: 100, expandedBytes: 400),
            .init(path: "overrides/saves/我的世界/level.dat", compressedBytes: 5000, expandedBytes: 8000)
        ], availableBytes: 4_000_000_000)
    }
}
