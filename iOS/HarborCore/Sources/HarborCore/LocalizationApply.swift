import Foundation

public struct LocalizationApplyResult: Sendable {
    public let files: Int
    public let backup: URL?
}

public enum LocalizationApply {
    /// The caller must hold the native instance mutation token. All source
    /// revisions are checked before backup and again before each atomic write.
    public static func apply(_ project: LocalizationProject, instance: URL, backupHome: URL) throws -> LocalizationApplyResult {
        let root = instance.standardizedFileURL.resolvingSymlinksInPath()
        struct Patch { let source: URL; let expected: String; let target: URL; let relative: String; let data: Data; let before: Data? }
        var patches: [Patch] = [], targets: Set<String> = [], total = 0
        func safe(_ relative: String) throws -> URL {
            try LocalizationDocument.validatePath(relative)
            let path = root.appendingPathComponent(relative).standardizedFileURL
            guard path.path.hasPrefix(root.path + "/"), path.path == path.resolvingSymlinksInPath().path else { throw ResourceError.invalid("任务 / 数据包包含符号链接或越界路径。") }
            return path
        }
        func read(_ url: URL) throws -> Data? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw ResourceError.invalid("任务文件不是普通文件或超过 4 MB。") }
            return try Data(contentsOf: url)
        }
        for source in project.sources where source.selected && source.kind != "mods" && source.kind != "resourcepacks" && source.kind != "languages" {
            for doc in source.documents where doc.kind != .languageJSON && doc.kind != .languageLegacy {
                var rendered = try doc.rendered()
                guard rendered != doc.original else { continue }
                let sourceRelative = source.installPath + "/" + doc.path
                let relative = doc.kind == .ftbLocale ? sourceRelative.replacingOccurrences(of: #"(?i)(^|/)en_(?:us|gb)(?=/|\.)"#, with: "$1zh_cn", options: .regularExpression) : sourceRelative
                let originalURL = try safe(sourceRelative), target = try safe(relative)
                guard let original = try read(originalURL), LocalizationDocument.digest(original) == doc.revision else { throw ResourceError.invalid("任务 / 数据包原文已变化，请重新读取后应用：" + sourceRelative) }
                let before = try read(target)
                if doc.kind == .ftbLocale, let scanned = source.originalFiles[doc.path.replacingOccurrences(of: #"(?i)(^|/)en_(?:us|gb)(?=/|\.)"#, with: "$1zh_cn", options: .regularExpression)], scanned != before {
                    throw ResourceError.invalid("已有中文任务文件在读取后发生变化，请重新读取再合并：" + relative)
                }
                if doc.kind == .ftbLocale, let before { rendered = try doc.mergingLocale(into: before) }
                guard rendered != before else { continue }
                guard targets.insert(relative.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ResourceError.invalid("所选任务译文目标重复。") }
                total += rendered.count + (before?.count ?? 0)
                guard total <= 48 * 1024 * 1024 else { throw ResourceError.invalid("任务应用文本超过 48 MB，请分批选择。") }
                patches.append(.init(source: originalURL, expected: doc.revision, target: target, relative: relative, data: rendered, before: before))
            }
        }
        guard !patches.isEmpty else { return .init(files: 0, backup: nil) }
        let home = backupHome.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("harbor-localization-backups")
        guard home.path == home.resolvingSymlinksInPath().path else { throw ResourceError.invalid("汉化备份目录包含符号链接。") }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let backup = home.appendingPathComponent(UUID().uuidString + ".zip")
        var entries = patches.compactMap { patch in patch.before.map { LocalizationExportEntry(path: patch.relative, data: $0) } }
        let manifest: [String: Any] = ["kind": "MC Harbor localization backup", "createdFiles": patches.filter { $0.before == nil }.map(\.relative),
                                       "restore": "Restore the original files from this ZIP; remove only files listed in createdFiles."]
        entries.append(.init(path: "MC-Harbor-backup.json", data: try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])))
        try LocalizationZIP.write(entries, to: backup)
        var committed: [Patch] = []
        do {
            for patch in patches {
                try Task.checkCancellation()
                _ = try safe(patch.relative)
                guard let current = try read(patch.source), LocalizationDocument.digest(current) == patch.expected,
                      try read(patch.target) == patch.before else { throw ResourceError.invalid("应用过程中原文件发生变化，已停止并恢复本次改动。") }
                try FileManager.default.createDirectory(at: patch.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try patch.data.write(to: patch.target, options: .atomic); committed.append(patch)
            }
            return .init(files: committed.count, backup: backup)
        } catch {
            var recovery: [String] = []
            for patch in committed.reversed() {
                do {
                    _ = try safe(patch.relative)
                    // Do not erase a file edited by another actor after commit.
                    guard try read(patch.target) == patch.data else { recovery.append(patch.relative); continue }
                    if let before = patch.before { try before.write(to: patch.target, options: .atomic) }
                    else { try FileManager.default.removeItem(at: patch.target) }
                } catch { recovery.append(patch.relative) }
            }
            if !recovery.isEmpty { throw ResourceError.invalid("部分文件需要从备份手动恢复：" + recovery.joined(separator: "、") + "；备份：" + backup.lastPathComponent) }
            throw error
        }
    }
}
