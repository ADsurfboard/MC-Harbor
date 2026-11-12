import Foundation

public struct ArchiveEntry: Sendable {
    public let path: String
    public let compressedBytes: UInt64
    public let expandedBytes: UInt64
    public let symbolicLink: Bool
    public init(path: String, compressedBytes: UInt64, expandedBytes: UInt64, symbolicLink: Bool = false) {
        self.path = path; self.compressedBytes = compressedBytes; self.expandedBytes = expandedBytes; self.symbolicLink = symbolicLink
    }
}
public enum ArchiveSafetyError: Error, Equatable {
    case invalidPath(String), symbolicLink(String), duplicatePath(String), tooManyEntries, archiveTooLarge, unreasonableExpansion(String)
}

public enum ArchiveSafety {
    public static func validate(_ entries: [ArchiveEntry], availableBytes: UInt64) throws {
        guard entries.count <= 100_000 else { throw ArchiveSafetyError.tooManyEntries }
        var paths: Set<String> = []; var expanded: UInt64 = 0
        let limit = min(availableBytes > 512 * 1024 * 1024 ? availableBytes - 512 * 1024 * 1024 : 0, 32 * 1024 * 1024 * 1024)
        for entry in entries {
            let name = entry.path.precomposedStringWithCanonicalMapping
            let pieces = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  !pieces.contains(".."), !pieces.contains("."), !pieces.dropLast().contains("") else { throw ArchiveSafetyError.invalidPath(entry.path) }
            guard !entry.symbolicLink else { throw ArchiveSafetyError.symbolicLink(entry.path) }
            // iOS storage is usually case insensitive; case/Unicode aliases must not overwrite each other.
            let canonical = name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            guard paths.insert(canonical).inserted else { throw ArchiveSafetyError.duplicatePath(entry.path) }
            guard entry.expandedBytes <= limit, expanded <= limit - entry.expandedBytes else { throw ArchiveSafetyError.archiveTooLarge }
            expanded += entry.expandedBytes
            if entry.expandedBytes > 64 * 1024 * 1024 && (entry.compressedBytes == 0 || entry.expandedBytes / max(1, entry.compressedBytes) > 1000) {
                throw ArchiveSafetyError.unreasonableExpansion(entry.path)
            }
        }
    }
}
