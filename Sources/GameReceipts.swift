import Darwin
import Foundation

enum HarborGameReceipts {
    struct Receipt: Decodable {
        let id: String
        let runDirectory: String
        let pid: Int32
        let started: UInt64
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func controls(for games: [GameInstance], in data: URL) -> [String: URL] {
        let directory = data.appendingPathComponent("launch-control", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        let paths = Dictionary(games.map {
            ($0.id, canonicalPath($0.runDirectory))
        }, uniquingKeysWith: { first, _ in first })
        var controls: [String: URL] = [:]
        for file in entries where file.pathExtension == "running" {
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let count = values.fileSize, count < 16_384,
                  let data = try? Data(contentsOf: file),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                  paths[receipt.id] == canonicalPath(receipt.runDirectory), isRunning(receipt) else { continue }
            controls[receipt.id] = file.deletingPathExtension().appendingPathExtension("stop")
        }
        return controls
    }

    static func isRunning(_ receipt: Receipt) -> Bool {
        guard receipt.pid > 1, receipt.started > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(receipt.pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != SZOMB else { return false }
        let started = info.pbi_start_tvsec * 1000 + info.pbi_start_tvusec / 1000
        return started == receipt.started
    }
}
