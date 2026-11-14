import Foundation

/// Standalone host runner for the production actor, independent of SwiftPM's
/// manifest toolchain. JAR-shaped byte fixtures test storage, not Minecraft.
@main struct FolderChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("HarborFolderChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw ModFolderError.invalid("CHECK FAILED: " + message) }
            count += 1
        }
        func fixture(_ name: String, _ content: String, _ directory: URL) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try (Data([0x50, 0x4b, 0x03, 0x04]) + Data(content.utf8)).write(to: url)
            return url
        }
        let a = try fixture("a.jar", "a", root), b = try fixture("b.jar", "b", root)
        let original = try Data(contentsOf: a)
        let library = try ModFolderLibrary(root: root.appendingPathComponent("library"))
        let first = try await library.create(name: "  常用模组  ")
        let second = try await library.create(name: "PVP", color: "#ddeeff")
        let number = try await library.importFiles([.init(file: a), .init(file: b), .init(file: a)], to: first)
        try check(number == 2, "deduplicate copied content")
        var state = await library.snapshot()
        try check(state.folders[0].name == "常用模组", "trim names")
        let ids = state.folders[0].mods.map(\.id)
        try await library.transfer(.init(library: state.identity, folder: first, mods: [ids[0]]), to: second, copy: true)
        state = await library.snapshot()
        try check(state.folders[0].mods.count == 2 && state.folders[1].mods.count == 1, "copy to another folder")
        try await library.transfer(.init(library: state.identity, folder: first, mods: [ids[0]]), to: second)
        state = await library.snapshot()
        try check(state.folders[0].mods.count == 1 && state.folders[1].mods.count == 1, "move and target deduplication")
        var rejected = false
        do { try await library.transfer(.init(library: UUID(), folder: first, mods: [ids[1]]), to: second) }
        catch { rejected = true }
        try check(rejected, "foreign drag rejected")
        let old = state.folders
        rejected = false
        do { try await library.update(first, name: "bad", color: "../../private") } catch { rejected = true }
        state = await library.snapshot()
        try check(rejected && state.folders == old, "failed metadata edit preserves state")
        let reloaded = try ModFolderLibrary(root: root.appendingPathComponent("library"))
        let disk = await reloaded.snapshot()
        try check(disk.folders == state.folders && disk.identity == state.identity, "atomic persistence")
        let third = try await library.create(name: "all or nothing")
        rejected = false
        do { _ = try await library.importFiles([.init(file: a), .init(file: root.appendingPathComponent("missing.jar"))], to: third) }
        catch { rejected = true }
        state = await library.snapshot()
        try check(rejected && state.folders.last!.mods.isEmpty, "batch import rollback")
        let link = root.appendingPathComponent("link.jar")
        try fm.createSymbolicLink(at: link, withDestinationURL: a)
        rejected = false
        do { _ = try await library.importFiles([.init(file: link)], to: third) } catch { rejected = true }
        try check(rejected, "symlink rejected")
        try check(try Data(contentsOf: a) == original, "source unchanged")
        _ = try await library.importFiles([.init(file: a), .init(file: b)], to: third)
        state = await library.snapshot()
        let destination = root.appendingPathComponent("instance/mods")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let conflict = try fixture("B.JAR", "existing player file", destination)
        let conflictBytes = try Data(contentsOf: conflict)
        rejected = false
        do { _ = try await library.install(Set(ids), from: third, to: destination) } catch { rejected = true }
        try check(rejected, "case-alias conflict rejected")
        try check(try Data(contentsOf: conflict) == conflictBytes, "existing mod preserved")
        try check(!fm.fileExists(atPath: destination.appendingPathComponent("a.jar").path), "no partial instance install")
        try fm.removeItem(at: conflict)
        let installed = try await library.install(Set(ids), from: third, to: destination)
        try check(installed == 2, "install selected copies")
        let duplicate = try await library.install(Set(ids), from: third, to: destination)
        try check(duplicate == 0, "skip exact installed copies")
        try await library.transfer(.init(library: state.identity, folder: third, mods: [ids[0]]), to: third, at: 2)
        state = await library.snapshot()
        try check(state.folders.last!.mods.map(\.filename) == ["b.jar", "a.jar"], "drag reordering")
        let fabric = try ModArchiveMetadata.read(entries: ["fabric.mod.json": Data(#"{"schemaVersion":1,"id":"example","name":"测试模组","version":"2.0","description":"简介","authors":[{"name":"作者"}],"depends":{"minecraft":[">=1.20","<1.22"]},"icon":{"32":"small.png","256":"assets/icon.png"}}"#.utf8)], filename: "fabric.jar")
        try check(fabric.name == "测试模组" && fabric.version == "2.0", "real Fabric metadata fields")
        try check(fabric.loaders == ["Fabric"] && fabric.gameVersions == [">=1.20", "<1.22"], "keep declared version constraints")
        try check(fabric.iconPath == "assets/icon.png" && fabric.authors == "作者", "icon size and author object")
        let quilt = try ModArchiveMetadata.read(entries: ["quilt.mod.json": Data(#"{"quilt_loader":{"id":"q","version":"3.1","metadata":{"name":"Quilt Example","contributors":{"Alice":"Owner"}},"depends":[{"id":"minecraft","versions":">=1.21"}]}}"#.utf8)], filename: "q.jar")
        try check(quilt.loaders == ["Quilt"] && quilt.name == "Quilt Example" && quilt.authors == "Alice", "Quilt metadata")
        let toml = "[[mods]] # primary\nmodId='test'\ndisplayName=\"A \\\"quoted\\\" mod\"\nversion=\"$" + "{file.jarVersion}\"\ndescription='''\nOne\nTwo\n'''\n[[mods]]\ndisplayName='Second'"
        let forge = try ModArchiveMetadata.read(entries: ["META-INF/mods.toml": Data(toml.utf8), "META-INF/MANIFEST.MF": Data("Implementation-Version: 4.5\r\n".utf8)], filename: "test.jar")
        try check(forge.name == "A \"quoted\" mod" && forge.version == "4.5", "TOML escaped quotes and real manifest version")
        try check(forge.summary == "One\nTwo" && forge.loaders == ["Forge"], "multiline TOML primary record")
        let legacy = try ModArchiveMetadata.read(entries: ["mcmod.info": Data(#"[{"name":"Legacy","version":"1","mcversion":"1.12.2","logoFile":"../../outside.png"}]"#.utf8)], filename: "legacy.jar")
        try check(legacy.gameVersions == ["1.12.2"] && legacy.iconPath == nil, "legacy version and icon traversal rejection")
        let unknown = try ModArchiveMetadata.read(entries: [:], filename: "original-name.jar")
        try check(unknown.name == "original-name" && unknown.version == nil && unknown.loaders.isEmpty, "unknown metadata never fabricated")
        rejected = false
        do { _ = try ModArchiveMetadata.read(entries: ["fabric.mod.json": Data("[1,2]".utf8)], filename: "bad.jar") } catch { rejected = true }
        try check(rejected, "invalid known metadata produces readable error")
        rejected = false
        do { _ = try ModArchiveMetadata.read(entries: ["fabric.mod.json": Data(repeating: 32, count: 1024 * 1024 + 1)], filename: "big.jar") } catch { rejected = true }
        try check(rejected, "oversize metadata rejected before parsing")
        print("PASS \(count) production mod-folder storage checks")
    }
}
