import Foundation
import HarborCore

/// Non-UI bridge, deliberately usable on the native installer's worker queue.
@objc(HarborArchiveSafety) public final class HarborArchiveSafety: NSObject {
    private struct Entry: Decodable {
        let path: String
        let compressedBytes: UInt64
        let expandedBytes: UInt64
        let symbolicLink: Bool
    }
    @objc(validateEntriesJSON:availableBytes:error:)
    public static func validateEntriesJSON(_ data: Data, availableBytes: UInt64) throws {
        guard data.count <= 32 * 1024 * 1024 else { throw ArchiveSafetyError.tooManyEntries }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        do {
            try ArchiveSafety.validate(entries.map { ArchiveEntry(path: $0.path, compressedBytes: $0.compressedBytes, expandedBytes: $0.expandedBytes, symbolicLink: $0.symbolicLink) }, availableBytes: availableBytes)
        } catch {
            throw NSError(domain: "net.morben.harbor.archive", code: 1, userInfo: [NSLocalizedDescriptionKey: "整合包未通过安全检查。请检查文件路径、重复文件、解压大小和可用空间。原有实例未被覆盖。", NSUnderlyingErrorKey: error])
        }
    }
}
