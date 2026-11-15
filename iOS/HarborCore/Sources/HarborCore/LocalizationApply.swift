import Foundation
import Darwin

public struct LocalizationApplyResult: Sendable {
    public let files: Int
    public let backup: URL?
}

public enum LocalizationApply {
    /// The caller must hold the native instance mutation token. All source
    /// revisions are checked before backup and again before each atomic write.
    public static func apply(_ project: LocalizationProject, instance: URL, backupHome: URL) throws -> LocalizationApplyResult {
        let root = instance.standardizedFileURL.resolvingSymlinksInPath()
        struct Patch { let source: URL; let expected: String; let target: URL; let relative: String; let data: Data; let before: Data?; var limit: Int = 4 * 1024 * 1024 }
        var patches: [Patch] = [], targets: Set<String> = [], total = 0
        func safe(_ relative: String) throws -> URL {
            try LocalizationDocument.validatePath(relative)
            let path = root.appendingPathComponent(relative).standardizedFileURL
            guard path.path.hasPrefix(root.path + "/"), path.path == path.resolvingSymlinksInPath().path else { throw ResourceError.invalid("任务 / 数据包包含符号链接或越界路径。") }
            return path
        }
        func read(_ url: URL, limit: Int = 4 * 1024 * 1024) throws -> Data? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard url.path == url.resolvingSymlinksInPath().path else { throw ResourceError.invalid("任务 / 数据包路径包含链接。") }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ResourceError.invalid("无法读取任务 / 数据包文件。") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else { throw ResourceError.invalid("任务 / 数据包不是普通文件或超过读取上限。") }
            var result = Data()
            while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
                guard result.count <= limit - bytes.count else { throw ResourceError.invalid("读取过程中任务 / 数据包超过上限。") }; result.append(bytes)
            }
            guard result.count == info.st_size else { throw ResourceError.invalid("读取过程中任务 / 数据包发生变化。") }
            return result
        }
        func replace(_ data: Data, at target: URL, attributes: [FileAttributeKey: Any]) throws {
            try data.write(to: target, options: .atomic)
            var preserved: [FileAttributeKey: Any] = [.posixPermissions: attributes[.posixPermissions] ?? 0o600]
            #if os(iOS)
            if let protection = attributes[.protectionKey] { preserved[.protectionKey] = protection }
            #endif
            try FileManager.default.setAttributes(preserved, ofItemAtPath: target.path)
            let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }; try handle.synchronize()
        }
        for source in project.sources where source.selected && source.kind != "mods" && source.kind != "resourcepacks" && source.kind != "languages" {
            if source.kind == "datapack-zip" {
                guard source.documents.contains(where: { $0.rows.contains(where: { !$0.translation.isEmpty }) }) else { continue }
                let file = try safe(source.installPath)
                guard let expected = source.archiveRevision, let original = try read(file, limit: LocalizationDatapackZIP.archiveLimit), LocalizationDocument.digest(original) == expected else { throw ResourceError.invalid("ZIP 数据包已变化，请重新读取后应用：" + source.installPath) }
                let rendered = try LocalizationDatapackZIP.rendered(source)
                guard targets.insert(source.installPath.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ResourceError.invalid("数据包译文目标重复。") }
                total += original.count + rendered.count
                guard total <= 64 * 1024 * 1024 else { throw ResourceError.invalid("任务与 ZIP 数据包应用超过 64 MB，请分批选择。") }
                patches.append(.init(source: file, expected: expected, target: file, relative: source.installPath, data: rendered, before: original, limit: LocalizationDatapackZIP.archiveLimit))
                continue
            }
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
                guard total <= 64 * 1024 * 1024 else { throw ResourceError.invalid("任务 / 数据包应用超过 64 MB，请分批选择。") }
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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        var committed: [Patch] = []
        var attributesByPath: [String: [FileAttributeKey: Any]] = [:]
        do {
            for patch in patches {
                try Task.checkCancellation()
                _ = try safe(patch.relative)
                guard let current = try read(patch.source, limit: patch.limit), LocalizationDocument.digest(current) == patch.expected,
                      try read(patch.target, limit: patch.limit) == patch.before else { throw ResourceError.invalid("应用过程中原文件发生变化，已停止并恢复本次改动。") }
                try FileManager.default.createDirectory(at: patch.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Track the replacement before attribute/fsync operations so
                // a failure after rename is included in recovery.
                let attributes = try? FileManager.default.attributesOfItem(atPath: patch.target.path)
                attributesByPath[patch.relative] = attributes ?? [:]
                committed.append(patch); try replace(patch.data, at: patch.target, attributes: attributes ?? [:])
                guard try read(patch.target, limit: patch.limit) == patch.data else { throw ResourceError.invalid("任务 / 数据包写入后校验失败。") }
            }
            return .init(files: committed.count, backup: backup)
        } catch {
            var recovery: [String] = []
            for patch in committed.reversed() {
                do {
                    _ = try safe(patch.relative)
                    // Do not erase a file edited by another actor after commit.
                    let current = try read(patch.target, limit: patch.limit)
                    if current == patch.before { continue }
                    guard current == patch.data else { recovery.append(patch.relative); continue }
                    if let before = patch.before { try replace(before, at: patch.target, attributes: attributesByPath[patch.relative] ?? [:]) }
                    else { try FileManager.default.removeItem(at: patch.target) }
                } catch { recovery.append(patch.relative) }
            }
            if !recovery.isEmpty { throw ResourceError.invalid("部分文件需要从备份手动恢复：" + recovery.joined(separator: "、") + "；备份：" + backup.lastPathComponent) }
            throw error
        }
    }
}
