import SwiftUI
import UIKit
import HarborCore

struct HarborConversation: View {
    @ObservedObject var model: HarborSocialLibrary
    let person: SocialPerson
    let instances: [PhoneInstance]
    @Environment(\.scenePhase) private var scenePhase
    @State private var sending = false
    @State private var error: String?
    @State private var composeInvite = false
    @State private var invitation: SocialMessage?
    private var rows: [SocialMessage] { model.messages[person.id] ?? [] }
    private var draft: Binding<String> { Binding(get: { model.drafts[person.id] ?? "" }, set: { model.drafts[person.id] = $0 }) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if rows.isEmpty { Text("还没有消息。只有双方确认的好友可以聊天。").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160) }
                    ForEach(rows) { message in
                        messageView(message).id(message.id)
                    }
                }.padding(16)
            }.scrollDismissesKeyboard(.interactively)
                .onChange(of: rows.last?.id) { id in
                    if let id { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) } }
                    if scenePhase == .active { model.markRead(person) }
                }
                .onAppear { if let id = rows.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .harborPageBackground().navigationTitle(model.name(person)).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { composer }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            do {
                try await model.refreshMessages(person)
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    if !model.live { try await model.refreshMessages(person) }
                }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $composeInvite) { HarborComposeInvitation(model: model, person: person, instances: instances) }
        .sheet(item: $invitation) { HarborInvitationDetail(message: $0) }
        .alert("聊天", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private var composer: some View {
        VStack(spacing: 10) {
            HStack {
                Circle().fill(model.live ? .green : .secondary).frame(width: 7, height: 7)
                Text(model.live ? "实时消息已连接" : "消息可刷新读取").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { composeInvite = true } label: { Label("快捷邀请", systemImage: "gamecontroller").frame(minHeight: 44).contentShape(Rectangle()) }
                    .disabled(sending || model.busy)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("发送消息", text: draft, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44).accessibilityIdentifier("chat.input")
                Button { send() } label: {
                    if sending { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: "arrow.up").frame(width: 44, height: 44).contentShape(Rectangle()) }
                }.harborGlassButton(prominent: true).accessibilityLabel("发送消息").disabled(sending || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.regularMaterial)
    }
    private func messageView(_ message: SocialMessage) -> some View {
        let own = message.sender == model.snapshot?.me.id
        return HStack(alignment: .bottom, spacing: 12) {
            if own { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 9) {
                if !message.text.isEmpty { Text(message.text).font(.body).textSelection(.enabled) }
                if let invite = message.invite {
                    Button { invitation = message } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("联机邀请", systemImage: "gamecontroller.fill").font(.headline)
                            Text(invite.instance.isEmpty ? invite.target : invite.instance).font(.subheadline).lineLimit(2)
                            Text("查看连接信息").font(.caption)
                        }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text(Date(timeIntervalSince1970: message.created), style: .time).font(.caption2).foregroundStyle(.secondary)
            }.padding(14).background(own ? Color.accentColor.opacity(0.13) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            if !own { Spacer(minLength: 48) }
        }
    }
    private func send() {
        let text = draft.wrappedValue
        guard !sending else { return }; sending = true
        Task {
            defer { sending = false }
            do { try await model.send(text, to: person); if draft.wrappedValue == text { draft.wrappedValue = "" }; model.markRead(person) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct HarborComposeInvitation: View {
    @ObservedObject var model: HarborSocialLibrary
    let person: SocialPerson
    let instances: [PhoneInstance]
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var profile = ""
    @State private var sending = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("邀请连接服务器") {
                    TextField("域名或 IP，可附加端口", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Picker("实例信息", selection: $profile) {
                        Text("不附加实例信息").tag("")
                        ForEach(instances) { Text($0.name).tag($0.id) }
                    }
                    Text("将连接地址和可选的实例信息发送给好友，邀请30分钟后过期。好友仍需准备兼容的 Minecraft 版本与模组。服务只传递邀请，不代理游戏网络。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("发送邀请") { send() }.frame(maxWidth: .infinity, minHeight: 48).harborGlassButton(prominent: true).disabled(sending || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if sending { ProgressView("发送中…") }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section { Button("取消") { dismiss() }.frame(maxWidth: .infinity, minHeight: 48).disabled(sending) }
            }.harborPageBackground().navigationTitle("邀请 \(model.name(person))").navigationBarTitleDisplayMode(.inline)
        }.harborMotionPolicy()
    }
    private func send() {
        guard !sending else { return }; sending = true
        let instance = instances.first { $0.id == profile }
        let invitation = SocialInvitation(transport: "address", target: address.trimmingCharacters(in: .whitespacesAndNewlines), instance: instance?.name ?? "", version: instance?.gameVersion ?? instance?.version ?? "", loader: instance?.loader ?? "")
        Task {
            defer { sending = false }
            do { try await model.send("邀请你一起游玩 Minecraft", to: person, invite: invitation); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct HarborInvitationDetail: View {
    let message: SocialMessage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let invite = message.invite {
                    Section("连接信息") {
                        LabeledContent(invite.transport == "address" ? "服务器地址" : "Terracotta 房间", value: invite.target).textSelection(.enabled)
                        if !invite.instance.isEmpty { LabeledContent("实例", value: invite.instance) }
                        if !invite.version.isEmpty { LabeledContent("Minecraft", value: invite.version) }
                        if !invite.loader.isEmpty { LabeledContent("加载器", value: invite.loader) }
                        Text(message.expires > Date().timeIntervalSince1970 ? "有效期至 \(Date(timeIntervalSince1970: message.expires).formatted(date: .omitted, time: .shortened))" : "此邀请已过期")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("复制连接信息") { UIPasteboard.general.string = invite.target }.frame(maxWidth: .infinity, minHeight: 48).disabled(message.expires <= Date().timeIntervalSince1970)
                        Text(invite.transport == "address" ? "在兼容实例的多人游戏中添加此地址。局域网或隧道地址需要双方先建立相应网络连接。" : "iOS 当前不能直接运行 Mac 的 Terracotta / EasyTier 进程。可保留房间信息，在支持的桌面客户端或已配置的网络环境中连接；此按钮不会伪装为一键入房。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section { Button("完成") { dismiss() }.frame(maxWidth: .infinity, minHeight: 48) }
            }.harborPageBackground().navigationTitle("联机邀请").navigationBarTitleDisplayMode(.inline)
        }.harborMotionPolicy()
    }
}
