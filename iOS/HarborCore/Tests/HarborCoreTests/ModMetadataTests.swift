import XCTest
@testable import HarborCore

final class ModMetadataTests: XCTestCase {
    func testFabricKeepsDeclaredConstraintsAndRejectsUnsafeIcon() throws {
        let data = Data(#"{"id":"mod","name":"Example","version":"1.2","icon":"../outside.png","depends":{"minecraft":[">=1.20","<1.22"]}}"#.utf8)
        let value = try ModArchiveMetadata.read(entries: ["fabric.mod.json": data], filename: "example.jar")
        XCTAssertEqual(value.name, "Example"); XCTAssertEqual(value.version, "1.2")
        XCTAssertEqual(value.gameVersions, [">=1.20", "<1.22"]); XCTAssertNil(value.iconPath)
    }
    func testLegacyAndNeoForge() throws {
        let legacy = try ModArchiveMetadata.read(entries: ["mcmod.info": Data(#"{"modList":[{"name":"Old","mcversion":"1.12.2","authorList":["A","B"]}]}"#.utf8)], filename: "old.jar")
        XCTAssertEqual(legacy.name, "Old"); XCTAssertEqual(legacy.authors, "A、B")
        let neo = try ModArchiveMetadata.read(entries: ["META-INF/neoforge.mods.toml": Data("[[mods]]\nmodId='example'\ndisplayName='Neo'\nversion='2.0'".utf8)], filename: "new.jar")
        XCTAssertEqual(neo.loaders, ["NeoForge"]); XCTAssertEqual(neo.name, "Neo"); XCTAssertEqual(neo.version, "2.0")
    }
    func testMalformedAndMissingFieldsDoNotInventMetadata() throws {
        XCTAssertThrowsError(try ModArchiveMetadata.read(entries: ["fabric.mod.json": Data("not json".utf8)], filename: "bad.jar"))
        XCTAssertThrowsError(try ModArchiveMetadata.read(entries: ["fabric.mod.json": Data("[]".utf8)], filename: "bad.jar"))
        let value = try ModArchiveMetadata.read(entries: [:], filename: "unknown.jar")
        XCTAssertEqual(value.name, "unknown"); XCTAssertTrue(value.loaders.isEmpty); XCTAssertNil(value.version)
    }
}
