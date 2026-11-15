import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum HarborWallpaperMedia {
    public static func image(_ url: URL, maximum: Int) throws -> CGImage {
        guard url.isFileURL, (1...4096).contains(maximum) else { throw ResourceError.invalid("壁纸图片地址或预览尺寸无效。") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 50 * 1024 * 1024 else { throw ResourceError.invalid("图片不是有效本地文件或超过 50 MB。") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 100_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximum,
                  kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ResourceError.invalid("图片无法解码或像素过大，请选择有效图片。") }
        return image
    }
    public static func png(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0, image.width <= 4096, image.height <= 4096 else { throw ResourceError.invalid("壁纸预览尺寸超过安全上限。") }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw ResourceError.invalid("无法生成壁纸预览。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ResourceError.invalid("壁纸预览生成失败。") }; return bytes as Data
    }
    public static func prepare(_ url: URL) async throws -> WallpaperPreparedMedia {
        let ext = url.pathExtension.lowercased(), video = ["mp4", "mov", "m4v"].contains(ext)
        guard ["jpg", "jpeg", "png", "heic", "heif", "webp", "mp4", "mov", "m4v"].contains(ext) else { throw ResourceError.invalid("支持 JPG、PNG、HEIC、WebP、MP4、MOV 和 M4V。") }
        guard url.isFileURL else { throw ResourceError.invalid("壁纸只接受本地 Files 文件。") }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, let size = properties.fileSize, size > 0,
              size <= (video ? 512 : 50) * 1024 * 1024 else { throw ResourceError.invalid("壁纸不是有效本地文件或超过大小上限。") }
        let thumbnail: CGImage
        if video {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else { throw ResourceError.invalid("视频没有有效画面或时长。") }
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 960, height: 960)
            defer { generator.cancelAllCGImageGeneration() }
            thumbnail = try await generator.image(at: .zero).image
        } else { thumbnail = try image(url, maximum: 960) }
        try Task.checkCancellation()
        return .init(original: url, thumbnail: try png(thumbnail), fileExtension: ext, video: video)
    }
}
