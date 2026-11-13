import SwiftUI

struct HarborInstanceCard: View {
    let instance: PhoneInstance
    let compact: Bool
    let launch: () -> Void
    let manage: () -> Void
    let controls: () -> Void

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 14) {
                    identity
                    Spacer(minLength: 4)
                    launchButton.frame(width: 148)
                    more
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) { identity; Spacer(minLength: 0); more }
                    launchButton
                }
            }
        }.padding(.vertical, compact ? 8 : 12)
    }
    private var identity: some View {
        HStack(spacing: 14) {
            HarborLoaderArtwork(loader: instance.loader).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(instance.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text([instance.version, instance.loader].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var launchButton: some View {
        Button(action: launch) {
            Label("启动游戏", systemImage: "play.fill").font(.headline)
                .frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
        }.buttonStyle(.borderedProminent).accessibilityIdentifier("instance.launch." + instance.id)
    }
    private var more: some View {
        Menu {
            Button(action: manage) { Label("实例管理", systemImage: "slider.horizontal.3") }
            Button(action: controls) { Label("触控布局", systemImage: "hand.draw") }
        } label: {
            Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle()).contentShape(Circle())
        }.accessibilityLabel(instance.name + "，更多操作")
            .accessibilityIdentifier("instance.more." + instance.id)
    }
}
