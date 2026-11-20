import SwiftUI
import UIKit
import WebKit
import UniformTypeIdentifiers
import HarborCore

struct HarborSkinLibraryView: View {
    @State private var query = ""
    @State private var request = Search(term: "", page: 1)
    @State private var results: [LittleSkinEntry] = []
    @State private var hasNextPage = false
    @State private var loading = true
    @State private var failure: String?
    private let catalog = LittleSkinCatalog()

    private struct Search: Equatable {
        var term: String
        var page: Int
        var id = UUID()
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("搜索皮肤名称或作者", text: $query)
                        .textInputAutocapitalization(.never).onSubmit(search)
                        .frame(minHeight: 44).accessibilityIdentifier("skins.search")
                    Button(action: search) {
                        Image(systemName: "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.borderless).accessibilityLabel("搜索")
                }
            }
            if loading { ProgressView("正在读取皮肤").frame(minHeight: 44) }
            if let failure {
                Text(failure).foregroundStyle(.secondary)
                Button("重试") { request.id = UUID() }.frame(minHeight: 44)
            } else if !loading && results.isEmpty {
                Text("没有匹配的皮肤。").foregroundStyle(.secondary)
            }
            ForEach(results) { entry in
                NavigationLink {
                    HarborSkinDetails(entry: entry, catalog: catalog)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.name).font(.headline)
                        Text(entry.author + (entry.highResolution ? " · 高清" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 48)
                }
            }
            HStack {
                Button("上一页") { request = Search(term: request.term, page: request.page - 1) }
                    .disabled(loading || request.page <= 1)
                Spacer()
                Text("第 \(request.page) 页").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("下一页") { request = Search(term: request.term, page: request.page + 1) }
                    .disabled(loading || !hasNextPage)
            }.buttonStyle(.borderless).frame(minHeight: 44)
        }
        .harborPageBackground().navigationTitle("LittleSkin 皮肤库").navigationBarTitleDisplayMode(.inline)
        .task(id: request) {
            let search = request
            loading = true; failure = nil; results = []
            defer { if request == search { loading = false } }
            do {
                let page = try await catalog.search(search.term, page: search.page)
                guard !Task.isCancelled, request == search else { return }
                results = page.items; hasNextPage = page.hasNextPage
            } catch {
                if !Task.isCancelled, request == search { failure = error.localizedDescription; hasNextPage = false }
            }
        }
    }

    private func search() { request = Search(term: query.trimmingCharacters(in: .whitespacesAndNewlines), page: 1) }
}

private struct HarborSkinDetails: View {
    let entry: LittleSkinEntry
    let catalog: LittleSkinCatalog
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    @State private var texture: Data?
    @State private var error: String?
    @State private var rendererError: String?
    @State private var exporting = false
    @State private var reload = UUID()

    var body: some View {
        List {
            Section {
                if let texture {
                    if rendererError == nil {
                        HarborSkinModel(texture: texture, model: entry.model,
                                        rotating: phase == .active && !reduceMotion && !exclusive,
                                        report: { rendererError = $0 })
                            .frame(height: 290).accessibilityLabel("三维皮肤预览，可拖动旋转")
                    } else if let image = UIImage(data: texture) {
                        Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                            .frame(maxWidth: .infinity).frame(height: 180)
                            .accessibilityLabel("皮肤贴图")
                    }
                } else if error == nil { ProgressView("正在读取并校验皮肤").frame(minHeight: 64) }
                LabeledContent("作者", value: entry.author)
                LabeledContent("模型", value: entry.model == "slim" ? "细手臂" : "标准")
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("重新读取") { reload = UUID() }.frame(minHeight: 44)
                }
                Link(destination: entry.projectURL) {
                    Label("在 LittleSkin 查看", systemImage: "arrow.up.right.square").frame(minHeight: 44)
                }
                Button { exporting = true } label: {
                    Label("导出 PNG", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }.disabled(texture == nil)
            }
        }
        .harborPageBackground().navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
        .task(id: reload) {
            error = nil
            do {
                let data = try await catalog.texture(entry)
                if !Task.isCancelled { texture = data }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exporting, document: texture.map { SkinPNG(data: $0) },
                      contentType: .png, defaultFilename: "LittleSkin-\(entry.id)") {
            if case .failure(let failure) = $0 { error = failure.localizedDescription }
        }
    }
}

private struct SkinPNG: FileDocument {
    static let readableContentTypes: [UTType] = [.png]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try LittleSkinCatalog.validate(data)
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor private struct HarborSkinModel: UIViewRepresentable {
    let texture: Data
    let model: String
    let rotating: Bool
    let report: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "harborSkin")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        if let file = Bundle(for: HarborRootFactory.self).url(forResource: "index", withExtension: "html", subdirectory: "SkinViewer") {
            context.coordinator.entry = file
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else {
            Task { @MainActor in report("没有找到皮肤预览组件。") }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.texture = texture; context.coordinator.model = model
        context.coordinator.rotating = rotating; context.coordinator.report = report
        context.coordinator.update(view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "harborSkin")
        view.evaluateJavaScript("window.harborDispose?.()")
        view.stopLoading(); view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var entry: URL?
        var report: (String) -> Void = { _ in }
        var texture: Data?
        var model = "default"
        var rotating = false
        private var sentTexture = false
        private var sentMotion: Bool?
        private var ready = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; update(webView)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error.localizedDescription)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            report("皮肤预览已停止。")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == entry ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let values = message.body as? [String: String], let error = values["error"] { report(error) }
        }
        func update(_ view: WKWebView) {
            guard ready else { return }
            if !sentTexture, let texture {
                let payload = ["model": model, "skin": "data:image/png;base64," + texture.base64EncodedString()]
                if let json = try? JSONSerialization.data(withJSONObject: payload) {
                    view.evaluateJavaScript("window.harborSetSkin(" + String(decoding: json, as: UTF8.self) + ")") { [weak self] _, error in
                        if let error { self?.report(error.localizedDescription) }
                    }
                    sentTexture = true
                }
            }
            if sentMotion != rotating {
                let value = rotating ? "{motion:'rotate',active:true}" : "{motion:'none',active:false}"
                view.evaluateJavaScript("window.harborSetMotion(" + value + ")")
                sentMotion = rotating
            }
        }
    }
}
