import AppKit
import SwiftUI

enum HarborThemeArea:String,CaseIterable,Identifiable,Codable {
    case buttonFill,buttonText,controls,icons,accentText,primaryText,secondaryText,surfaces,borders,effects
    var id:String{rawValue}
    var title:String{switch self{case .buttonFill:return "主要按钮背景";case .buttonText:return "按钮上的文字与图标";case .controls:return "选中状态与控件";case .icons:return "界面图标";case .accentText:return "强调文字";case .primaryText:return "主要文字";case .secondaryText:return "辅助文字";case .surfaces:return "玻璃卡片底色";case .borders:return "卡片与按钮边框";case .effects:return "欢迎动画与流体配色"}}
}
enum HarborColorRole:String,Codable,CaseIterable,Identifiable {case system,theme,inverse,custom;var id:String{rawValue};var title:String{switch self{case .system:return "默认";case .theme:return "主题色";case .inverse:return "反色";case .custom:return "自定义"}}}
enum HarborInverseMode:String,Codable,CaseIterable,Identifiable {case contrast,rgb,complementary,custom;var id:String{rawValue};var title:String{switch self{case .contrast:return "自动黑白对比色";case .rgb:return "RGB 反色";case .complementary:return "色相互补色";case .custom:return "自定义反色"}}}
struct HarborThemeSettings:Codable,Equatable {
    var roles:[String:HarborColorRole]=["buttonFill":.theme,"buttonText":.system,"controls":.theme,"effects":.theme]
    var custom:[String:String]=[:]
    var inverseMode:HarborInverseMode = .contrast
    var inverseHex="#10271E"
    var inverseBrightness=0.0
    var inverseSaturation=1.0
    var protectContrast=true
    var surfaceStrength=0.14
    var borderStrength=0.35
    func role(_ area:HarborThemeArea)->HarborColorRole{roles[area.rawValue] ?? .system}
}
struct HarborThemeRuntime {
    let settings:HarborThemeSettings;let appearance:HarborAppearance;let theme:Color
    var basicInk:Color{appearance.isLight ? HarborPalette.night:HarborPalette.fog}
    var inverse:Color {
        let rgb=NSColor(theme).usingColorSpace(.sRGB) ?? .systemGreen
        let base:Color
        switch settings.inverseMode {
        case .contrast:base=theme.readableInk
        case .rgb:base=Color(.sRGB,red:1-rgb.redComponent,green:1-rgb.greenComponent,blue:1-rgb.blueComponent,opacity:1)
        case .complementary:base=Color(nsColor:NSColor(calibratedHue:(rgb.hueComponent+0.5).truncatingRemainder(dividingBy:1),saturation:rgb.saturationComponent,brightness:rgb.brightnessComponent,alpha:1))
        case .custom:base=Color(hexString:settings.inverseHex)
        }
        let c=NSColor(base).usingColorSpace(.sRGB) ?? .black
        let saturated=abs(settings.inverseSaturation-1)<0.00001 ? base:Color(nsColor:NSColor(calibratedHue:c.hueComponent,saturation:min(1,max(0,c.saturationComponent*settings.inverseSaturation)),brightness:c.brightnessComponent,alpha:1))
        return saturated.harborMix(with:settings.inverseBrightness>=0 ? .white:.black,by:abs(settings.inverseBrightness))
    }
    func color(_ area:HarborThemeArea,default fallback:Color,text:Bool=false,on background:Color?=nil)->Color {
        let chosen:Color
        switch settings.role(area){case .system:chosen=fallback;case .theme:chosen=theme;case .inverse:chosen=inverse;case .custom:chosen=Color(hexString:settings.custom[area.rawValue] ?? theme.hexString)}
        guard text && settings.protectContrast else{return chosen}
        return HarborColorContrast.readable(chosen,on:background ?? Color(nsColor:HarborColorContrast.reference(light:appearance.isLight)))
    }
    var buttonFill:Color{color(.buttonFill,default:HarborPalette.oxide)}
    var buttonInk:Color{color(.buttonText,default:buttonFill.readableInk,text:true,on:buttonFill)}
    var controlTint:Color{color(.controls,default:HarborPalette.oxide,text:true)}
    var iconColor:Color{color(.icons,default:basicInk,text:true)}
    var accentText:Color{color(.accentText,default:basicInk,text:true)}
    var primaryText:Color{color(.primaryText,default:basicInk,text:true)}
    var secondaryText:Color{color(.secondaryText,default:appearance.isLight ? Color(hex:0x3E5046):Color(hex:0xC2CEC7),text:true)}
    var effects:Color{color(.effects,default:HarborPalette.oxide)}
    var surface:Color?{settings.role(.surfaces) == .system ? nil:color(.surfaces,default:theme)}
    var border:Color?{settings.role(.borders) == .system ? nil:color(.borders,default:theme).opacity(settings.borderStrength)}
}
private struct ThemeRuntimeKey:EnvironmentKey {static let defaultValue=HarborThemeRuntime(settings:.init(),appearance:.ultraClear,theme:HarborPalette.oxide)}
private struct IconInkKey:EnvironmentKey {static let defaultValue:Color?=nil}
extension EnvironmentValues {
    var harborThemeRuntime:HarborThemeRuntime{get{self[ThemeRuntimeKey.self]}set{self[ThemeRuntimeKey.self]=newValue}}
    var harborIconInk:Color?{get{self[IconInkKey.self]}set{self[IconInkKey.self]=newValue}}
}
/// SF Symbols follow the configured icon scope. Resource logos keep their original pixels.
struct HarborSymbol:View {
    let systemName:String
    @Environment(\.harborThemeRuntime) private var style
    @Environment(\.harborIconInk) private var onButton
    private var resizes=false
    init(systemName:String){self.systemName=systemName}
    func resizable()->Self{var value=self;value.resizes=true;return value}
    var body:some View{Group{if resizes{Image(systemName:systemName).resizable()}else{Image(systemName:systemName)}}.foregroundStyle(onButton ?? style.iconColor)}
}
struct ThemeCustomizationPanel:View {
    @ObservedObject var model:LauncherModel
    @State private var expanded=false
    private var configuration:Binding<HarborThemeSettings>{$model.preferences.themeCustomization}
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            Button{expanded.toggle()}label:{HStack{Text("主题范围与反色").font(.system(size:16,weight:.semibold));Spacer();HarborSymbol(systemName:expanded ? "chevron.up":"chevron.down")}.frame(maxWidth:.infinity).contentShape(Rectangle())}.buttonStyle(HarborBareButtonStyle())
            if expanded{
                HStack(spacing:12){swatch(model.themeColor,title:"主题色");swatch(model.themeRuntime.inverse,title:"反色");swatch(model.themeRuntime.accentText,title:"强调文字");Spacer();Button("恢复默认范围"){model.preferences.themeCustomization.roles=HarborThemeSettings().roles};Button("全界面跟随主题"){for area in HarborThemeArea.allCases{model.preferences.themeCustomization.roles[area.rawValue] = area == .buttonText ? .inverse:.theme}}}.buttonStyle(HarborButtonStyle())
                ForEach(HarborThemeArea.allCases){area in HStack{Text(area.title).font(.system(size:12));Spacer();Picker(area.title,selection:Binding(get:{model.preferences.themeCustomization.role(area)},set:{model.preferences.themeCustomization.roles[area.rawValue]=$0})){ForEach(HarborColorRole.allCases){role in Text(role.title).tag(role)}}.labelsHidden().frame(width:130);if model.preferences.themeCustomization.role(area) == .custom{ColorPicker(area.title,selection:Binding(get:{Color(hexString:model.preferences.themeCustomization.custom[area.rawValue] ?? model.preferences.themeHex)},set:{model.preferences.themeCustomization.custom[area.rawValue]=$0.hexString}),supportsOpacity:false).labelsHidden()}}}
                Divider()
                Picker("反色生成方式",selection:configuration.inverseMode){ForEach(HarborInverseMode.allCases){mode in Text(mode.title).tag(mode)}}
                if model.preferences.themeCustomization.inverseMode == .custom{ColorPicker("自定义反色",selection:Binding(get:{Color(hexString:model.preferences.themeCustomization.inverseHex)},set:{model.preferences.themeCustomization.inverseHex=$0.hexString}),supportsOpacity:false)}
                HStack{Text("反色亮度").frame(width:90,alignment:.leading);Slider(value:configuration.inverseBrightness,in:-0.5...0.5);Text(String(format:"%+.0f",model.preferences.themeCustomization.inverseBrightness*100)).monospacedDigit().frame(width:42)}
                HStack{Text("反色饱和度").frame(width:90,alignment:.leading);Slider(value:configuration.inverseSaturation,in:0...2);Text(String(format:"%.0f%%",model.preferences.themeCustomization.inverseSaturation*100)).monospacedDigit().frame(width:42)}
                HStack{Text("卡片染色强度").frame(width:90,alignment:.leading);Slider(value:configuration.surfaceStrength,in:0...0.7)}
                HStack{Text("边框强度").frame(width:90,alignment:.leading);Slider(value:configuration.borderStrength,in:0...1)}
                Toggle("自动保护文字对比度",isOn:configuration.protectContrast)
                Text("每类元素可独立使用默认色、主题色、反色或自定义色。自动保护会调整文字明暗；关闭后按原色显示。模组原图标与皮肤保持原图。").font(.system(size:11)).harborSecondaryText()
                HStack{Text("主题按钮预览").padding(12).foregroundStyle(model.themeRuntime.buttonInk).background(model.themeRuntime.buttonFill,in:Capsule());Text("强调文字预览").foregroundStyle(model.themeRuntime.accentText);Spacer()}
            }
        }.padding(24).harborGlass(appearance:model.appearance,radius:24)
    }
    private func swatch(_ color:Color,title:String)->some View{VStack(spacing:5){RoundedRectangle(cornerRadius:9).fill(color).frame(width:42,height:30);Text(title).font(.system(size:10))}}
}

private struct HarborSecondaryTextModifier:ViewModifier {
    @Environment(\.harborThemeRuntime) private var style
    func body(content:Content)->some View{content.foregroundStyle(style.secondaryText)}
}
extension View {func harborSecondaryText()->some View{modifier(HarborSecondaryTextModifier())}}
