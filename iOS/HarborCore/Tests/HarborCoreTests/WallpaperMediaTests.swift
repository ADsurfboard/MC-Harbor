import XCTest
import CoreGraphics
import ImageIO
import AVFoundation
import CoreVideo
@testable import HarborCore

@MainActor final class WallpaperMediaTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func testActualPNGDecoderProducesBoundedPreview() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let original = try HarborWallpaperMedia.png(XCTUnwrap(context.makeImage())), file = root.appendingPathComponent("image.png")
        try original.write(to: file)
        let small = try HarborWallpaperMedia.image(file, maximum: 16)
        XCTAssertEqual(small.width, 16); XCTAssertEqual(small.height, 8)
        XCTAssertThrowsError(try HarborWallpaperMedia.image(file, maximum: 0))
        XCTAssertThrowsError(try HarborWallpaperMedia.image(file, maximum: 20_000))
        let prepared = try await HarborWallpaperMedia.prepare(file)
        XCTAssertFalse(prepared.video); XCTAssertEqual(prepared.fileExtension, "png"); XCTAssertTrue(!prepared.thumbnail.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testCorruptImagesAndUnsupportedFormatsThrowInsteadOfCrashing() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("broken.png"); try Data("not a PNG".utf8).write(to: file)
        XCTAssertThrowsError(try HarborWallpaperMedia.image(file, maximum: 960))
        do { _ = try await HarborWallpaperMedia.prepare(file); XCTFail("corrupt PNG accepted") } catch { }
        let unsupported = root.appendingPathComponent("script.html"); try Data("<script/>".utf8).write(to: unsupported)
        do { _ = try await HarborWallpaperMedia.prepare(unsupported); XCTFail("unsupported file accepted") } catch { }
        do { _ = try await HarborWallpaperMedia.prepare(URL(string: "https://example.invalid/image.png")!); XCTFail("remote wallpaper accepted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: unsupported.path))
    }
    func testBrokenVideoCannotBecomePreparedMedia() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("broken.mp4"); try Data(repeating: 0, count: 64).write(to: file)
        do { _ = try await HarborWallpaperMedia.prepare(file); XCTFail("broken video accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: file).count, 64)
    }
    func testRealVideoGeneratesStaticPosterWithoutPlayingAudio() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tiny.mov")
        try await Self.writeTinyVideo(file)
        let prepared = try await HarborWallpaperMedia.prepare(file)
        XCTAssertTrue(prepared.video); XCTAssertEqual(prepared.fileExtension, "mov")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.thumbnail as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue(image.width > 0 && image.width <= 960); XCTAssertTrue(image.height > 0 && image.height <= 960)
    }
    nonisolated private static func writeTinyVideo(_ file: URL) async throws {
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        guard writer.canAdd(input) else { throw ResourceError.invalid("测试视频编码器不可用。") }; writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ResourceError.invalid("测试视频无法写入。") }; writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess, let buffer else { throw ResourceError.invalid("测试像素缓冲区无法创建。") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(buffer) { memset(bytes, 127, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<2 {
            var attempts = 0
            while !input.isReadyForMoreMediaData {
                attempts += 1
                guard attempts < 100, writer.status == .writing else { throw writer.error ?? ResourceError.invalid("测试视频编码超时。") }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)) else { throw writer.error ?? ResourceError.invalid("测试视频帧无法写入。") }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ResourceError.invalid("测试视频未完整写入。") }
    }
}
