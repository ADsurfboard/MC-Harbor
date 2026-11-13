import SwiftUI
import UniformTypeIdentifiers
import HarborCore

struct TouchLayoutEditor: View {
    let home: URL
    let profile: String?
    @Environment(\.dismiss) private var dismiss
    @State private var layout = TouchLayout.standard()
    @State private var selected: UUID?
    @State private var error: String?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = TouchLayoutDocument(data: Data())
    private var file: URL { HarborRootFactory.controlConfigurationURL(home: home, profile: profile) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TouchLayoutCanvas(layout: $layout, selected: $selected).aspectRatio(2, contentMode: .fit)
                    Text("拖动按键和摇杆调整位置；下方可精确设置。实际游戏会按屏幕安全区自动适配。").font(.footnote).foregroundStyle(.secondary)
                    TextField("布局名称", text: $layout.name)
                    Button { layout.mirrorHorizontally() } label: { Label("左右手镜像", systemImage: "arrow.left.and.right").frame(minHeight: 44) }
                } header: { Text(profile == nil ? "默认布局" : "此实例的布局") }
                Section("摇杆") {
                    slider("尺寸", value: $layout.settings.joystickDiameter, range: 88...240, unit: "pt")
                    slider("死区", value: $layout.settings.joystickDeadZone, range: 0.04...0.5)
                    slider("横向位置", value: $layout.settings.joystickCenter.x, range: 0...1)
                    slider("纵向位置", value: $layout.settings.joystickCenter.y, range: 0...1)
                    Toggle("浮动摇杆", isOn: $layout.settings.floatingJoystick)
                    Toggle("推到底自动疾跑", isOn: $layout.settings.autoSprint)
                }
                Section("视角与反馈") {
                    slider("视角灵敏度", value: $layout.settings.cameraSensitivity, range: 0.1...4)
                    Toggle("反转横向视角", isOn: $layout.settings.invertCameraX)
                    Toggle("反转纵向视角", isOn: $layout.settings.invertCameraY)
                    Toggle("陀螺仪辅助", isOn: $layout.settings.gyroEnabled)
                    if layout.settings.gyroEnabled { slider("陀螺仪灵敏度", value: $layout.settings.gyroSensitivity, range: 0.05...3) }
                    Toggle("触觉反馈", isOn: $layout.settings.haptics)
                    Toggle("快捷栏触控", isOn: $layout.settings.hotbarVisible)
                }
                Section("按键") {
                    ForEach(layout.buttons) { button in
                        Button { selected = button.id } label: {
                            HStack { Text(button.displayName); Spacer(); Text(button.visible ? "显示" : "隐藏").foregroundStyle(.secondary); if selected == button.id { Image(systemName: "checkmark.circle.fill") } }
                                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }
                    }
                    Menu {
                        ForEach(ControlAction.allCases, id: \.self) { action in
                            Button(action.chineseName) {
                                guard layout.buttons.count < 96 else { error = "最多可添加 96 个按键。"; return }
                                let button = TouchButton(action: action, x: 0.5, y: 0.5)
                                layout.buttons.append(button); selected = button.id
                            }
                        }
                    } label: { Label("添加按键", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                }
                if let index = layout.buttons.firstIndex(where: { $0.id == selected }) {
                    Section(layout.buttons[index].displayName) {
                        TextField("自定义名称", text: Binding(get: { layout.buttons[index].customLabel ?? "" }, set: { layout.buttons[index].customLabel = $0.isEmpty ? nil : $0 }))
                        Picker("键盘映射", selection: $layout.buttons[index].customKey) {
                            Text("使用默认动作").tag(Optional<Int>.none)
                            ForEach(65...90, id: \.self) { key in Text(String(UnicodeScalar(key)!)).tag(Optional(key)) }
                            ForEach(290...301, id: \.self) { key in Text("F\(key-289)").tag(Optional(key)) }
                            Text("空格").tag(Optional(32)); Text("Tab").tag(Optional(258)); Text("Shift").tag(Optional(340))
                            Text("Ctrl").tag(Optional(341)); Text("Alt").tag(Optional(342))
                        }
                        Toggle("显示按键", isOn: $layout.buttons[index].visible)
                            .disabled(layout.buttons[index].action == .pause)
                        Toggle("点按切换保持状态", isOn: $layout.buttons[index].toggle)
                        slider("按键大小", value: $layout.buttons[index].diameter, range: 44...160, unit: "pt")
                        slider("按键不透明度", value: $layout.buttons[index].opacity, range: 0.1...1)
                        slider("横向位置", value: $layout.buttons[index].center.x, range: 0...1)
                        slider("纵向位置", value: $layout.buttons[index].center.y, range: 0...1)
                        if layout.buttons[index].action != .pause {
                            Button("移除此按键", role: .destructive) { layout.buttons.remove(at: index); selected = nil }.frame(minHeight: 44)
                        }
                    }
                }
                Section("布局文件") {
                    Button { importing = true } label: { Label("导入布局", systemImage: "square.and.arrow.down").frame(minHeight: 44) }
                    Button { do { exportDocument = .init(data: try JSONEncoder().encode(layout)); exporting = true } catch { self.error = error.localizedDescription } } label: { Label("导出布局", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                    Button("恢复经典布局", role: .destructive) { layout = .standard(); selected = nil }.frame(minHeight: 44)
                }
            }
            .navigationTitle("触控与摇杆").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.accessibilityIdentifier("touch.save") }
            }
            .onAppear(perform: load)
            .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 128 * 1024 else { throw TouchLayoutError.tooLarge }
                    layout = try TouchLayout.decode(Data(contentsOf: url)); selected = nil
                } catch { self.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "MC-Harbor-Touch-Layout") { result in if case .failure(let error) = result { self.error = error.localizedDescription } }
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title); Spacer(); Text(unit.isEmpty ? String(format: "%.2f", value.wrappedValue) : "\(Int(value.wrappedValue)) \(unit)").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range).accessibilityLabel(title)
        }.padding(.vertical, 5)
    }
    private func shortName(_ action: ControlAction) -> String {
        switch action { case .attack: "挖掘"; case .use: "使用"; case .swapHands: "副手"; case .perspective: "视角"; case .playerList: "玩家"; default: String(action.chineseName.prefix(3)) }
    }
    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 128 * 1024 else { throw TouchLayoutError.tooLarge }
            layout = try TouchLayout.decode(Data(contentsOf: file))
        } catch { self.error = "布局文件未被覆盖：" + error.localizedDescription }
    }
    private func save() {
        do {
            try layout.sanitize()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(layout).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            dismiss()
        } catch { self.error = "保存失败，原配置保留：" + error.localizedDescription }
    }
}

struct TouchLayoutDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
