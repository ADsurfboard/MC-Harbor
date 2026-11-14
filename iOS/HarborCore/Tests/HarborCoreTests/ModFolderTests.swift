import XCTest
@testable import HarborCore

/// Tests use storage fixtures, never claim those fixtures are runnable mods.
final class ModFolderTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarborFolders-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func jar(_ name: String, in root: URL, content: String = "fixture") throws -> URL {
        let url = root.appendingPathComponent(name)
        try (Data([0x50, 0x4b, 0x03, 0x04]) + Data(content.utf8)).write(to: url)
        return url
    }
    func testFolderMetadataPersistsAndInvalidChangesDoNotCommit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try ModFolderLibrary(root: root)
        let id = try await library.create(name: "  优化模组  ")
        try await library.update(id, name: "PVP", color: "#c5d8ee")
        let before = await library.snapshot()
        for color in ["red", "#XYZ123", "../../private"] {
            do { try await library.update(id, name: "错误改名", color: color); XCTFail("Must reject invalid color") }
            catch {}
        }
        do { _ = try await library.create(name: String(repeating: "长", count: 61)); XCTFail() } catch {}
        let reloaded = try ModFolderLibrary(root: root)
        let after = await reloaded.snapshot()
        XCTAssertEqual(before.identity, after.identity)
        XCTAssertEqual(before.folders, after.folders)
        XCTAssertEqual(after.folders.first?.name, "PVP")
    }
    func testCopiesDeduplicateAndDragTransfersRemainAtomic() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try jar("a.jar", in: root, content: "a"), b = try jar("b.jar", in: root, content: "b")
        let original = try Data(contentsOf: a)
        let library = try ModFolderLibrary(root: root.appendingPathComponent("library"))
        let first = try await library.create(name: "第一个"), second = try await library.create(name: "第二个")
        let added = try await library.importFiles([.init(file: a), .init(file: b), .init(file: a)], to: first)
        XCTAssertEqual(added, 2)
        let initial = await library.snapshot()
        let entries = try XCTUnwrap(initial.folders.first?.mods)
        let payload = FolderModDrag(library: initial.identity, folder: first, mods: [entries[0].id])
        try await library.transfer(payload, to: second, copy: true)
        var value = await library.snapshot()
        XCTAssertEqual(value.folders[0].mods.count, 2)
        XCTAssertEqual(value.folders[1].mods.count, 1)
        try await library.transfer(payload, to: second)
        value = await library.snapshot()
        XCTAssertEqual(value.folders[0].mods.count, 1)
        XCTAssertEqual(value.folders[1].mods.count, 1)
        do { try await library.transfer(payload, to: second); XCTFail("Stale drag must fail") } catch {}
        let foreign = FolderModDrag(library: UUID(), folder: second, mods: [entries[0].id])
        do { try await library.transfer(foreign, to: first); XCTFail("Foreign drag must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: a), original)
        let reloaded = try ModFolderLibrary(root: root.appendingPathComponent("library"))
        let disk = await reloaded.snapshot()
        XCTAssertEqual(value.folders, disk.folders)
    }
    func testBatchFailureAndSymlinkDoNotCreatePartialCollections() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try jar("a.jar", in: root)
        let library = try ModFolderLibrary(root: root.appendingPathComponent("library"))
        let folder = try await library.create(name: "保留原件")
        do {
            _ = try await library.importFiles([.init(file: source), .init(file: root.appendingPathComponent("missing.jar"))], to: folder)
            XCTFail("All-or-nothing import required")
        } catch {}
        let state = await library.snapshot()
        XCTAssertTrue(state.folders[0].mods.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library/files").path)
        XCTAssertTrue(files.isEmpty)
        let link = root.appendingPathComponent("link.jar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try await library.importFiles([.init(file: link)], to: folder); XCTFail("Reject source symlink") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testReorderingAndSelectedRemovalKeepOtherFoldersAndFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = try ["a", "b", "c"].map { try jar($0 + ".jar", in: root, content: $0) }
        let library = try ModFolderLibrary(root: root.appendingPathComponent("library"))
        let folder = try await library.create(name: "排序")
        _ = try await library.importFiles(files.map { .init(file: $0) }, to: folder)
        var state = await library.snapshot()
        let first = state.folders[0].mods[0].id
        try await library.transfer(.init(library: state.identity, folder: folder, mods: [first]), to: folder, at: 3)
        state = await library.snapshot()
        XCTAssertEqual(state.folders[0].mods.map(\.filename), ["b.jar", "c.jar", "a.jar"])
        try await library.remove([first], from: folder)
        state = await library.snapshot()
        XCTAssertEqual(state.folders[0].mods.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library/files/" + first + ".jar").path))
    }
    func testInstanceInstallSkipsExactCopiesAndRejectsConflictsBeforeCommit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try jar("a.jar", in: root, content: "a"), b = try jar("b.jar", in: root, content: "b")
        let library = try ModFolderLibrary(root: root.appendingPathComponent("library"))
        let folder = try await library.create(name: "安装")
        _ = try await library.importFiles([.init(file: a), .init(file: b)], to: folder)
        let state = await library.snapshot(), ids = Set((await library.snapshot()).folders[0].mods.map(\.id))
        let destination = root.appendingPathComponent("instance/mods")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let conflict = try jar("B.JAR", in: destination, content: "old player mod")
        let old = try Data(contentsOf: conflict)
        do { _ = try await library.install(ids, from: folder, to: destination); XCTFail("No overwrite") } catch {}
        XCTAssertEqual(try Data(contentsOf: conflict), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.jar").path))
        try FileManager.default.removeItem(at: conflict)
        let installed = try await library.install(ids, from: folder, to: destination)
        XCTAssertEqual(installed, 2)
        let duplicate = try await library.install(ids, from: folder, to: destination)
        XCTAssertEqual(duplicate, 0)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: destination.appendingPathComponent("a.jar")))
        let blob = try await library.fileURL(for: state.folders[0].mods[0].id)
        _ = try jar(blob.lastPathComponent, in: blob.deletingLastPathComponent(), content: "corruption")
        let fresh = root.appendingPathComponent("other-instance/mods")
        do { _ = try await library.install(ids, from: folder, to: fresh); XCTFail("Verify stored bytes") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("a.jar").path))
    }
}
