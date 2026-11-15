import Foundation
import HarborCore

/// Owned by the disposable UI host only; never bundled into the native game app.
enum WorldFixture {
    static func prepare(home: URL) throws {
        let folder = home.appendingPathComponent("world-fixture/saves/World QA")
        let file = folder.appendingPathComponent("level.dat")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        func be(_ number: UInt64, _ size: Int) -> Data { Data(stride(from: (size - 1) * 8, through: 0, by: -8).map { UInt8(truncatingIfNeeded: number >> $0) }) }
        func string(_ text: String) -> Data { be(UInt64(text.utf8.count), 2) + Data(text.utf8) }
        func tag(_ type: UInt8, _ name: String, _ bytes: Data) -> Data { Data([type]) + string(name) + bytes }
        func integer(_ name: String, _ value: UInt64) -> Data { tag(3, name, be(value, 4)) }
        func float(_ name: String, _ value: Float) -> Data { tag(5, name, be(UInt64(value.bitPattern), 4)) }
        var player = float("Health", 20) + integer("foodLevel", 20) + float("foodSaturationLevel", 5)
        player += integer("XpLevel", 0) + float("XpP", 0) + integer("XpTotal", 0) + integer("playerGameType", 0)
        player.append(0)
        var data = tag(8, "LevelName", string("QA World")) + integer("GameType", 0)
        data += tag(1, "Difficulty", Data([2])) + tag(1, "hardcore", Data([0])) + tag(1, "allowCommands", Data([0]))
        data += tag(4, "DayTime", be(48000, 8)) + tag(4, "Time", be(96000, 8))
        data += tag(10, "Version", tag(8, "Name", string("1.20.1")) + Data([0]))
        data += tag(10, "Player", player); data.append(0)
        let root = tag(10, "", tag(10, "Data", data) + Data([0]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WorldNBTCodec.deflate(root, compression: .gzip).write(to: file, options: .withoutOverwriting)
    }
}
