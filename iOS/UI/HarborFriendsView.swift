import SwiftUI
import UIKit
import HarborCore
import UniformTypeIdentifiers

struct HarborFriendsView: View {
    @ObservedObject var model: HarborSocialLibrary
    let instances: [PhoneInstance]
    @State private var query = ""
    @State private var nickname = ""
    @State private var code = ""
    @State private var removing: SocialPerson?
    private var friends: [SocialPerson] {
        (model.snapshot?.friends ?? []).filter { query.isEmpty || model.name($0).localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) || $0.code.localizedCaseInsensitiveContains(query) }
            .sorted { model.name($0).localizedStandardCompare(model.name($1)) == .orderedAscending }
    }
    var body: some View {
        List {
            Section {
                NavigationLink { HarborLocalPlayHistoryView(model: model) } label: {
                    Label("本机最近游戏", systemImage: "clock.arrow.circlepath").frame(minHeight: 48)
                }.accessibilityIdentifier("friends.localHistory")
            }
            if let snapshot = model.snapshot {
                Section {
                    HStack(spacing: 14) {
                        HarborFriendAvatar(model: model, person: snapshot.me)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(snapshot.me.name).font(.title3.bold())
                            Text("好友码：\(snapshot.me.code)").font(.subheadline.monospaced()).textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                        Button { UIPasteboard.general.string = snapshot.me.code } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("复制好友码")
                    }.padding(.vertical, 10)
                    NavigationLink { HarborFriendIdentitySettings(model: model) } label: {
                        Label("好友身份与共享设置", systemImage: "person.crop.circle").frame(minHeight: 44)
                    }
                }
                Section("添加好友") {
                    HStack(spacing: 12) {
                        TextField("输入对方的好友码", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .accessibilityIdentifier("friends.code")
                        Button("添加") { model.request(code) }.frame(minWidth: 44, minHeight: 44).disabled(model.busy || code.isEmpty)
                    }
                }
                if !snapshot.requests.isEmpty {
                    Section("收到的申请") { ForEach(snapshot.requests) { person in
                        VStack(alignment: .leading, spacing: 10) {
                            HarborFriendLabel(model: model, person: person)
                            HStack(spacing: 16) {
                                Button("接受") { model.respond(person, accept: true) }.frame(maxWidth: .infinity, minHeight: 44)
                                Button("拒绝", role: .destructive) { model.respond(person, accept: false) }.frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.borderless).disabled(model.busy)
                        }.padding(.vertical, 8)
                    } }
                }
                Section("好友 · \(snapshot.friends.count)") {
                    if friends.isEmpty { Text(query.isEmpty ? "还没有好友。交换好友码，由对方接受申请后即可聊天和共享动态。" : "没有匹配的好友。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16) }
                    ForEach(friends) { person in
                        NavigationLink { HarborFriendDetail(model: model, person: person, instances: instances) } label: { HarborFriendLabel(model: model, person: person) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("移除", role: .destructive) { removing = person }
                            }
                    }
                }
                if !snapshot.sent.isEmpty {
                    Section("等待对方确认") { ForEach(snapshot.sent) { HarborFriendLabel(model: model, person: $0) } }
                }
            } else {
                Section("建立好友身份") {
                    Text("与 Mac 版共用好友、聊天和游戏动态服务。每位玩家可直接创建身份，不用部署或填写服务器。好友身份与 Minecraft 游戏账号分开。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextField("你的好友昵称", text: $nickname).textContentType(.nickname).accessibilityIdentifier("friends.nickname")
                    Button("创建好友身份") { model.register(nickname) }.frame(maxWidth: .infinity, minHeight: 48).disabled(model.busy || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .harborGlassButton(prominent: true).accessibilityIdentifier("friends.register")
                    NavigationLink { HarborFriendRecovery(model: model) } label: { Text("导入已有身份的恢复密钥").frame(minHeight: 44) }
                    if model.recoverySecret != nil {
                        NavigationLink { HarborFriendIdentitySettings(model: model) } label: { Text("保存本次身份恢复密钥").frame(minHeight: 44) }
                    }
                }
            }
            Section {
                HStack(spacing: 8) {
                    if model.busy { ProgressView() }
                    else { Circle().fill(model.live ? .green : .secondary).frame(width: 7, height: 7) }
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
                Text("只有双方确认的好友可聊天。皮肤、最近游戏需主动共享；备注仅保存在本机。服务免费计划受第三方配额与网络可用性限制，不中转 Minecraft 游戏流量。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.harborPageBackground().navigationTitle("好友").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.snapshot != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("搜索昵称、备注或好友码", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .frame(minHeight: 44).accessibilityIdentifier("friends.search")
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("清空搜索")
                        }
                    }.padding(.horizontal, 14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
            }
            .refreshable { do { try await model.reload() } catch { model.error = error.localizedDescription } }
            .alert("好友服务", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
            .confirmationDialog("移除好友并收回共享访问？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("移除好友", role: .destructive) { if let person = removing { model.remove(person) }; removing = nil }
            }
    }
}

struct HarborFriendAvatar: View {
    @ObservedObject var model: HarborSocialLibrary
    let person: SocialPerson
    var body: some View {
        Group {
            if let image = model.avatars[person.id] ?? HarborSocialLibrary.defaultAvatar { Image(uiImage: image).resizable().interpolation(.none).scaledToFit() }
            else { Image(systemName: "person.crop.square.fill").resizable().scaledToFit().padding(8).foregroundStyle(.secondary) }
        }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            .task(id: person.id + person.skinHash) { await model.loadAvatar(person) }
    }
}

private struct HarborFriendLabel: View {
    @ObservedObject var model: HarborSocialLibrary
    let person: SocialPerson
    var body: some View {
        HStack(spacing: 14) {
            HarborFriendAvatar(model: model, person: person)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.name(person)).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(model.notes[person.id]?.isEmpty == false ? person.name : person.sharing ? "已共享最近游戏" : "最近游戏未共享")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.unread.contains(person.id) { Circle().fill(.blue).frame(width: 8, height: 8).accessibilityLabel("有未读消息") }
        }.padding(.vertical, 12).frame(minHeight: 80).contentShape(Rectangle())
    }
}

struct HarborFriendDetail: View {
    @ObservedObject var model: HarborSocialLibrary
    let person: SocialPerson
    let instances: [PhoneInstance]
    @State private var note = ""
    @State private var remove = false
    @State private var onlyTogether = false
    private var current: SocialPerson? { model.snapshot?.friends.first { $0.id == person.id } }
    var body: some View {
        List {
            if let current {
                Section {
                    HarborFriendLabel(model: model, person: current)
                    NavigationLink { HarborConversation(model: model, person: current, instances: instances) } label: { Label("聊天与快捷邀请", systemImage: "bubble.left.and.bubble.right").frame(minHeight: 48) }
                    TextField("好友备注", text: $note).accessibilityIdentifier("friends.note")
                    Button("保存备注") { model.setNote(note, for: current) }.frame(minHeight: 44)
                    HarborSettingsToggle("记录为一起游玩的好友", isOn: Binding(get: { model.selectedCompanions.contains(person.id) }, set: { if $0 { model.selectedCompanions.insert(person.id) } else { model.selectedCompanions.remove(person.id) } }))
                    Text("同行由你选择，不代表系统已证实你们位于同一服务器或存档。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("最近游戏") {
                    if current.sharing {
                        HarborSettingsToggle("仅显示与我一起的游戏", isOn: $onlyTogether)
                        let rows = (model.histories[person.id] ?? []).filter { !onlyTogether || $0.friends.contains(model.snapshot?.me.id ?? "") }
                        if rows.isEmpty { Text("没有可显示的游戏记录。").foregroundStyle(.secondary) }
                        ForEach(rows) { HarborPlayHistoryRow(value: $0) }
                    } else { Text("对方尚未开启最近游戏共享。").foregroundStyle(.secondary) }
                    Button("刷新游戏动态") { Task { await model.loadHistory(current) } }.frame(minHeight: 44).disabled(!current.sharing)
                }
                Section { Button("移除好友", role: .destructive) { remove = true }.frame(minHeight: 44) }
            } else { Text("你们当前不是好友。好友关系变更后，聊天、动态和皮肤访问会收回。").foregroundStyle(.secondary) }
        }.harborPageBackground().navigationTitle(model.name(person)).navigationBarTitleDisplayMode(.inline)
            .onAppear { note = model.notes[person.id] ?? "" }
            .task { if let current { await model.loadHistory(current) } }
            .confirmationDialog("移除此好友并收回共享访问？", isPresented: $remove, titleVisibility: .visible) { Button("移除好友", role: .destructive) { model.remove(person) } }
    }
}

struct HarborPlayHistoryRow: View {
    let value: SocialPlaySession
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value.instance).font(.headline).lineLimit(2)
            Text([value.version, value.loader, value.world].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text(Date(timeIntervalSince1970: value.started), style: .date)
                Spacer()
                Text(value.seconds < 60 ? "\(Int(value.seconds))秒" : "\(Int(value.seconds) / 3600)小时\(Int(value.seconds) % 3600 / 60)分钟")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 10)
    }
}

struct HarborLocalPlayHistoryView: View {
    @ObservedObject var model: HarborSocialLibrary
    @State private var companion = ""
    var body: some View {
        List {
            Section {
                Picker("筛选同行好友", selection: $companion) {
                    Text("全部游戏").tag("")
                    Text("和好友一起").tag("together")
                    ForEach(model.snapshot?.friends ?? []) { Text(model.name($0)).tag($0.id) }
                }
                Text("记录来自实际游戏界面的启动与退出，时长按前台会话计时；后台不累加。每30秒保存，强退按最后保存点恢复。没有读到的存档名称会留空，不推测正在玩的世界。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("最近游戏") {
                let rows = model.localHistory.filter { companion.isEmpty || (companion == "together" ? !$0.friends.isEmpty : $0.friends.contains(companion)) }
                if rows.isEmpty { Text("还没有匹配的本机游戏记录。").foregroundStyle(.secondary).padding(.vertical, 16) }
                ForEach(rows) { HarborPlayHistoryRow(value: $0) }
            }
        }.harborPageBackground().navigationTitle("本机最近游戏").navigationBarTitleDisplayMode(.inline)
    }
}

struct HarborFriendRecovery: View {
    @ObservedObject var model: HarborSocialLibrary
    @State private var secret = ""
    var body: some View {
        Form {
            Section("恢复已有好友身份") {
                SecureField("恢复密钥", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("验证并恢复身份") { model.restore(secret); secret = "" }.frame(maxWidth: .infinity, minHeight: 48).disabled(model.busy || secret.isEmpty)
                Text("恢复密钥等同于好友身份的登录凭证。好友码用于添加好友，两者不同。此操作先验证新密钥，再保存，失败会保留旧身份。不要将恢复密钥发给他人或写入 Issue。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.harborPageBackground().navigationTitle("恢复好友身份").navigationBarTitleDisplayMode(.inline)
    }
}

struct HarborFriendIdentitySettings: View {
    @ObservedObject var model: HarborSocialLibrary
    @State private var showKey = false
    @State private var skinPicker = false
    @State private var slim = false
    @State private var loadingSkin = false
    var body: some View {
        Form {
            Section("资料共享") {
                HarborSettingsToggle("共享最近游戏", isOn: Binding(get: { model.snapshot?.me.sharing ?? false }, set: { model.share($0) })).disabled(model.busy)
                Text("默认关闭。共享仅包含实例名称、版本、加载器、已记录的存档名称、时长和主动选择的同行好友，不上传游戏文件、磁盘路径或 Minecraft 登录凭证。关闭会清除服务器已共享的历史。")
                    .font(.footnote).foregroundStyle(.secondary)
                HarborSettingsToggle("纤细手臂皮肤", isOn: $slim)
                Button("从文件共享皮肤") { skinPicker = true }.frame(minHeight: 44).disabled(model.busy || loadingSkin)
                Button("停止共享皮肤") { model.clearSkin() }.frame(minHeight: 44).disabled(model.busy || model.snapshot?.me.skinHash.isEmpty != false)
                if loadingSkin { ProgressView("读取皮肤…") }
                Text("好友头像读取对方主动共享的 Minecraft 皮肤头部；未共享时使用默认 Steve。皮肤文件仅接受64×64或64×32的 PNG。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("身份备份") {
                Button("显示我的恢复密钥") { showKey.toggle() }.frame(minHeight: 44)
                if showKey, let key = model.recoverySecret {
                    Text(key).font(.footnote.monospaced()).textSelection(.enabled).privacySensitive()
                    Button("复制恢复密钥") { UIPasteboard.general.setItems([["public.utf8-plain-text": key]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]) }.frame(minHeight: 44)
                    Text("密钥仅存本机钥匙串。此剪贴板副本一分钟后过期，且不会同步通用剪贴板。").font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink { HarborFriendRecovery(model: model) } label: { Text("恢复另一个身份").frame(minHeight: 44) }
            }
        }.harborPageBackground().navigationTitle("好友身份与共享").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $skinPicker, allowedContentTypes: [.png]) { result in
                switch result {
                case .failure(let error): model.error = error.localizedDescription
                case .success(let url):
                    loadingSkin = true
                    Task {
                        defer { loadingSkin = false }
                        do {
                            let data = try await Task.detached(priority: .utility) { try SocialSkin.readCoordinated(url) }.value
                            model.shareSkin(data, slim: slim)
                        } catch { model.error = error.localizedDescription }
                    }
                }
            }
    }
}
