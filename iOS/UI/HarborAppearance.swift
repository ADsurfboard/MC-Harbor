import SwiftUI
import UIKit

enum HarborAppearance {
    // Shared with HarborMotion.h. Off means the complete visual experience.
    static let exclusiveOptimizationKey = "harbor.performance.exclusive"
}

/// Suppress our animations at the presentation root as well as on each sheet.
/// This does not change the device's accessibility settings or game simulation.
private struct HarborMotionPolicy: ViewModifier {
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transaction { transaction in
            if exclusive || reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

private struct HarborGlassSurface: ViewModifier {
    let radius: CGFloat
    let interactive: Bool
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground),
                               in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else if #available(iOS 26.0, *) {
            // Optimization keeps the same optical material, without deformation.
            content.glassEffect(.regular.interactive(interactive && !exclusive && !reduceMotion),
                                in: .rect(cornerRadius: radius))
        } else {
            content.background(.regularMaterial,
                               in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

private struct HarborGlassButton: ViewModifier {
    let prominent: Bool
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if exclusive || reduceMotion {
                // Plain style avoids the system glass button's press spring.
                content.buttonStyle(.plain)
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .padding(.horizontal, 14).padding(.vertical, 2)
                    .glassEffect(prominent ? .regular.tint(.accentColor) : .regular,
                                 in: .rect(cornerRadius: 24))
            } else if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// One native effect container for a related set of controls.
struct HarborGlassGroup<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else { content }
    }
}

/// Static, restrained colors make the glass visible in both appearances.
/// No display link or perpetual animation is introduced by the background.
struct HarborPageBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var wallpaper = HarborWallpaperState.shared
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                RadialGradient(colors: [
                    Color(red: 0.35, green: 0.73, blue: 0.69).opacity(colorScheme == .dark ? 0.26 : 0.25),
                    .clear
                ], center: .topLeading, startRadius: 0,
                   endRadius: max(geometry.size.width, geometry.size.height) * 0.8)
                RadialGradient(colors: [
                    Color(red: 0.52, green: 0.66, blue: 0.81).opacity(colorScheme == .dark ? 0.18 : 0.2),
                    .clear
                ], center: .bottomTrailing, startRadius: 0,
                   endRadius: max(geometry.size.width, geometry.size.height) * 0.65)
                if let image = wallpaper.image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                if let player = wallpaper.player, !exclusive {
                    HarborWallpaperVideo(player: player).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                if wallpaper.image != nil || wallpaper.player != nil {
                    Color(uiColor: .systemGroupedBackground).opacity(colorScheme == .dark ? 0.56 : 0.42)
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            .onChange(of: exclusive) { wallpaper.setPolicy(exclusive: $0) }
    }
}

/// Glass belongs to the group, not to every touching List row. This avoids
/// overlapping system shadows and keeps a real 14pt gap between hit regions.
struct HarborGlassPanel<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .harborGlass(radius: 26)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
    }
}

extension View {
    func harborMotionPolicy() -> some View { modifier(HarborMotionPolicy()) }
    func harborGlass(radius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(HarborGlassSurface(radius: radius, interactive: interactive))
    }
    func harborGlassButton(prominent: Bool = false) -> some View {
        modifier(HarborGlassButton(prominent: prominent))
    }
    func harborPageBackground() -> some View {
        scrollContentBackground(.hidden).background { HarborPageBackdrop() }
    }
}

struct HarborPerformanceSettings: View {
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    var body: some View {
        Section {
          HarborGlassPanel {
            Toggle(isOn: $exclusive) {
                Label("独家优化", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { exclusive.toggle() }
            }.accessibilityIdentifier("settings.performance.exclusive")
            Text(exclusive
                 ? "已保留玻璃外观，关闭启动器内的过渡、玻璃弹性和动态装饰。不会改变游戏的画质、帧率设置或触控响应。"
                 : "完整视觉效果已开启。启用独家优化可保留玻璃外观，并关闭启动器内的过渡、玻璃弹性和动态装饰。")
                .font(.footnote).foregroundStyle(.secondary)
            if #available(iOS 26.0, *) {
                Text(exclusive ? "Liquid Glass · 静态模式" : "Liquid Glass · 完整效果")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.performance.material")
            } else {
                Text("此系统使用兼容的磨砂玻璃材质。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
          }
        } header: { Text("外观与性能") }
    }
}

/// Keep the platform switch, while also making its full label/blank area an
/// explicit target. Native switch gestures are left to the platform control.
struct HarborSettingsToggle: View {
    let title: String
    @Binding var value: Bool
    init(_ title: String, isOn value: Binding<Bool>) { self.title = title; _value = value }
    var body: some View {
        Toggle(isOn: $value) {
            Text(title).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture { value.toggle() }
        }.frame(minHeight: 44)
    }
}
