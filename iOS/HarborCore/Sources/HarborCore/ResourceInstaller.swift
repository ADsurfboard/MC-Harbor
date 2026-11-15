import Foundation
import CryptoKit
import Darwin

public typealias ResourceDownload = @Sendable (URL, URL, Int64) async throws -> Void

/// NSURLSession writes to disk, caps response bytes while receiving, and never
/// follows a mirror redirect to an unrelated host or an insecure URL.
private final class ResourceDownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let target: URL
    private let size: Int64
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var completion: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var failure: Error?
    private var produced = false
    private var redirects = 0
    init(target: URL, size: Int64) { self.target = target; self.size = size }
    func start(_ url: URL, completion: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); completion.resume(throwing: CancellationError()); return }
        self.completion = completion
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil; config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": ResourceNetwork.userAgent]
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session; task = session.downloadTask(with: url)
        let transfer = task; lock.unlock(); transfer?.resume()
    }
    func cancel() { lock.lock(); cancelled = true; let transfer = task; lock.unlock(); transfer?.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 4, let url = request.url, ResourceNetwork.fileURLAllowed(url) else {
            failure = ResourceError.invalid("下载来源重定向到不受支持的地址。"); completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > size || totalBytesExpectedToWrite > size {
            failure = ResourceError.invalid("下载文件超过声明大小。"); downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw ResourceError.http((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0) }
            guard Int64(try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == size else { throw ResourceError.invalid("下载文件不完整。") }
            try FileManager.default.moveItem(at: location, to: target); produced = true
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let completion = completion; self.completion = nil
        let wasCancelled = cancelled; self.task = nil; self.session = nil; lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { completion?.resume(throwing: error) }
        else if !produced { completion?.resume(throwing: ResourceError.invalid("下载没有生成文件。")) }
        else { completion?.resume() }
    }
}

public enum ResourceFiles {
    public static func download(_ url: URL, to target: URL, size: Int64) async throws {
        guard ResourceNetwork.fileURLAllowed(url) else { throw ResourceError.invalid("下载地址无效。") }
        let transfer = ResourceDownloadTask(target: target, size: size)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(url, completion: $0) }
        } onCancel: { transfer.cancel() }
    }
    public static func verify(_ url: URL, file: ResourceFile) throws -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ResourceError.invalid("无法安全打开下载文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == file.size,
              let expected = ResourceFileValidation.digest(file) else { return false }
        var sha512 = SHA512(), sha1 = Insecure.SHA1(), md5 = Insecure.MD5()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            switch expected.name { case "sha512": sha512.update(data: data); case "sha1": sha1.update(data: data); default: md5.update(data: data) }
        }
        let hash: [UInt8]
        switch expected.name { case "sha512": hash = Array(sha512.finalize()); case "sha1": hash = Array(sha1.finalize()); default: hash = Array(md5.finalize()) }
        return hash.map { String(format: "%02x", $0) }.joined() == expected.value.lowercased()
    }
}

/// All downloads are verified before any file enters an instance. Existing
/// conflicting files are preserved. A failed multi-file commit rolls back only
/// the files that this transaction moved, never pre-existing user content.
public actor ResourceInstaller {
    private let home: URL
    private var busy = false
    public init(home: URL) { self.home = home.standardizedFileURL.resolvingSymlinksInPath() }
    private func safe(_ url: URL) throws {
        let url = url.standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix(home.path + "/"), url.path == url.resolvingSymlinksInPath().path else { throw ResourceError.invalid("资源目标不在实例存储范围内，或包含符号链接。") }
    }
    public func install(_ files: [ResourceFile], kind: ResourceKind, destination: URL, route: ResourceRoute,
                        download: @escaping ResourceDownload = ResourceFiles.download,
                        progress: @escaping @Sendable (Int, Int, String) async -> Void = { _, _, _ in }) async throws -> Int {
        guard !busy else { throw ResourceError.invalid("已有资源正在安装。") }
        guard !files.isEmpty, files.count <= 40, destination.lastPathComponent == kind.directory else { throw ResourceError.invalid("下载计划或目标目录无效。") }
        try safe(destination)
        var names: Set<String> = []
        for file in files {
            try ResourceFileValidation.validate(file, kind: kind)
            guard names.insert(file.name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ResourceError.invalid("下载计划包含同名文件。") }
        }
        busy = true; defer { busy = false }
        let fm = FileManager.default
        let root = home.appendingPathComponent("harbor-resource-downloads", isDirectory: true)
        try safe(root); try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let needed = files.reduce(Int64(0)) { $0 + $1.size }
        let available = try stage.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard Int64(available) > needed + 128 * 1024 * 1024 else { throw ResourceError.invalid("空间不足，请至少保留下载大小以外的 128 MB 空间。") }
        await progress(0, files.count, "下载与校验")
        try await withThrowingTaskGroup(of: String.self) { group in
            var next = 0, finished = 0
            func enqueue(_ file: ResourceFile) {
                let target = stage.appendingPathComponent(file.name)
                group.addTask {
                    let transferFiles = FileManager()
                    var last: Error = ResourceError.unavailable("所有下载来源均暂不可用。")
                    for url in ResourceNetwork.candidates(file.url, route: route) {
                        try Task.checkCancellation()
                        do {
                            try await download(url, target, file.size)
                            try Task.checkCancellation()
                            guard try ResourceFiles.verify(target, file: file) else { throw ResourceError.invalid("\(file.name) 校验失败。") }
                            return file.name
                        } catch {
                            last = error; try? transferFiles.removeItem(at: target); try Task.checkCancellation()
                        }
                    }
                    throw last
                }
            }
            while next < min(3, files.count) { enqueue(files[next]); next += 1 }
            while let name = try await group.next() {
                finished += 1; await progress(finished, files.count, name)
                if next < files.count { enqueue(files[next]); next += 1 }
            }
        }
        try Task.checkCancellation(); try safe(destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = try fm.contentsOfDirectory(atPath: destination.path)
        var install: [ResourceFile] = []
        for file in files {
            if let alias = existing.first(where: { $0.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(file.name.precomposedStringWithCanonicalMapping) == .orderedSame }) {
                guard try ResourceFiles.verify(destination.appendingPathComponent(alias), file: file) else { throw ResourceError.invalid("已存在不同内容的 \(alias)。为保护已有模组，本次没有覆盖任何文件。") }
            } else { install.append(file) }
        }
        var moved: [URL] = []
        do {
            for file in install {
                try Task.checkCancellation(); try safe(destination)
                let target = destination.appendingPathComponent(file.name)
                try fm.moveItem(at: stage.appendingPathComponent(file.name), to: target); moved.append(target)
            }
            // No await in the commit section: actor re-entry cannot change its
            // state between preflight, the moves, and rollback bookkeeping.
            return moved.count
        } catch {
            for url in moved.reversed() { try? fm.removeItem(at: url) }
            throw error
        }
    }
}
