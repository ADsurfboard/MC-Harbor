import XCTest
@testable import HarborCore

@MainActor final class WallpaperTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func fixture(_ root: URL, ext: String = "png", video: Bool = false) throws -> WallpaperPreparedMedia {
        let file = root.appendingPathComponent(UUID().uuidString + "." + ext)
        try Data("isolated-storage-fixture".utf8).write(to: file)
        return .init(original: file, thumbnail: Data("thumbnail-storage-fixture".utf8), fileExtension: ext, video: video)
    }
    func testImportRenameSelectionReloadAndDeletePreserveOriginal() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try fixture(root), library = WallpaperLibrary(home: root)
        let item = try await library.add(media, name: "  我的壁纸  ")
        XCTAssertEqual(item.name, "我的壁纸")
        try await library.select(item.id); try await library.rename(item.id, name: "命名预览")
        let fresh = WallpaperLibrary(home: root), loaded = try await fresh.load()
        XCTAssertEqual(loaded.items.count, 1); XCTAssertEqual(loaded.selected, item.id); XCTAssertEqual(loaded.items[0].name, "命名预览")
        let bytes = try await fresh.preview(item.id); XCTAssertEqual(bytes, media.thumbnail)
        try await fresh.remove(item.id)
        let removed = try await fresh.load(); XCTAssertTrue(removed.items.isEmpty); XCTAssertNil(removed.selected)
        XCTAssertEqual(try Data(contentsOf: media.original), Data("isolated-storage-fixture".utf8))
    }
    func testInvalidImportNeverRegistersOrCopies() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try fixture(root), library = WallpaperLibrary(home: root)
        for name in ["", " \n", String(repeating: "字", count: 81), "a\nb"] {
            do { _ = try await library.add(media, name: name); XCTFail("invalid name accepted") } catch { }
        }
        let mismatched = WallpaperPreparedMedia(original: media.original, thumbnail: media.thumbnail, fileExtension: "png", video: true)
        do { _ = try await library.add(mismatched, name: "Bad"); XCTFail("wrong media accepted") } catch { }
        let loaded = try await library.load(); XCTAssertTrue(loaded.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("harbor-wallpapers/library.json").path))
    }
    func testMissingSelectedFileFailsWithoutClearingValidIndex() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = WallpaperLibrary(home: root), media = try fixture(root)
        let item = try await library.add(media, name: "Image"); try await library.select(item.id)
        let path = try await library.media(item); try FileManager.default.removeItem(at: path)
        do { _ = try await library.media(item); XCTFail("missing media accepted") } catch { }
        let fresh = WallpaperLibrary(home: root), loaded = try await fresh.load()
        XCTAssertEqual(loaded.selected, item.id); XCTAssertEqual(loaded.items.count, 1)
        try await fresh.select(nil); let defaults = try await fresh.load(); XCTAssertNil(defaults.selected)
    }
    func testCorruptIndexIsPreservedAndSymlinkCannotEscape() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("harbor-wallpapers"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = folder.appendingPathComponent("library.json"), original = Data("corrupt but preserved".utf8); try original.write(to: index)
        let library = WallpaperLibrary(home: root)
        do { _ = try await library.load(); XCTFail("corrupt index accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: index), original)
        try FileManager.default.removeItem(at: index)
        let protected = root.appendingPathComponent("protected.json"); try original.write(to: protected)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: protected)
        do { try await WallpaperLibrary(home: root).select(nil); XCTFail("index symlink accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: protected), original)
    }
    func testVideoMarkerAndCopiesHaveIndependentStableIdentity() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try fixture(root, ext: "mov", video: true), library = WallpaperLibrary(home: root)
        let first = try await library.add(media, name: "动态一"), second = try await library.add(media, name: "动态二")
        XCTAssertTrue(first.video); XCTAssertTrue(second.video); XCTAssertFalse(first.id == second.id)
        try await library.select(second.id); try await library.remove(first.id)
        let loaded = try await library.load(); XCTAssertEqual(loaded.items.count, 1); XCTAssertEqual(loaded.selected, second.id)
        let path = try await library.media(second); XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
}
