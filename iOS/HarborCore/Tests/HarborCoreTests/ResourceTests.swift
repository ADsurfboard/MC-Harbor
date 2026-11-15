import XCTest
import CryptoKit
@testable import HarborCore

private actor ResourceProbe {
    var requests: [URLRequest] = []
    var active = 0
    var peak = 0
    func record(_ request: URLRequest) { requests.append(request) }
    func requestList() -> [URLRequest] { requests }
    func fetch(_ request: URLRequest) async throws -> ResourceHTTPResult {
        requests.append(request)
        return .init(data: Data(#"{"hits":[],"total_hits":0}"#.utf8), status: request.url?.host == "mod.mcimirror.top" ? 503 : 200)
    }
    func download(_ url: URL, _ target: URL, _ size: Int64) async throws {
        active += 1; peak = max(peak, active); defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30)); try Data("file".utf8).write(to: target, options: .withoutOverwriting)
    }
    func maximum() -> Int { peak }
}

@MainActor final class ResourceTests: XCTestCase {
    private func trace(_ text: String) {
        if ProcessInfo.processInfo.environment["HARBOR_RESOURCE_TEST_TRACE"] == "1" { FileHandle.standardError.write(Data(("[resource-boundary] " + text + "\n").utf8)) }
    }
    private func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func versionJSON(_ id: String = "version1", project: String = "project1", dependencies: [[String: Any]] = []) -> [String: Any] {
        ["id": id, "project_id": project, "name": "Example", "version_number": "1.0", "game_versions": ["1.20.1"], "loaders": ["fabric"], "dependencies": dependencies,
         "files": [["filename": project + ".jar", "url": "https://cdn.modrinth.com/data/" + project + "/file.jar", "size": 4, "primary": true, "hashes": ["sha512": String(repeating: "a", count: 128)]]]]
    }
    private func file(_ name: String = "example.jar", value: Data = Data("file".utf8)) -> ResourceFile {
        .init(name: name, url: URL(string: "https://cdn.modrinth.com/data/file.jar")!, size: Int64(value.count), hashes: ["sha512": SHA512.hash(data: value).map { String(format: "%02x", $0) }.joined()])
    }
    func testDomesticFallbackPreservesFacetsAndSeventhPage() async throws {
        let probe = ResourceProbe()
        let catalog = ResourceCatalog { request, _ in try await probe.fetch(request) }
        let result = try await catalog.search("Sodium", source: .modrinth, kind: .mod, target: .init(gameVersion: "1.20.1", loader: "Fabric"), page: 6)
        XCTAssertEqual(result.total, 0)
        let requests = await probe.requestList()
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0].url?.host, "mod.mcimirror.top"); XCTAssertEqual(requests[1].url?.host, "api.modrinth.com")
        let query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "offset" }?.value, "180")
        let facets = try XCTUnwrap(query.first { $0.name == "facets" }?.value)
        XCTAssertTrue(facets.contains("versions:1.20.1")); XCTAssertTrue(facets.contains("categories:fabric")); XCTAssertTrue(facets.contains("project_type:mod"))
    }
    func testOfficialOrderAndCurseForgeMirrorDoesNotShipAnAPIKey() async throws {
        let probe = ResourceProbe()
        let catalog = ResourceCatalog(route: .officialFirst) { request, _ in
            await probe.record(request)
            if request.url?.path.contains("mods/search") == true { return .init(data: Data(#"{"data":[],"pagination":{"totalCount":0}}"#.utf8), status: 200) }
            return .init(data: Data(#"{"hits":[],"total_hits":0}"#.utf8), status: 200)
        }
        _ = try await catalog.search("", source: .modrinth, kind: .shader, target: nil)
        _ = try await catalog.search("", source: .curseforge, kind: .mod, target: .init(gameVersion: "1.20.1", loader: "Forge"))
        let requests = await probe.requestList()
        XCTAssertEqual(requests.first?.url?.host, "api.modrinth.com")
        XCTAssertEqual(requests.last?.url?.path, "/curseforge/v1/mods/search")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertTrue(requests.last?.url?.query?.contains("modLoaderType=1") == true)
    }
    func testMalformedAndOversizedMetadataFailInsteadOfEmptySuccess() throws {
        XCTAssertThrowsError(try ResourceDecoding.modrinthSearch(Data("{}".utf8), kind: .mod))
        XCTAssertThrowsError(try ResourceDecoding.modrinthVersions(Data("{}".utf8)))
        XCTAssertThrowsError(try ResourceDecoding.modrinthSearch(Data(repeating: 0, count: 8 * 1024 * 1024 + 1), kind: .mod))
    }
    func testPrimaryFileAndMissingCurseDownloadArePreserved() throws {
        var json = versionJSON()
        var files = json["files"] as! [[String: Any]]
        var sources = files[0]; sources["primary"] = false; sources["filename"] = "sources.jar"
        files.insert(sources, at: 0); json["files"] = files
        XCTAssertEqual(try ResourceDecoding.modrinthVersion(bytes(json)).files.first?.name, "project1.jar")
        let cf: [String: Any] = ["data": ["id": 10, "displayName": "No direct download", "gameVersions": ["1.20.1", "Fabric"], "downloadUrl": NSNull(), "fileLength": 5]]
        let version = try ResourceDecoding.curseVersion(bytes(cf), project: "20")
        XCTAssertTrue(version.files.isEmpty); XCTAssertEqual(version.loaders, ["fabric"])
    }
    func testDependencyResolutionInstallsBeforeChosenMod() async throws {
        let childData = try bytes([versionJSON("child1", project: "child")])
        let catalog = ResourceCatalog { _, _ in .init(data: childData, status: 200) }
        let parent = try ResourceDecoding.modrinthVersion(bytes(versionJSON(dependencies: [["project_id": "child", "dependency_type": "required"]])))
        let plan = try await catalog.plan(parent, source: .modrinth, kind: .mod, target: .init(gameVersion: "1.20.1", loader: "fabric"))
        XCTAssertEqual(plan.map(\.name), ["child.jar", "project1.jar"])
        do { _ = try await catalog.plan(parent, source: .modrinth, kind: .mod, target: .init(gameVersion: "1.21", loader: "fabric")); XCTFail("incompatible version installed") } catch { }
    }
    func testDependencyCycleAndPathInjectionAreRejected() async throws {
        let cycle = try bytes([versionJSON(dependencies: [["project_id": "project1", "dependency_type": "required"]])])
        let catalog = ResourceCatalog { _, _ in .init(data: cycle, status: 200) }
        let selected = try ResourceDecoding.modrinthVersion(bytes(versionJSON(dependencies: [["project_id": "project1", "dependency_type": "required"]])))
        do { _ = try await catalog.plan(selected, source: .modrinth, kind: .mod, target: .init(gameVersion: "1.20.1", loader: "fabric")); XCTFail("cycle accepted") } catch { }
        do { _ = try await catalog.versions(project: "../../private", source: .modrinth, kind: .mod, target: nil); XCTFail("path accepted") } catch { }
    }
    func testFileValidationAndOrigins() throws {
        for name in ["../a.jar", ".hidden.jar", "a/b.jar", "a\\b.jar", "a:jar.jar", "bad\n.jar", "x.zip"] { XCTAssertThrowsError(try ResourceFileValidation.validate(file(name), kind: .mod)) }
        XCTAssertNoThrow(try ResourceFileValidation.validate(file("中文.jar"), kind: .mod))
        XCTAssertFalse(ResourceNetwork.fileURLAllowed(URL(string: "https://127.0.0.1/file.jar")!))
        XCTAssertFalse(ResourceNetwork.fileURLAllowed(URL(string: "http://cdn.modrinth.com/file.jar")!))
        XCTAssertFalse(ResourceNetwork.fileURLAllowed(URL(string: "https://name:pass@cdn.modrinth.com/file.jar")!))
        XCTAssertEqual(ResourceNetwork.candidates(file().url, route: .domesticFirst).first?.host, "mod.mcimirror.top")
    }
    func testInstallIsRealBoundedDeduplicatedAndPreservesConflicts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("instance/mods")
        let installer = ResourceInstaller(home: root), probe = ResourceProbe()
        let plan = (0..<8).map { file("mod\($0).jar") }
        let count = try await installer.install(plan, kind: .mod, destination: destination, route: .domesticFirst, download: { try await probe.download($0, $1, $2) })
        XCTAssertEqual(count, 8)
        let peak = await probe.maximum(); XCTAssertEqual(peak, 3)
        let again = try await installer.install(plan, kind: .mod, destination: destination, route: .domesticFirst, download: { try await probe.download($0, $1, $2) })
        XCTAssertEqual(again, 0)
        let conflict = destination.appendingPathComponent("conflict.jar"); try Data("original".utf8).write(to: conflict)
        do {
            _ = try await installer.install([file("new.jar"), file("CONFLICT.jar")], kind: .mod, destination: destination, route: .domesticFirst, download: { try await probe.download($0, $1, $2) })
            XCTFail("conflict overwritten")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: conflict), Data("original".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("new.jar").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("harbor-resource-downloads").path).isEmpty)
    }
    func testCorruptDownloadAndSymlinkTargetNeverCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("instance/mods"), installer = ResourceInstaller(home: root)
        trace("before corrupt file transfer")
        do {
            _ = try await installer.install([file()], kind: .mod, destination: destination, route: .domesticFirst, download: { _, target, _ in try Data("fake".utf8).write(to: target) })
            XCTFail("corrupt file accepted")
        } catch { }
        trace("corrupt file rejected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked").path, withDestinationPath: "/tmp")
        trace("before symlink early rejection")
        do { _ = try await installer.install([file()], kind: .mod, destination: root.appendingPathComponent("linked/mods"), route: .domesticFirst); XCTFail("symlink accepted") } catch { }
        trace("symlink rejected")
    }
    func testCancellationStopsBeforeCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let installer = ResourceInstaller(home: root), destination = root.appendingPathComponent("instance/mods")
        let task = Task {
            try await installer.install([file()], kind: .mod, destination: destination, route: .domesticFirst, download: { _, _, _ in try await Task.sleep(for: .seconds(10)) })
        }
        try await Task.sleep(for: .milliseconds(40)); task.cancel()
        do { _ = try await task.value; XCTFail("cancel accepted") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testEarlyRejectionsDoNotInvokeTransferOrLeaveStages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ResourceInstaller(home: root), probe = ResourceProbe()
        let destination = root.appendingPathComponent("instance/mods")
        for _ in 0..<8 {
            do { _ = try await installer.install([], kind: .mod, destination: destination, route: .domesticFirst); XCTFail("empty plan accepted") } catch { }
            do { _ = try await installer.install([file("../bad.jar")], kind: .mod, destination: destination, route: .domesticFirst); XCTFail("unsafe name accepted") } catch { }
            do {
                _ = try await installer.install([file()], kind: .mod, destination: root.appendingPathComponent("outside"), route: .domesticFirst, download: { url, _, _ in await probe.record(URLRequest(url: url)) })
                XCTFail("wrong directory accepted")
            } catch { }
        }
        let requests = await probe.requestList(); XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("harbor-resource-downloads").path))
    }
    func testChineseNamesAndCompleteTranslationOnly() throws {
        XCTAssertEqual(ResourceNames.english("机械动力"), "Create"); XCTAssertEqual(ResourceNames.chinese("Sodium"), "钠")
        let valid = try bytes(["choices": [["finish_reason": "stop", "message": ["content": "优化游戏内存占用"]]]])
        XCTAssertEqual(try ResourceTextService.parse(valid, provider: .bilibili, source: "Optimize memory", toChinese: true), "优化游戏内存占用")
        let partial = try bytes(["choices": [["finish_reason": "length", "message": ["content": "不完整"]]]])
        XCTAssertThrowsError(try ResourceTextService.parse(partial, provider: .bilibili, source: "Example", toChinese: true))
        XCTAssertThrowsError(try ResourceTextService.parse(valid, provider: .bilibili, source: "优化游戏内存占用", toChinese: true))
    }
    func testForeignTranslationIsExplicitAndCacheAvoidsRepeatRequests() async throws {
        let probe = ResourceProbe()
        let service = ResourceTextService { request, _ in
            await probe.record(request)
            return .init(data: Data(#"[[["中文简介","English"]]]"#.utf8), status: 200)
        }
        let first = try await service.translate("English", provider: .google)
        let second = try await service.translate("English", provider: .google)
        XCTAssertEqual(first, "中文简介"); XCTAssertEqual(second, first)
        let requests = await probe.requestList(); XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.url?.host, "translate.googleapis.com")
    }
}
