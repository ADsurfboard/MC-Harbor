import SwiftUI
import ImageIO

/// Decode only the pixels needed on a phone rather than keeping desktop-sized
/// loader artwork in memory. Original assets remain unchanged in the repository.
@MainActor enum HarborArtwork {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ name: String, pixels: Int = 192) -> UIImage? {
        let key = "\(name)-\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let bundle = Bundle(for: HarborRootFactory.self)
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: bitmap)
        cache.totalCostLimit = 4 * 1024 * 1024
        cache.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.height)
        return image
    }
    static func loaderName(_ loader: String) -> String {
        switch loader.lowercased() {
        case "neoforge": "neoforge"
        case "forge": "forge"
        case "fabric": "fabric"
        case "quilt": "quilt"
        case "legacyfabric": "legacyfabric"
        case "cleanroom": "cleanroom"
        default: "grass"
        }
    }
}

struct HarborLoaderArtwork: View {
    let loader: String
    var body: some View {
        Group {
            if let image = HarborArtwork.image(HarborArtwork.loaderName(loader)) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
            } else { Image(systemName: "cube.fill").resizable().scaledToFit().foregroundStyle(.tint) }
        }.accessibilityHidden(true)
    }
}

struct HarborBrandArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
            if let image = HarborArtwork.image(colorScheme == .dark ? "Mark" : "Mark-dark", pixels: 128) {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }.accessibilityHidden(true)
    }
}
