import SwiftUI
import UIKit
import AVFoundation
import HarborCore
import UniformTypeIdentifiers

struct HarborWallpapersView: View {
    @ObservedObject private var state = HarborWallpaperState.shared
    @State private var importing = false
    @State private var rename: HarborWallpaper?
    @State private var name = ""
    @State private var deleting: HarborWallpaper?
    var body: some View {
        List {
            Section {
                Button { Task { await state.select(nil) } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.fill.on.rectangle.fill").font(.title2)
                        Text("使用默认背景").foregroundStyle(.primary)
                        Spacer()
                        if state.snapshot.selected == nil { Image(systemName: "checkmark.circle.fill") }
                    }.frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("wallpapers.default")
                    .accessibilityValue(state.snapshot.selected == nil ? "已选中" : "未选择")
                if state.busy { HStack(spacing: 12) { ProgressView(); Text("正在读取、生成预览并保存壁纸…").font(.footnote) }.frame(minHeight: 44) }
                if let error = state.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                Text("从 Files 导入图片或视频，原件保留。点壁纸可放大预览、命名和使用；动态壁纸右下角有视频标识。游戏中、切后台或启用独家优化时暂停动态播放，壁纸保持静音。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("我的壁纸 · \(state.snapshot.items.count)") {
                ForEach(state.snapshot.items.sorted { $0.added > $1.added }) { item in
                    NavigationLink { HarborWallpaperDetail(item: item) } label: {
                        HStack(spacing: 16) {
                            HarborWallpaperThumbnail(item: item).frame(width: 88, height: 62).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.name).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                Text(item.video ? "动态壁纸" : "静态壁纸").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if state.snapshot.selected == item.id { Image(systemName: "checkmark.circle.fill") }
                        }.frame(maxWidth: .infinity, minHeight: 72).padding(.vertical, 8).contentShape(Rectangle())
                    }.accessibilityIdentifier("wallpapers.item." + item.id.uuidString)
                        .accessibilityValue(state.snapshot.selected == item.id ? "使用中" : "未选择")
                        .contextMenu {
                            Button("使用此壁纸") { Task { await state.select(item.id) } }
                            Button("重命名") { name = item.name; rename = item }
                            Button("移除", role: .destructive) { deleting = item }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { deleting = item } label: { Label("移除", systemImage: "trash") }
                            Button { name = item.name; rename = item } label: { Label("命名", systemImage: "pencil") }.tint(.accentColor)
                        }
                }
                if state.snapshot.items.isEmpty { Text("导入壁纸后会在这里显示预览。").foregroundStyle(.secondary).padding(.vertical, 18) }
            }
        }.harborPageBackground().navigationTitle("壁纸库").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Button { importing = true } label: { Label("导入壁纸", systemImage: "plus").frame(minHeight: 44).contentShape(Rectangle()) }
                        .harborGlassButton(prominent: true).accessibilityLabel("导入壁纸").accessibilityIdentifier("wallpapers.import").disabled(state.busy)
                }.padding(.horizontal, 18).padding(.vertical, 8)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie]) { result in
                switch result { case .success(let url): state.importFile(url); case .failure(let error): state.error = error.localizedDescription }
            }
            .alert("壁纸名称", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("名称", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存") { if let item = rename { Task { await state.rename(item.id, name: name) } }; rename = nil }
                Button("取消", role: .cancel) { rename = nil }
            }
            .confirmationDialog("从壁纸库移除？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("移除壁纸", role: .destructive) { if let item = deleting { Task { await state.remove(item.id) } }; deleting = nil }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { Text("只移除启动器中的副本，导入时的原始文件不受影响。") }
    }
}

private struct HarborWallpaperThumbnail: View {
    let item: HarborWallpaper
    @ObservedObject private var state = HarborWallpaperState.shared
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(.quaternary)
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary) }
                if item.video { Image(systemName: "video.fill").font(.caption.bold()).foregroundStyle(.white).padding(6).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7)).padding(5) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.task(id: item.id) { image = await state.thumbnail(item) }
    }
}

private struct HarborWallpaperDetail: View {
    let item: HarborWallpaper
    @ObservedObject private var state = HarborWallpaperState.shared
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var playing = false
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let player, playing {
                    HarborWallpaperVideo(player: player).aspectRatio(image.map { $0.size.width / max(1, $0.size.height) } ?? 16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 24))
                }
                else if let image { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 24)) }
                else { Image(systemName: "photo").font(.largeTitle).frame(maxWidth: .infinity, minHeight: 220).foregroundStyle(.secondary) }
                Text(item.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Label(item.video ? "动态壁纸 · 使用后静音循环播放" : "静态壁纸", systemImage: item.video ? "video" : "photo").foregroundStyle(.secondary)
                if item.video {
                    Button(playing ? "暂停视频预览" : "播放视频预览") {
                        playing.toggle(); state.setPreviewing(playing)
                        if playing { player?.play() } else { player?.pause() }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).disabled(player == nil || exclusive)
                    if exclusive { Text("独家优化已开启，动态壁纸使用静态预览。").font(.footnote).foregroundStyle(.secondary) }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                if let error = state.error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button { Task { await state.select(item.id) } } label: {
                    Text(state.snapshot.selected == item.id ? "正在使用" : "使用此壁纸").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }.harborGlassButton(prominent: true).disabled(state.busy)
            }.padding(20).frame(maxWidth: 760)
        }.harborPageBackground().navigationTitle("壁纸预览").navigationBarTitleDisplayMode(.inline)
            .task(id: item.id) {
                guard let library = state.library else { return }
                do {
                    if item.video {
                        image = await state.thumbnail(item)
                        let url = try await library.media(item); try Task.checkCancellation()
                        let queue = AVQueuePlayer(); queue.isMuted = true; queue.allowsExternalPlayback = false
                        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url)); player = queue
                    }
                    else {
                        let url = try await library.media(item)
                        let data = try await Task.detached(priority: .utility) { try HarborWallpaperMedia.png(HarborWallpaperMedia.image(url, maximum: 2560)) }.value
                        image = HarborWallpaperState.previewImage(data)
                    }
                } catch { failure = error.localizedDescription }
            }
            .onChange(of: phase) { if $0 != .active { stopPreview() } }
            .onChange(of: exclusive) { if $0 { stopPreview() } }
            .onDisappear { stopPreview(); looper?.disableLooping(); looper = nil; player?.removeAllItems(); player = nil }
    }
    private func stopPreview() { player?.pause(); playing = false; state.setPreviewing(false) }
}
