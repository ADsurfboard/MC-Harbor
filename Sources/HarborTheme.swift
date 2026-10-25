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
        appearance == .light ? HarborPalette.night : HarborPalette.fog
    }

    var secondaryText: Color {
        primaryText.opacity(0.62)
    }

    var sidebarTint: Color {
        switch appearance {
        case .dark:
            return HarborPalette.night.opacity(0.4)
        case .light:
            return Color.white.opacity(0.38)
        case .ultraClear:
            return HarborPalette.night.opacity(0.08)
        }
    }

    var glassTint: Color? {
        switch appearance {
        case .dark:
            return HarborPalette.nightRaised.opacity(0.2)
        case .light:
            return Color.white.opacity(0.18)
        case .ultraClear:
            return nil
        }
    }

    var border: Color {
        appearance == .light
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

struct HarborGlassModifier: ViewModifier {
    let appearance: HarborAppearance
    let radius: CGFloat
    let interactive: Bool
    @Environment(\.harborClarity) private var clarity
    @Environment(\.harborAccent) private var accent
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // Negative clarity increases native backdrop diffusion, never the dark fill.
    // The existing nonnegative Liquid Glass range is unchanged.
    private var minimumFrost: Double {
        guard !reduceTransparency, clarity < 0.50 else { return 0 }
        let value = max(0, min(1, 1 - clarity / 0.50))
        return value * value * (3 - 2 * value)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let theme = HarborTheme(appearance: appearance)
        if minimumFrost > 0 || appearance == .light {
            // Keep the AppKit diffuser outside the SwiftUI glass subtree. Wrapping an
            // NSVisualEffectView in glassEffect lets the compositor flatten/rebuild
            // its backdrop when a scroll view or modal animates over it.
            let frost = max(minimumFrost, appearance == .light ? pow(1-clarity,2)*0.65:0)
            content
                .foregroundStyle(theme.primaryText.mix(with:HarborPalette.night,by:minimumFrost*0.92))
                .environment(\.colorScheme,minimumFrost>0.65 ? .light:(appearance == .light ? .light:.dark))
                .background {
                    ZStack {
                        FrostedSurface(blur:36*frost,radius:radius)
                        shape.fill((appearance == .light ? Color(hex:0xF0F3F1):HarborPalette.nightRaised).opacity(0.25*(1-minimumFrost)))
                            .glassEffect(Glass.clear.tint(accent.opacity(0.035*(1-minimumFrost))).interactive(interactive),in:shape)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
                .overlay(shape.stroke(theme.border,lineWidth:0.7))
                .shadow(color:theme.shadow,radius:20,y:10)
        } else if #available(macOS 26.0, *) {
            switch appearance {
            case .ultraClear:
                content
                    .background(HarborPalette.nightRaised.opacity(pow(1-clarity,2)),in:shape)
                    .glassEffect((reduceTransparency ? Glass.regular : Glass.clear).tint(accent.opacity((1-clarity)*0.10)).interactive(interactive), in: shape)
                    .overlay(shape.stroke(theme.border, lineWidth: 0.7))
                    .shadow(color: theme.shadow, radius: 22, y: 12)
            case .dark, .light:
                content
                    .background((appearance == .dark ? HarborPalette.nightRaised:Color(hex:0xF0F3F1)).opacity(pow(1-clarity,2)),in:shape)
                    .glassEffect(
                        (clarity>0.55 && !reduceTransparency ? Glass.clear:Glass.regular)
                            .tint(accent.opacity((1-clarity)*0.07))
                            .interactive(interactive),
                        in: shape
                    )
                    .overlay(shape.stroke(theme.border, lineWidth: 0.7))
                    .shadow(color: theme.shadow, radius: 20, y: 10)
            }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(theme.border, lineWidth: 0.7))
                .shadow(color: theme.shadow, radius: 18, y: 9)
        }
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
            .foregroundStyle(prominent ? Color.white : theme.primaryText)
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
