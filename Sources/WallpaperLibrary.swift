import AppKit
import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct LibraryWallpaper:Codable,Identifiable,Equatable,Sendable {
    let id:String
    var name:String
    let path:String
    let kind:WallpaperKind
    let owned:Bool
}

@MainActor final class WallpaperLibrary:ObservableObject {
    @Published var items:[LibraryWallpaper]=[]
    @Published var busy=false
    @Published var error:String?
    static var directory:URL{NativePaths.root.appendingPathComponent("wallpapers",isDirectory:true)}
    init(current:WallpaperSettings){
        items=(try? JSONDecoder().decode([LibraryWallpaper].self,from:Data(contentsOf:Self.directory.appendingPathComponent("catalog.json")))) ?? []
        if current.kind != .harbor,let path=current.filePath,!items.contains(where:{$0.path==path}) {
            items.insert(LibraryWallpaper(id:UUID().uuidString,name:URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent,path:path,kind:current.kind,owned:false),at:0)
            do{try save()}catch{self.error=error.localizedDescription}
        }
    }
    func save()throws{try FileManager.default.createDirectory(at:Self.directory,withIntermediateDirectories:true);try JSONEncoder().encode(items).write(to:Self.directory.appendingPathComponent("catalog.json"),options:.atomic)}
    func rename(_ item:LibraryWallpaper,to name:String){let name=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty,name.count<=100,let index=items.firstIndex(where:{$0.id==item.id}) else{return};let old=items;items[index].name=name;do{try save()}catch{items=old;self.error=error.localizedDescription}}
    func remove(_ item:LibraryWallpaper){let old=items;items.removeAll{$0.id==item.id};do{try save();let url=URL(fileURLWithPath:item.path).standardizedFileURL;if item.owned,url.deletingLastPathComponent()==Self.directory.standardizedFileURL{try? FileManager.default.removeItem(at:url)}}catch{items=old;self.error=error.localizedDescription}}
    func choose(){
        guard !busy else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.image,.movie];panel.allowsMultipleSelection=true;panel.prompt="导入壁纸"
        guard panel.runModal() == .OK else{return};let urls=panel.urls;busy=true;error=nil
        Task{defer{busy=false};var failures:[String]=[]
            for url in urls {do{let item=try await Self.copy(url);items.insert(item,at:0);do{try save()}catch{items.removeAll{$0.id==item.id};try? FileManager.default.removeItem(atPath:item.path);throw error}}catch{failures.append(url.lastPathComponent+"："+error.localizedDescription)}}
            if !failures.isEmpty{error=failures.joined(separator:"\n")}
        }
    }
    nonisolated static func copy(_ source:URL)async throws->LibraryWallpaper {
        let values=try source.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.contentTypeKey]);guard values.isRegularFile==true,let size=values.fileSize,size>0,size<=4_000_000_000 else{throw FileTransactions.error("文件无效或超过 4 GB。")}
        let kind:WallpaperKind
        if values.contentType?.conforms(to:.movie)==true {guard !(try await AVURLAsset(url:source).loadTracks(withMediaType:.video)).isEmpty else{throw FileTransactions.error("视频中没有画面。")};kind = .video}
        else {guard size<=100_000_000,let image=CGImageSourceCreateWithURL(source as CFURL,nil),CGImageSourceGetCount(image)>0 else{throw FileTransactions.error("无法读取这张图片。")};kind = .image}
        let folder=NativePaths.root.appendingPathComponent("wallpapers",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let available=(try? folder.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        guard available>Int64(size)+100_000_000 else{throw FileTransactions.error("磁盘空间不足，请先释放空间。")}
        let id=UUID().uuidString,target=folder.appendingPathComponent(id+"."+source.pathExtension.lowercased()),staging=folder.appendingPathComponent(id+".partial")
        do{try await Task.detached(priority:.userInitiated){try FileManager.default.copyItem(at:source,to:staging)}.value;try Task.checkCancellation();try FileManager.default.moveItem(at:staging,to:target)}catch{try? FileManager.default.removeItem(at:staging);throw error}
        return LibraryWallpaper(id:id,name:source.deletingPathExtension().lastPathComponent,path:target.path,kind:kind,owned:true)
    }
}

/// Limit simultaneous video generators when a lot of cards appear at once.
private actor WallpaperDecoder {
    static let shared = WallpaperDecoder()
    private var active = 0

    func bitmap(_ item: LibraryWallpaper, pixels: Int) async -> HarborDecodedBitmap? {
        while active >= 2 {
            do { try await HarborDelay.sleep(seconds: 0.04) }
            catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        active += 1
        defer { active -= 1 }
        let url = URL(fileURLWithPath: item.path)
        if item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels, height: pixels)
            let image: CGImage?
            if #available(macOS 13.0, *) {
                image = try? await generator.image(at: .zero).image
            } else {
                image = try? generator.copyCGImage(at: .zero, actualTime: nil)
            }
            guard !Task.isCancelled, let image else { return nil }
            return HarborDecodedBitmap(image: image)
        }
        return HarborImageCache.decodeThumbnail(item.path, pixels: pixels)
    }
}

enum WallpaperThumbnails {
    static func image(_ item: LibraryWallpaper, pixels: Int = 640) async -> HarborDecodedBitmap? {
        await WallpaperDecoder.shared.bitmap(item, pixels: pixels)
    }

    @MainActor static func presentation(_ item: LibraryWallpaper, pixels: Int) async -> NSImage? {
        if let cached = HarborImageCache.cachedThumbnail(item.path, pixels: pixels) { return cached }
        guard let bitmap = await image(item, pixels: pixels), !Task.isCancelled else { return nil }
        return HarborImageCache.cacheThumbnail(bitmap, path: item.path, pixels: pixels)
    }
}

private struct WallpaperThumbnail: View {
    let item: LibraryWallpaper
    @State private var image: NSImage?

    var body: some View {
        // The grid proposes the width. The artwork cannot negotiate a wider
        // cell when its aspect ratio exceeds the allocated tile.
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.06)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .padding(7)
                }
            }
        }
        .frame(height: 102)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: item.path) {
            let result = await WallpaperThumbnails.presentation(item, pixels: 384)
            if !Task.isCancelled { image = result }
        }
        .onDisappear { image = nil }
    }
}

struct WallpaperLibraryPanel: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var library: WallpaperLibrary
    @State private var selected: String?
    @State private var name = ""
    @State private var preview: NSImage?
    @State private var player: AVPlayer?
    @State private var removing = false

    init(model: LauncherModel) {
        self.model = model
        _library = StateObject(wrappedValue: WallpaperLibrary(current: model.preferences.wallpaper))
    }

    private var current: LibraryWallpaper? { library.items.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Text("壁纸库").font(.system(size: 27, weight: .semibold))
                Spacer()
                if library.busy { HarborActivityIndicator().controlSize(.small) }
                Button("导入图片或视频…") { library.choose() }
                    .buttonStyle(HarborButtonStyle()).disabled(library.busy)
                Button { model.modal = nil } label: { HarborSymbol(systemName: "xmark") }
                    .buttonStyle(HarborButtonStyle())
                    .accessibilityLabel("关闭壁纸库")
            }
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 20) {
                    catalog
                    Divider().opacity(0.30)
                    detail.frame(width: min(320, max(230, geometry.size.width * 0.34)))
                }
            }
            if let error = library.error {
                Text(error).font(.system(size: 12)).harborSecondaryText().textSelection(.enabled).lineLimit(3)
            }
        }
        .padding(25)
        .onAppear { select(library.items.first { $0.path == model.preferences.wallpaper.filePath } ?? library.items.first) }
        .onDisappear { stopPreview() }
        .task(id: selected) {
            guard let current, current.kind == .image else { return }
            let result = await WallpaperThumbnails.presentation(current, pixels: 1120)
            if !Task.isCancelled && selected == current.id { preview = result }
        }
        .harborOnChange(of: phase) { _, value in
            if value == .active { player?.play() } else { player?.pause() }
        }
        .harborOnChange(of: library.items.count) { _, _ in
            if current == nil { select(library.items.first) }
        }
        .alert("从壁纸库移除？", isPresented: $removing) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) { removeSelection() }
        } message: { Text("导入的副本将被移除，原始文件保留。") }
    }

    private var catalog: some View {
        ScrollView {
            if library.items.isEmpty {
                HarborEmptyView("壁纸库为空", systemImage: "photo.on.rectangle")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: 12)], spacing: 12) {
                    ForEach(library.items) { item in card(item) }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func card(_ item: LibraryWallpaper) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        let applied = model.preferences.wallpaper.filePath == item.path
        return Button { select(item) } label: {
            VStack(alignment: .leading, spacing: 8) {
                WallpaperThumbnail(item: item)
                HStack(spacing: 5) {
                    Text(item.name).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    Spacer(minLength: 0)
                    if applied { Image(systemName: "checkmark.circle.fill").foregroundStyle(model.controlTint) }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 3)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == item.id ? model.themeColor.opacity(0.18) : Color.primary.opacity(0.035), in: shape)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(HarborPressButtonStyle(pressedScale: 0.98, pressedOffset: 0))
        .help(item.name)
    }

    private var detail: some View {
        ScrollView {
            if let item = current {
                VStack(alignment: .leading, spacing: 16) {
                    GeometryReader { geometry in
                        ZStack {
                            Color.primary.opacity(0.04)
                            if let player { WallpaperVideoPreview(player: player) }
                            else if let preview { Image(nsImage: preview).resizable().scaledToFit() }
                            else { HarborSymbol(systemName: "photo") }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    HStack {
                        TextField("壁纸名称", text: $name).textFieldStyle(.roundedBorder)
                            .onSubmit { library.rename(item, to: name) }
                        Button("保存") { library.rename(item, to: name) }
                            .buttonStyle(HarborButtonStyle())
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(item.kind == .video ? "动态壁纸 · 无声播放" : "静态壁纸")
                        .font(.system(size: 12)).harborSecondaryText()
                    HStack {
                        Button("使用壁纸") {
                            model.preferences.wallpaper.kind = item.kind
                            model.preferences.wallpaper.filePath = item.path
                            model.toast("壁纸已切换")
                        }
                        .buttonStyle(HarborButtonStyle(prominent: true))
                        Button("移除") { removing = true }.buttonStyle(HarborButtonStyle())
                    }
                }
            } else {
                HarborEmptyView("选择壁纸", systemImage: "photo.on.rectangle",
                                description: Text("导入后可命名、预览和切换。"))
            }
        }.harborHideScrollIndicators()
    }

    private func select(_ item: LibraryWallpaper?) {
        if selected == item?.id && (item?.kind != .video || player != nil) { return }
        stopPreview()
        selected = item?.id
        name = item?.name ?? ""
        guard let item, item.kind == .video else { return }
        let player = AVPlayer(url: URL(fileURLWithPath: item.path))
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        if phase == .active { player.play() }
    }

    private func stopPreview() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        preview = nil
    }

    private func removeSelection() {
        guard let item = current else { return }
        library.remove(item)
        guard !library.items.contains(where: { $0.id == item.id }) else { return }
        if model.preferences.wallpaper.filePath == item.path {
            model.preferences.wallpaper.kind = .harbor
            model.preferences.wallpaper.filePath = nil
        }
        select(library.items.first)
    }
}
