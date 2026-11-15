import XCTest
@testable import HarborCore

@MainActor final class LocalizationTests: XCTestCase {
    func testLanguageJSONRetainsKeysAndRejectsDuplicates() throws {
        var doc = try LocalizationDocument.read(Data(#"{"item.example.tool":"Tool %1$s","tip":"Use {0}"}"#.utf8), path: "assets/example/lang/en_us.json", kind: .languageJSON)
        XCTAssertEqual(doc.rows.map(\.key), ["item.example.tool", "tip"])
        doc.rows[0].translation = "工具 %1$s"; doc.rows[1].translation = "使用 {0}"
        let object = try JSONSerialization.jsonObject(with: doc.rendered()) as! [String: String]
        XCTAssertEqual(object["item.example.tool"], "工具 %1$s")
        XCTAssertEqual(object["tip"], "使用 {0}")
        XCTAssertThrowsError(try LocalizationDocument.read(Data(#"{"same":"a","same":"b"}"#.utf8), path: "assets/a/lang/en_us.json", kind: .languageJSON))
        XCTAssertThrowsError(try LocalizationDocument.read(Data(#"{"nested":{"text":"bad"}}"#.utf8), path: "assets/a/lang/en_us.json", kind: .languageJSON))
        XCTAssertThrowsError(try LocalizationDocument.read(Data(#"{key:"lenient"}"#.utf8), path: "assets/a/lang/en_us.json", kind: .languageJSON))
    }
    func testLegacyKeepsCommentsCRLFAndFirstEqualsOnly() throws {
        let original = Data("# comment\r\nkey=Value = %s\r\nnext=Another\r\n".utf8)
        var doc = try LocalizationDocument.read(original, path: "assets/a/lang/en_us.lang", kind: .languageLegacy)
        XCTAssertEqual(doc.rows[0].source, "Value = %s")
        doc.rows[0].translation = "值 = %s"
        XCTAssertEqual(String(decoding: try doc.rendered(), as: UTF8.self), "# comment\r\nkey=值 = %s\r\nnext=Another\r\n")
        doc.rows[0].translation = "错误换行\n%s"; XCTAssertThrowsError(try doc.rendered())
    }
    func testFTBSNBTPatchesOnlyPresentationSpans() throws {
        let original = """
        {
          // preserve order, relationships and rewards
          id: "12ABCD"
          title: "First steps"
          description: ["Get wood", "Use %s"]
          tasks: [{ type: "item", item: "minecraft:oak_log", count: 3L }]
          rewards: [{ type: "xp", xp: 25 }]
          dependencies: [L; 123L, 456L]
        }
        """
        var doc = try LocalizationDocument.read(Data(original.utf8), path: "chapters/start.snbt", kind: .ftbQuest)
        XCTAssertEqual(doc.rows.map(\.source), ["First steps", "Get wood", "Use %s"])
        doc.rows[0].translation = "开始旅程"; doc.rows[1].translation = "获取木头"; doc.rows[2].translation = "使用 %s"
        let text = String(decoding: try doc.rendered(), as: UTF8.self)
        XCTAssertTrue(text.contains("id: \"12ABCD\"")); XCTAssertTrue(text.contains("count: 3L"))
        XCTAssertTrue(text.contains("dependencies: [L; 123L, 456L]")); XCTAssertTrue(text.contains("xp: 25"))
        XCTAssertTrue(text.contains("// preserve order, relationships and rewards")); XCTAssertTrue(text.contains("开始旅程"))
    }
    func testUnicodeSingleTripleQuotedLocaleAndMalformedInput() throws {
        let text = "{ title: '''A long\nquest''' description: '\\uD83C\\uDF0D World' }"
        let doc = try LocalizationDocument.read(Data(text.utf8), path: "lang/en_us.snbt", kind: .ftbLocale)
        XCTAssertEqual(doc.rows.map(\.source), ["A long\nquest", "🌍 World"])
        XCTAssertThrowsError(try LocalizationDocument.read(Data("{title:'\\uD800'}".utf8), path: "a.snbt", kind: .ftbQuest))
        XCTAssertThrowsError(try LocalizationDocument.read(Data("{title:'incomplete'".utf8), path: "a.snbt", kind: .ftbQuest))
        XCTAssertThrowsError(try LocalizationDocument.read(Data(repeating: 0xff, count: 5), path: "a.snbt", kind: .ftbQuest))
        XCTAssertThrowsError(try LocalizationDocument.read(Data("{}".utf8), path: "../a.snbt", kind: .ftbQuest))
    }
    func testDatapackComponentsAvoidCommandsAndIdentifiers() throws {
        let text = #"{"display":{"title":{"text":"My Title"},"description":{"translate":"example.key","fallback":"My fallback"},"icon":{"id":"minecraft:stone"}},"criteria":{"minecraft:stone":{"trigger":"minecraft:impossible"}}}"#
        var doc = try LocalizationDocument.read(Data(text.utf8), path: "data/a/advancements/start.json", kind: .datapack)
        XCTAssertEqual(doc.rows.map(\.source), ["My Title", "My fallback"])
        doc.rows[0].translation = "我的标题"
        let result = String(decoding: try doc.rendered(), as: UTF8.self)
        XCTAssertTrue(result.contains("example.key")); XCTAssertTrue(result.contains("minecraft:impossible")); XCTAssertTrue(result.contains("我的标题"))
    }
    func testFunctionOnlyReadsChatPayloadAndKeepsExecutePrefix() throws {
        let text = "# untouched\nsay Do not rewrite commands\nexecute as @a run tellraw @s {\"text\":\"Welcome %s\",\"clickEvent\":{\"action\":\"run_command\",\"value\":\"/op @s\"}}\ntitle @a actionbar \"Ready\"\n"
        var doc = try LocalizationDocument.read(Data(text.utf8), path: "data/a/function/start.mcfunction", kind: .function)
        XCTAssertEqual(doc.rows.map(\.source), ["Welcome %s", "Ready"])
        doc.rows[0].translation = "欢迎 %s"; doc.rows[1].translation = "准备就绪"
        let result = String(decoding: try doc.rendered(), as: UTF8.self)
        XCTAssertTrue(result.contains("say Do not rewrite commands")); XCTAssertTrue(result.contains("execute as @a run tellraw @s")); XCTAssertTrue(result.contains("/op @s"))
    }
    func testPlaceholderMultisetsAndFormattingAreStrict() {
        XCTAssertTrue(LocalizationPlaceholders.compatible("Hello %1$s: {0} §a<bold>X</bold>", "你好 {0}：%1$s §a<bold>X</bold>"))
        XCTAssertFalse(LocalizationPlaceholders.compatible("%s %s", "%s"))
        XCTAssertFalse(LocalizationPlaceholders.compatible("${key} $(item)", "${other} $(item)"))
        XCTAssertFalse(LocalizationPlaceholders.compatible("%1$d", "%1$s"))
        XCTAssertFalse(LocalizationPlaceholders.compatible("§aGreen", "§c红"))
    }
    func testDraftsSurviveUnchangedSourceAndDoNotLeakToChangedSource() throws {
        let doc = try LocalizationDocument.read(Data(#"{"a":"Hello"}"#.utf8), path: "assets/a/lang/en_us.json", kind: .languageJSON)
        let source = LocalizationSource(name: "Example", installPath: "mods/example.jar", kind: "mods", documents: [doc])
        var old = LocalizationProject(name: "翻译", sources: [source])
        try old.setTranslation(row: source.documents[0].rows[0].id, value: "你好")
        var fresh = LocalizationProject(name: "翻译", sources: [source]); fresh.inheritDrafts(from: old)
        XCTAssertEqual(fresh.counts.translated, 1)
        let changed = try LocalizationDocument.read(Data(#"{"a":"Changed"}"#.utf8), path: doc.path, kind: doc.kind)
        fresh.sources[0].documents = [changed]; fresh.inheritDrafts(from: old)
        XCTAssertEqual(fresh.counts.translated, 0)
        XCTAssertThrowsError(try fresh.setTranslation(row: "missing", value: "bad"))
    }
    func testSourceExportIsExplicitAndConflictingKeysFail() throws {
        let doc = try LocalizationDocument.read(Data(#"{"a":"Hello %s"}"#.utf8), path: "assets/a/lang/en_us.json", kind: .languageJSON)
        var project = LocalizationProject(name: "测试", sources: [.init(name: "Mod", installPath: "mods/a.jar", kind: "mods", documents: [doc])])
        let raw = try LocalizationPack.entries(project, sourceOnly: true)
        XCTAssertTrue(raw.contains { $0.path.hasPrefix("original/") }); XCTAssertTrue(raw.contains { $0.path == "AI-translation.json" })
        let target = try XCTUnwrap(raw.first { $0.path == "assets/a/lang/zh_cn.json" })
        XCTAssertEqual((try JSONSerialization.jsonObject(with: target.data) as! [String: String])["a"], "Hello %s")
        let conflicting = try LocalizationDocument.read(Data(#"{"a":"Different"}"#.utf8), path: doc.path, kind: doc.kind)
        project.sources.append(.init(name: "Conflict", installPath: "mods/b.jar", kind: "mods", documents: [conflicting]))
        XCTAssertThrowsError(try LocalizationPack.entries(project, sourceOnly: true))
    }
    func testWorkspaceIsAtomicAndRejectsSymlinkWithoutTouchingOriginal() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: home) }
        let store = LocalizationWorkspaceStore(home: home, instance: "../../profile")
        try await store.save(.init(name: "Initial")); let first = try await store.load()
        XCTAssertEqual(first?.name, "Initial")
        let folder = home.appendingPathComponent("harbor-localization")
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: file)
        let original = home.appendingPathComponent("original.json"); try Data("protect".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        do { try await store.save(.init(name: "Never overwrite")); XCTFail("symlink accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: original), Data("protect".utf8))
    }
    func testZIPIsDeterministicAndNeverOverwrites() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: home) }
        let entries = [LocalizationExportEntry(path: "assets/测试/lang/zh_cn.json", data: Data(#"{"a":"你好"}"#.utf8)), .init(path: "pack.mcmeta", data: Data("{}".utf8))]
        let a = home.appendingPathComponent("a.zip"), b = home.appendingPathComponent("b.zip")
        try LocalizationZIP.write(entries, to: a); try LocalizationZIP.write(entries.reversed(), to: b)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        XCTAssertThrowsError(try LocalizationZIP.write(entries, to: a))
        XCTAssertThrowsError(try LocalizationZIP.write([.init(path: "../outside", data: Data())], to: home.appendingPathComponent("bad.zip")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("bad.zip").path))
    }
    func testArchivePreservesEveryLocaleAndScopesRowsByResource() throws {
        let english = Data(#"{"a":"Hello %s","b":"World"}"#.utf8)
        let entries = ["assets/a/lang/en_us.json": english, "assets/a/lang/en_gb.json": Data(#"{"a":"Hello GB"}"#.utf8),
                       "assets/a/lang/zh_cn.json": Data(#"{"a":"你好 %s"}"#.utf8), "assets/a/lang/fr_fr.json": Data(#"{"a":"Bonjour"}"#.utf8)]
        let first = try LocalizationScanner.archive(entries: entries, name: "A", installPath: "mods/a.jar", kind: "mods")
        let second = try LocalizationScanner.archive(entries: entries, name: "B", installPath: "mods/b.jar", kind: "mods")
        XCTAssertEqual(first.documents.count, 1); XCTAssertEqual(first.documents[0].rows[0].translation, "你好 %s")
        XCTAssertFalse(first.documents[0].rows[0].id == second.documents[0].rows[0].id)
        let exported = try LocalizationPack.entries(.init(name: "All", sources: [first]), sourceOnly: true)
        XCTAssertEqual(exported.filter { $0.path.hasPrefix("original/") }.count, 4)
        XCTAssertTrue(exported.contains { $0.path.hasSuffix("fr_fr.json") })
        let changed = try LocalizationScanner.archive(entries: ["assets/a/lang/en_us.json": Data(#"{"a":"Changed","b":"World"}"#.utf8)], name: "A", installPath: "mods/a.jar", kind: "mods")
        XCTAssertEqual(first.documents[0].rows[1].id, changed.documents[0].rows[1].id)
    }
    func testLooseScannerReadsKubeJSFTBWorldDataAndReportsBadFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: home) }
        let files = ["kubejs/assets/pack/lang/en_us.json": #"{"item.pack.tool":"Custom Tool"}"#,
                     "config/ftbquests/quests/chapter.snbt": "{id:'ABC' title:'Start' tasks:[{type:'item' item:'minecraft:stone'}]}",
                     "config/ftbquests/quests/bad.snbt": "{title:'broken'",
                     "saves/World/datapacks/quest/data/pack/advancements/start.json": #"{"display":{"title":{"text":"Find stone"}},"criteria":{"id":{"trigger":"minecraft:impossible"}}}"#]
        for (path, text) in files { let file = home.appendingPathComponent(path); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: file) }
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("kubejs/assets/linked").path, withDestinationPath: "/tmp")
        let result = try LocalizationScanner.loose(instance: home)
        XCTAssertEqual(result.sources.count, 3); XCTAssertEqual(result.sources.flatMap(\.documents).flatMap(\.rows).count, 3)
        XCTAssertTrue(result.warnings.contains { $0.contains("bad.snbt") }); XCTAssertTrue(result.warnings.contains { $0.contains("符号链接") })
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("config/ftbquests/quests/chapter.snbt"), encoding: .utf8), files["config/ftbquests/quests/chapter.snbt"])
    }
    func testApplyBacksUpAndStaleRevisionCannotTouchFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let instance = home.appendingPathComponent("instance"), file = instance.appendingPathComponent("config/ftbquests/quests/start.snbt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: home) }
        let original = Data("{id:'ABC' title:'Start' rewards:[{xp:25}]}".utf8); try original.write(to: file)
        var doc = try LocalizationDocument.read(original, path: "start.snbt", kind: .ftbQuest); doc.rows[0].translation = "开始"
        let project = LocalizationProject(name: "Pack", sources: [.init(name: "FTB", installPath: "config/ftbquests/quests", kind: "ftbquests", documents: [doc])])
        let result = try LocalizationApply.apply(project, instance: instance, backupHome: home)
        XCTAssertEqual(result.files, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.backup).path))
        let translated = try Data(contentsOf: file)
        XCTAssertTrue(String(decoding: translated, as: UTF8.self).contains("开始")); XCTAssertTrue(String(decoding: translated, as: UTF8.self).contains("xp:25"))
        XCTAssertThrowsError(try LocalizationApply.apply(project, instance: instance, backupHome: home))
        XCTAssertEqual(try Data(contentsOf: file), translated)
    }
    func testExistingChineseFTBLocaleIsPreservedAndUnsafeTargetsAreRejected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let folder = home.appendingPathComponent("instance/config/ftbquests/quests/lang")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: home) }
        let english = Data("{key:'Welcome'}".utf8), chinese = Data("{key:'自定义中文' extra:'保留'}".utf8)
        try english.write(to: folder.appendingPathComponent("en_us.snbt")); try chinese.write(to: folder.appendingPathComponent("zh_cn.snbt"))
        var doc = try LocalizationDocument.read(english, path: "lang/en_us.snbt", kind: .ftbLocale); doc.rows[0].translation = "欢迎"
        let source = LocalizationSource(name: "FTB", installPath: "config/ftbquests/quests", kind: "ftbquests", documents: [doc])
        XCTAssertThrowsError(try LocalizationApply.apply(.init(name: "Pack", sources: [source]), instance: home.appendingPathComponent("instance"), backupHome: home))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("zh_cn.snbt")), chinese)
        let unsafe = LocalizationSource(name: "Bad", installPath: "../outside", kind: "ftbquests", documents: [doc])
        XCTAssertThrowsError(try LocalizationApply.apply(.init(name: "Pack", sources: [unsafe]), instance: home.appendingPathComponent("instance"), backupHome: home))
    }
}
