import XCTest
@testable import HarborCore

@MainActor final class SocialPlayHistoryTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-history-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func testOpeningDoesNotInventHistoryOrCreateFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SocialPlayHistory(home: root), values = await store.snapshot()
        XCTAssertTrue(values.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("harbor-play-history").path))
    }
    func testForegroundTimePausesAndSurvivesRestartExactly() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SocialPlayHistory(home: root)
        _ = try await store.start(profile: "fabric", instance: "游戏实例", version: "1.20.1", loader: "Fabric", friends: [], wallTime: 1_700_000_000, uptime: 100)
        let first = try await store.checkpoint(uptime: 220); XCTAssertEqual(first.first?.seconds, 120)
        _ = try await store.pause(uptime: 280)
        let paused = try await store.checkpoint(uptime: 900); XCTAssertEqual(paused.first?.seconds, 180)
        _ = try await store.resume(uptime: 1000)
        let finished = try await store.finish(uptime: 1030); XCTAssertEqual(finished.first?.seconds, 210)
        let reopened = try SocialPlayHistory(home: root), saved = await reopened.snapshot()
        XCTAssertEqual(saved, finished); let active = await reopened.hasActiveSession(); XCTAssertFalse(active)
    }
    func testRepeatedSurfaceDoesNotDuplicateAndProfileChangeEndsPrevious() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SocialPlayHistory(home: root)
        let initial = try await store.start(profile: "a", instance: "A", version: "1.20.1", loader: "Fabric", friends: [], wallTime: 1_700_000_000, uptime: 10)
        let repeatStart = try await store.start(profile: "a", instance: "A", version: "1.20.1", loader: "Fabric", friends: [], wallTime: 1_700_000_010, uptime: 30)
        XCTAssertEqual(repeatStart.count, 1); XCTAssertEqual(repeatStart.first?.id, initial.first?.id); XCTAssertEqual(repeatStart.first?.seconds, 20)
        let next = try await store.start(profile: "b", instance: "B", version: "1.21", loader: "Forge", friends: [], wallTime: 1_700_000_100, uptime: 100)
        XCTAssertEqual(next.count, 2); XCTAssertEqual(next.first { $0.instance == "A" }?.seconds, 90)
        XCTAssertEqual(next.first { $0.instance == "B" }?.seconds, 0)
    }
    func testKilledProcessKeepsLastCheckpointWithoutInventingElapsedTime() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try SocialPlayHistory(home: root)
        _ = try await original.start(profile: "a", instance: "A", version: "1.20.1", loader: "Fabric", friends: [], wallTime: 1_700_000_000, uptime: 10)
        _ = try await original.checkpoint(uptime: 70)
        let recovered = try SocialPlayHistory(home: root)
        let later = try await recovered.resume(uptime: 99999); XCTAssertEqual(later.first?.seconds, 60)
        let still = try await recovered.checkpoint(uptime: 999999); XCTAssertEqual(still.first?.seconds, 60)
    }
    func testCorruptOrLinkedIndexIsPreserved() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("harbor-play-history"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = folder.appendingPathComponent("history-v1.json"), bytes = Data("{broken".utf8)
        try bytes.write(to: index)
        XCTAssertThrowsError(try SocialPlayHistory(home: root)); XCTAssertEqual(try Data(contentsOf: index), bytes)
        try FileManager.default.removeItem(at: index)
        let outside = root.appendingPathComponent("private.json"); try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outside)
        XCTAssertThrowsError(try SocialPlayHistory(home: root)); XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }
    func testWriteFailureRollsBackMemoryAndPreservesDurableData() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SocialPlayHistory(home: root)
        let original = try await store.start(profile: "a", instance: "A", version: "1.20.1", loader: "Fabric", friends: [], wallTime: 1_700_000_000, uptime: 10)
        let index = root.appendingPathComponent("harbor-play-history/history-v1.json"), backup = root.appendingPathComponent("preserved.json")
        let bytes = try Data(contentsOf: index)
        try FileManager.default.moveItem(at: index, to: backup); try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        do { _ = try await store.checkpoint(uptime: 100); XCTFail("write failure ignored") } catch { }
        let current = await store.snapshot(); XCTAssertEqual(current, original); XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }
}
