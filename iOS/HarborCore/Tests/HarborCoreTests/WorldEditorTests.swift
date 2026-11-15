import XCTest
@testable import HarborCore

@MainActor final class WorldEditorTests: XCTestCase {
    private let owner = "00010203-0405-0607-0809-0a0b0c0d0e0f"
    private func be(_ value: UInt64, _ width: Int) -> Data { Data(stride(from: (width - 1) * 8, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) }) }
    private func text(_ value: String) -> Data { be(UInt64(value.utf8.count), 2) + Data(value.utf8) }
    private func tag(_ type: UInt8, _ name: String, _ value: Data) -> Data { Data([type]) + text(name) + value }
    private func int(_ name: String, _ value: UInt64) -> Data { tag(3, name, be(value, 4)) }
    private func float(_ name: String, _ value: Float) -> Data { tag(5, name, be(UInt64(value.bitPattern), 4)) }
    private func player(_ uuid: UUID, health: Float = 20) -> Data {
        var value = float("Health", health) + int("foodLevel", 20) + float("foodSaturationLevel", 5)
        value += int("XpLevel", 0) + float("XpP", 0) + int("XpTotal", 0) + int("playerGameType", 0)
        var uuidBytes = uuid.uuid
        value += tag(11, "UUID", be(4, 4) + withUnsafeBytes(of: &uuidBytes) { Data($0) })
        var abilities = Data()
        for key in ["mayfly", "invulnerable", "instabuild", "mayBuild", "flying"] { abilities += tag(1, key, Data([key == "mayBuild" ? 1 : 0])) }
        value += tag(10, "abilities", abilities + Data([0])); value.append(0); return value
    }
    private func create(mirror: Bool = true, player: Bool = true) throws -> (URL, URL, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let instance = home.appendingPathComponent("instance"), world = instance.appendingPathComponent("saves/World")
        try FileManager.default.createDirectory(at: world, withIntermediateDirectories: true)
        var data = tag(8, "LevelName", text("Original")) + int("GameType", 0)
        data += tag(1, "Difficulty", Data([2])) + tag(1, "hardcore", Data([0])) + tag(1, "allowCommands", Data([0]))
        data += tag(4, "DayTime", be(48000, 8)) + tag(4, "Time", be(96000, 8))
        data += tag(10, "Version", tag(8, "Name", text("1.20.1")) + Data([0]))
        data += tag(7, "mod_blob", be(6, 4) + Data([0, 255, 128, 17, 31, 99]))
        if player { data += tag(10, "Player", self.player(UUID(uuidString: owner)!)) }
        data.append(0)
        let root = tag(10, "KeepRootName", tag(10, "Data", data) + Data([0]))
        try WorldNBTCodec.deflate(root, compression: .gzip).write(to: world.appendingPathComponent("level.dat"))
        try Data("untouched old save".utf8).write(to: world.appendingPathComponent("level.dat_old"))
        try Data([0xe2, 0x98, 0x83]).write(to: world.appendingPathComponent("session.lock"))
        if mirror && player {
            let file = world.appendingPathComponent("playerdata/" + owner + ".dat")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WorldNBTCodec.deflate(tag(10, "", self.player(UUID(uuidString: owner)!)), compression: .zlib).write(to: file)
        }
        return (home, instance, world)
    }
    func testSaveEditsWorldAndBothPlayerCopiesAfterVerifiedBackup() async throws {
        let (home, instance, world) = try create(); defer { try? FileManager.default.removeItem(at: home) }
        let store = WorldEditorStore(instance: instance, home: home), original = try Data(contentsOf: world.appendingPathComponent("level.dat"))
        let worlds = try await store.worlds(); XCTAssertEqual(worlds.map(\.id), ["World"])
        let before = try await store.read(folder: "World")
        XCTAssertEqual(before.player, "level"); XCTAssertEqual(before.players.count, 2)
        let changes: [String: WorldEditValue] = ["name": .text("新世界😀"), "gameMode": .number(1), "difficulty": .number(3), "hardcore": .number(1), "cheats": .number(1), "day": .number(3), "dayTick": .number(123), "ageTicks": .number(1000), "health": .number(7.5), "hunger": .number(12), "saturation": .number(6.25), "xpLevel": .number(20), "xpProgress": .number(0.5)]
        let after = try await store.save(folder: "World", player: before.player, revision: before.revision, changes: changes)
        XCTAssertFalse(before.revision == after.revision); XCTAssertEqual(after.values["name"], .text("新世界😀"))
        for (key, expected) in [("gameMode", 1.0), ("difficulty", 3), ("day", 3), ("dayTick", 123), ("ageTicks", 1000), ("health", 7.5), ("hunger", 12), ("saturation", 6.25), ("xpLevel", 20), ("xpProgress", 0.5), ("xpTotal", 581)] { XCTAssertEqual(after.values[key], .number(expected)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(after.backup).path))
        let mirror = try WorldNBTDocument(Data(contentsOf: world.appendingPathComponent("playerdata/" + owner + ".dat")))
        XCTAssertEqual(try mirror.number(XCTUnwrap(mirror.root.child("Health"))), 7.5)
        XCTAssertEqual(try mirror.number(XCTUnwrap(mirror.root.child("XpTotal"))), 581)
        let old = try WorldNBTDocument(original), current = try WorldNBTDocument(Data(contentsOf: world.appendingPathComponent("level.dat")))
        let a = try XCTUnwrap(old.root.at(["Data", "mod_blob"])), b = try XCTUnwrap(current.root.at(["Data", "mod_blob"]))
        XCTAssertEqual(Data(old.bytes[a.payload]), Data(current.bytes[b.payload]))
        XCTAssertEqual(try Data(contentsOf: world.appendingPathComponent("level.dat_old")), Data("untouched old save".utf8))
        XCTAssertEqual(try Data(contentsOf: world.appendingPathComponent("session.lock")), Data([0xe2, 0x98, 0x83]))
    }
    func testStaleRevisionAndInvalidValuesLeaveOriginalsUntouched() async throws {
        let (home, instance, world) = try create(); defer { try? FileManager.default.removeItem(at: home) }
        let store = WorldEditorStore(instance: instance, home: home), file = world.appendingPathComponent("level.dat"), original = try Data(contentsOf: file)
        let before = try await store.read(folder: "World")
        for change: [String: WorldEditValue] in [["health": .number(-1)], ["hunger": .number(21)], ["dayTick": .number(24000)], ["gameMode": .number(1.5)], ["xpLevel": .number(21864)], ["xpProgress": .number(1)], ["health": .number(.nan)], ["unrelated": .number(1)]] {
            do { _ = try await store.save(folder: "World", player: before.player, revision: before.revision, changes: change); XCTFail("invalid world edit accepted") } catch { }
        }
        do { _ = try await store.save(folder: "World", player: before.player, revision: "stale", changes: ["health": .number(1)]); XCTFail("stale revision accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("harbor-world-backups").path))
    }
    func testPlayerlessWorldSupportsWorldFieldsButRejectsInventedPlayer() async throws {
        let (home, instance, _) = try create(mirror: false, player: false); defer { try? FileManager.default.removeItem(at: home) }
        let store = WorldEditorStore(instance: instance, home: home), before = try await store.read(folder: "World")
        XCTAssertTrue(before.players.isEmpty); XCTAssertNil(before.values["health"])
        do { _ = try await store.save(folder: "World", player: nil, revision: before.revision, changes: ["health": .number(1)]); XCTFail("invented player accepted") } catch { }
        let after = try await store.save(folder: "World", player: nil, revision: before.revision, changes: ["difficulty": .number(1)])
        XCTAssertEqual(after.values["difficulty"], .number(1)); XCTAssertTrue(after.players.isEmpty)
    }
    func testAdventureAndSpectatorAbilitiesMatchTheChosenMode() async throws {
        let (home, instance, world) = try create(); defer { try? FileManager.default.removeItem(at: home) }
        let store = WorldEditorStore(instance: instance, home: home)
        for mode in [2.0, 3.0, 0.0] {
            let before = try await store.read(folder: "World")
            _ = try await store.save(folder: "World", player: before.player, revision: before.revision, changes: ["gameMode": .number(mode)])
            let doc = try WorldNBTDocument(Data(contentsOf: world.appendingPathComponent("level.dat")))
            let ability = try XCTUnwrap(doc.root.at(["Data", "Player", "abilities"]))
            XCTAssertEqual(try doc.number(XCTUnwrap(ability.child("mayBuild"))), mode == 0 ? 1 : 0)
            XCTAssertEqual(try doc.number(XCTUnwrap(ability.child("flying"))), mode == 3 ? 1 : 0)
            XCTAssertEqual(try doc.number(XCTUnwrap(ability.child("instabuild"))), 0)
        }
    }
    func testPlayerUUIDMismatchIsRejectedAndFloatProgressIsNotRoundedToOne() async throws {
        let (home, instance, world) = try create(); defer { try? FileManager.default.removeItem(at: home) }
        let store = WorldEditorStore(instance: instance, home: home)
        let before = try await store.read(folder: "World")
        let maximum = Double(Float(1).nextDown)
        let after = try await store.save(folder: "World", player: before.player, revision: before.revision, changes: ["xpProgress": .number(maximum)])
        let progress = try XCTUnwrap(after.values["xpProgress"])
        XCTAssertEqual(progress.number, maximum); XCTAssertFalse(progress.text == "1")
        let mirror = world.appendingPathComponent("playerdata/" + owner + ".dat")
        try WorldNBTCodec.deflate(tag(10, "", player(UUID())), compression: .gzip).write(to: mirror)
        let original = try Data(contentsOf: world.appendingPathComponent("level.dat"))
        do { _ = try await store.read(folder: "World"); XCTFail("mismatching player UUID accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: world.appendingPathComponent("level.dat")), original)
    }
    func testSymlinkAndEscapingWorldNeverReadOrModifyProtectedFile() async throws {
        let (home, instance, world) = try create(mirror: false); defer { try? FileManager.default.removeItem(at: home) }
        let protected = home.appendingPathComponent("protected.dat"), original = try Data(contentsOf: world.appendingPathComponent("level.dat"))
        try original.write(to: protected); try FileManager.default.removeItem(at: world.appendingPathComponent("level.dat"))
        try FileManager.default.createSymbolicLink(at: world.appendingPathComponent("level.dat"), withDestinationURL: protected)
        let store = WorldEditorStore(instance: instance, home: home)
        do { _ = try await store.read(folder: "World"); XCTFail("metadata symlink accepted") } catch { }
        do { _ = try await store.read(folder: "../World"); XCTFail("escaping folder accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: protected), original)
    }
    func testCancellationAfterFirstCommitRestoresBothOriginalsAndPermissions() async throws {
        let (home, instance, world) = try create(); defer { try? FileManager.default.removeItem(at: home) }
        let level = world.appendingPathComponent("level.dat"), mirror = world.appendingPathComponent("playerdata/" + owner + ".dat")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: level.path)
        let a = try Data(contentsOf: level), b = try Data(contentsOf: mirror)
        let store = WorldEditorStore(instance: instance, home: home, beforeReplace: { index in
            if index == 1 { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
        })
        let before = try await store.read(folder: "World")
        let task = Task { try await store.save(folder: "World", player: before.player, revision: before.revision, changes: ["health": .number(1)]) }
        do { _ = try await task.value; XCTFail("injected mid-commit cancellation ignored") } catch { }
        XCTAssertEqual(try Data(contentsOf: level), a); XCTAssertEqual(try Data(contentsOf: mirror), b)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: level.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let contents = try FileManager.default.subpathsOfDirectory(atPath: world.path)
        XCTAssertFalse(contents.contains { $0.contains(".harbor-world-") })
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("harbor-world-backups").path)
        XCTAssertEqual(backups.count, 1)
    }
    #if os(macOS)
    func testForeignJavaStyleFileLockBlocksWorldReadAndWrite() async throws {
        let (home, instance, world) = try create(mirror: false); defer { try? FileManager.default.removeItem(at: home) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'r+b'); fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB); print('locked',flush=True); sys.stdin.read(1)", world.appendingPathComponent("session.lock").path]
        process.standardInput = input; process.standardOutput = output; try process.run()
        defer { try? input.fileHandleForWriting.write(contentsOf: Data([1])); try? input.fileHandleForWriting.close(); process.waitUntilExit() }
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readData(ofLength: 7), as: UTF8.self), "locked\n")
        let store = WorldEditorStore(instance: instance, home: home)
        do { _ = try await store.read(folder: "World"); XCTFail("foreign world lock ignored") } catch { }
        do { _ = try await store.save(folder: "World", player: nil, revision: "unused", changes: ["health": .number(1)]); XCTFail("locked world modified") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("harbor-world-backups").path))
    }
    #endif
}
