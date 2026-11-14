import SwiftUI
import ImageIO
import HarborCore

extension Color {
    static func folderHex(_ value: String) -> Color {
        let hex = UInt64(value.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
private final class FolderBitmap: @unchecked Sendable {
    let image: CGImage
    let colors: FolderColorPair?
    init(image: CGImage) { self.image = image; colors = FolderColorPair.analyze(image) }
}
private actor FolderImageCache {
    static let shared = FolderImageCache()
    private let cache = NSCache<NSString, FolderBitmap>()
    init() { cache.totalCostLimit = 16 * 1024 * 1024; cache.countLimit = 96 }
    func image(_ requested: URL?) -> FolderBitmap? {
        let fallback = Bundle(for: HarborRootFactory.self).url(forResource: "FolderLandscape", withExtension: "png")
        guard let url = requested ?? fallback else { return nil }
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            if requested != nil { return self.image(nil) }
            return nil
        }
        let bitmap = FolderBitmap(image: image)
        cache.setObject(bitmap, forKey: key, cost: image.bytesPerRow * image.height)
        return bitmap
    }
}

/// The source icon stays fixed; only its two dominant colours flow underneath.
/// Alpha-aware sampling ignores RGB hidden in transparent PNG pixels.
struct HarborFolderArtwork: View {
    let url: URL?
    @State private var bitmap: FolderBitmap?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.08)
                if let bitmap {
                    if let colors = bitmap.colors { FolderFlowBackdrop(colors: colors) }
                    Image(decorative: bitmap.image, scale: 1).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit).padding(4)
                        .mask {
                            Rectangle().fill(LinearGradient(stops: [
                                .init(color: .clear, location: 0), .init(color: .white, location: 0.08),
                                .init(color: .white, location: 0.92), .init(color: .clear, location: 1)
                            ], startPoint: .leading, endPoint: .trailing))
                            .mask(LinearGradient(stops: [
                                .init(color: .clear, location: 0), .init(color: .white, location: 0.07),
                                .init(color: .white, location: 0.93), .init(color: .clear, location: 1)
                            ], startPoint: .top, endPoint: .bottom))
                        }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.task(id: url) { bitmap = await FolderImageCache.shared.image(url) }
            .accessibilityHidden(true)
    }
}

private struct HarborFolderBack: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path(); p.move(to: .init(x: 14, y: 0)); p.addLine(to: .init(x: w * 0.36, y: 0))
        p.addCurve(to: .init(x: w * 0.56, y: 12), control1: .init(x: w * 0.44, y: 0), control2: .init(x: w * 0.47, y: 12))
        p.addLine(to: .init(x: w - 14, y: 12)); p.addQuadCurve(to: .init(x: w, y: 26), control: .init(x: w, y: 12))
        p.addLine(to: .init(x: w, y: h - 14)); p.addQuadCurve(to: .init(x: w - 14, y: h), control: .init(x: w, y: h))
        p.addLine(to: .init(x: 14, y: h)); p.addQuadCurve(to: .init(x: 0, y: h - 14), control: .init(x: 0, y: h))
        p.addLine(to: .init(x: 0, y: 14)); p.addQuadCurve(to: .init(x: 14, y: 0), control: .zero); p.closeSubpath(); return p
    }
}
private struct HarborFolderPocket: Shape {
    var opening: CGFloat
    var animatableData: CGFloat { get { opening } set { opening = newValue } }
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, inset: CGFloat = 0.8 + opening * 3.2, lip: CGFloat = 12 + opening * 5
        var p = Path(); p.move(to: .init(x: 14 + inset, y: 0)); p.addLine(to: .init(x: w * 0.36, y: 0))
        p.addCurve(to: .init(x: w * 0.56, y: lip), control1: .init(x: w * 0.44, y: 0), control2: .init(x: w * 0.47, y: lip))
        p.addLine(to: .init(x: w - 14 - inset, y: lip)); p.addQuadCurve(to: .init(x: w - inset, y: lip + 14), control: .init(x: w - inset, y: lip))
        p.addLine(to: .init(x: w, y: h - 14)); p.addQuadCurve(to: .init(x: w - 14, y: h), control: .init(x: w, y: h))
        p.addLine(to: .init(x: 14, y: h)); p.addQuadCurve(to: .init(x: 0, y: h - 14), control: .init(x: 0, y: h))
        p.addLine(to: .init(x: inset, y: 14)); p.addQuadCurve(to: .init(x: 14 + inset, y: 0), control: .init(x: inset, y: 0)); p.closeSubpath(); return p
    }
}

struct HarborFolderCard: View {
    let folder: ModFolder
    @ObservedObject var model: HarborFolderLibrary
    let action: () -> Void
    @GestureState private var pressing = false
    @State private var hovering = false
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    private var open: Bool { (pressing || hovering) && !exclusive && !reduceMotion }
    private var tint: Color { folder.color == "none" ? .clear : .folderHex(folder.color) }
    private var dark: Bool { scheme == .dark }
    private var documents: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(folder.mods.prefix(3).enumerated()), id: \.element.id) { index, mod in
                HarborFolderArtwork(url: model.imageURL(mod)).frame(width: 154, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .rotationEffect(.degrees(open ? Double(index - 1) * 11 : Double(index - 1) * 3))
                    .offset(x: open ? CGFloat(index - 1) * 35 : CGFloat(index - 1) * 6,
                            y: open ? -48 - abs(CGFloat(index - 1)) * 6 : -23 - CGFloat(index) * 7)
            }
        }.frame(width: 238, height: 203, alignment: .bottom)
    }
    private var pocket: some View {
        let shape = HarborFolderPocket(opening: open ? 1 : 0)
        return ZStack(alignment: .bottom) {
            shape.fill(.ultraThinMaterial).opacity(dark ? 0.48 : 0.56)
            documents.compositingGroup().blur(radius: 14).opacity(0.45)
            shape.fill(tint.opacity(dark ? 0.15 : 0.13))
            shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0.34), .white.opacity(0.035), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }.frame(width: 210, height: 112).clipShape(shape)
            // A thin mouth glint; there is no dark bar or perimeter outline.
            .overlay(shape.trim(from: 0, to: 0.32).stroke(LinearGradient(colors: [.white.opacity(0.58), .white.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), style: StrokeStyle(lineWidth: 0.7, lineCap: .round)))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(folder.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text("\(folder.mods.count) 个模组").font(.caption).foregroundStyle(.secondary)
                }.padding(16).padding(.trailing, 10).frame(maxWidth: .infinity, alignment: .leading)
            }.scaleEffect(x: 1, y: open ? 0.955 : 1, anchor: .bottom).offset(y: open ? 3 : 0)
    }
    var body: some View {
        Button(action: action) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    HarborFolderBack().fill(.ultraThinMaterial).opacity(0.35)
                        .overlay(HarborFolderBack().fill(tint.opacity(0.075)))
                        .frame(width: 200, height: 141).offset(y: -9)
                    documents
                    pocket
                }.frame(width: 238, height: 203).scaleEffect(min(1, geometry.size.width / 238))
                    .position(x: geometry.size.width / 2, y: 108)
            }.frame(height: 216).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressing) { _, state, _ in state = true })
            .onHover { hovering = $0 }
            .animation(exclusive || reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.8), value: open)
            .accessibilityLabel("\(folder.name)，\(folder.mods.count) 个模组")
            .accessibilityHint("打开前景列表。长按可管理名称、颜色或删除模组夹。")
    }
}
