import SwiftUI

enum HarborPalette {
    static let night = Color(hex: 0x0C110E)
    static let nightRaised = Color(hex: 0x1D2521)
    static let fog = Color(hex: 0xEDF3F2)
    static let oxide = Color(hex: 0x29825B)
    static let amber = Color(hex: 0xF0A33B)
    static let copper = Color(hex: 0xB96F4B)
    static let seaGlass = Color(hex: 0x93CFAF)
}

struct HarborTheme {
    let appearance: HarborAppearance

    var primaryText: Color {
        appearance.isLight ? HarborPalette.night : HarborPalette.fog
    }

    var secondaryText: Color {
        primaryText.opacity(0.62)
    }

    var sidebarTint: Color {
        switch appearance {
        case .dark:
            return HarborPalette.night.opacity(0.4)
        case .light, .theme:
            return Color.white.opacity(0.38)
        case .ultraClear:
            return HarborPalette.night.opacity(0.08)
        }
    }

    var glassTint: Color? {
        switch appearance {
        case .dark:
            return HarborPalette.nightRaised.opacity(0.2)
        case .light, .theme:
            return Color.white.opacity(0.18)
        case .ultraClear:
            return nil
        }
    }

    var border: Color {
        appearance.isLight
            ? Color.white.opacity(0.5)
            : HarborPalette.fog.opacity(appearance == .ultraClear ? 0.24 : 0.16)
    }

    var shadow: Color {
        appearance == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.07)
    }

}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// A single monotonic scale: 0 is diffuse, 1 is clear. Frost is a separate material.
struct HarborSurfacePolicy {
    let clarity:Double
    let frosted:Bool
    init(clarity:Double,frosted:Bool){self.clarity=max(0,min(1,clarity.isFinite ? clarity:0.82));self.frosted=frosted}
    var diffusion:Double{frosted ? 1:1-clarity}
    var liquid:Double{frosted ? 0:clarity}
}
struct HarborMaterial<S:Shape>:View {
    let shape:S
    let appearance:HarborAppearance
    var interactive=false
    @Environment(\.harborClarity) private var clarity
    @Environment(\.harborFrosted) private var frosted
    @Environment(\.harborAccent) private var accent
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body:some View{let policy=HarborSurfacePolicy(clarity:clarity,frosted:frosted);let light=appearance.isLight;let base=light ? Color(hex:0xF0F3F1):HarborPalette.nightRaised
        ZStack{
            if reduceTransparency{shape.fill(appearance == .theme ? accent.paleThemeColor:base)}else{
                if policy.diffusion>0.001{FrostedSurface(blur:36,radius:0,dark:!light).clipShape(shape).opacity(policy.diffusion)}
                if policy.liquid>0.001{shape.fill(base.opacity(0.035)).glassEffect(Glass.clear.tint(accent.opacity(appearance == .theme ? 0.12:0.025)).interactive(interactive),in:shape).opacity(policy.liquid)}
                // A constant neutral veil avoids changing hue as clarity moves.
                shape.fill((appearance == .theme ? accent:base).opacity(frosted ? (light ? 0.12:0.10):(appearance == .theme ? 0.10:0.015)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct HarborGlassModifier:ViewModifier {
    let appearance:HarborAppearance
    let radius:CGFloat
    let interactive:Bool
    func body(content:Content)->some View{let shape=RoundedRectangle(cornerRadius:radius,style:.continuous);let theme=HarborTheme(appearance:appearance)
        content.background{HarborMaterial(shape:shape,appearance:appearance,interactive:interactive)}
            .overlay(shape.stroke(theme.border,lineWidth:0.7).allowsHitTesting(false))
            .shadow(color:theme.shadow,radius:20,y:10)
    }
}

extension View {
    func harborGlass(
        appearance: HarborAppearance,
        radius: CGFloat = 22,
        interactive: Bool = false
    ) -> some View {
        modifier(
            HarborGlassModifier(
                appearance: appearance,
                radius: radius,
                interactive: interactive
            )
        )
    }

}

struct HarborActionButtonStyle: ButtonStyle {
    let appearance: HarborAppearance
    var prominent = false
    @Environment(\.harborAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.harborReduceMotion) private var customReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || customReduceMotion }
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let theme = HarborTheme(appearance: appearance)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? accent.readableInk : theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                if prominent {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent, accent.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                } else {
                    Capsule()
                        .fill(theme.sidebarTint)
                }
            }
            .overlay {
                Capsule()
                    .stroke(
                        prominent
                            ? HarborPalette.seaGlass.opacity(0.35)
                            : theme.border,
                        lineWidth: 0.7
                    )
            }
            .contentShape(.interaction,Capsule())
            .harborPrism(radius:16)
            .scaleEffect(
                configuration.isPressed
                    ? (reduceMotion ? 0.98 : 0.85)
                    : 1
            )
            .offset(y: configuration.isPressed && !reduceMotion ? 2.5 : 0)
            .brightness(configuration.isPressed ? 0.05 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.48)
            .animation(
                configuration.isPressed || reduceMotion
                    ? .easeOut(duration: 0.07)
                    : .spring(response: 0.38, dampingFraction: 0.44, blendDuration: 0.08),
                value: configuration.isPressed
            )
            .onChange(of:configuration.isPressed){_,pressed in if pressed && isEnabled{HarborAudio.shared.play(.select)}}
            .onHover{inside in if inside && isEnabled{HarborAudio.shared.play(.focus)}}
    }
}

struct HarborPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.85
    var pressedOffset: CGFloat = 2.5

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.harborReduceMotion) private var customReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || customReduceMotion }
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.interaction,RoundedRectangle(cornerRadius:16))
            .harborPrism(radius:16)
            .scaleEffect(
                configuration.isPressed
                    ? (reduceMotion ? 0.98 : pressedScale)
                    : 1
            )
            .offset(y: configuration.isPressed && !reduceMotion ? pressedOffset : 0)
            .brightness(configuration.isPressed ? 0.05 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.48)
            .animation(
                configuration.isPressed || reduceMotion
                    ? .easeOut(duration: 0.07)
                    : .spring(response: 0.38, dampingFraction: 0.44, blendDuration: 0.08),
                value: configuration.isPressed
            )
            .onChange(of:configuration.isPressed){_,pressed in if pressed && isEnabled{HarborAudio.shared.play(.select)}}
            .onHover{inside in if inside && isEnabled{HarborAudio.shared.play(.focus)}}
    }
}

private struct HarborReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var harborReduceMotion: Bool { get { self[HarborReduceMotionKey.self] } set { self[HarborReduceMotionKey.self] = newValue } } }
