import AppKit
import SwiftUI
import ImageIO

private struct AccentKey:EnvironmentKey{static let defaultValue=Color(hex:0x29825B)}
private struct ClarityKey:EnvironmentKey{static let defaultValue=0.82}
private struct FrostedKey:EnvironmentKey{static let defaultValue=false}
private struct AppearanceKey:EnvironmentKey{static let defaultValue=HarborAppearance.ultraClear}
extension EnvironmentValues{
    var harborAccent:Color{get{self[AccentKey.self]}set{self[AccentKey.self]=newValue}}
    var harborClarity:Double{get{self[ClarityKey.self]}set{self[ClarityKey.self]=newValue}}
    var harborFrosted:Bool{get{self[FrostedKey.self]}set{self[FrostedKey.self]=newValue}}
    var harborAppearance:HarborAppearance{get{self[AppearanceKey.self]}set{self[AppearanceKey.self]=newValue}}
}
extension Color{
    init(hexString:String){let clean=hexString.trimmingCharacters(in:CharacterSet(charactersIn:"#"));self.init(hex:UInt32(clean,radix:16) ?? 0x29825B)}
    var hexString:String{let rgb=NSColor(self).usingColorSpace(.sRGB) ?? .systemGreen;return String(format:"#%02X%02X%02X",Int((rgb.redComponent*255).rounded()),Int((rgb.greenComponent*255).rounded()),Int((rgb.blueComponent*255).rounded()))}
    var readableInk:Color{let luminance=HarborColorContrast.luminance(NSColor(self));return (luminance+0.05)/0.05 >= 1.05/(luminance+0.05) ? .black:.white}
    func readableAccent(light:Bool)->Color {
        let background=HarborColorContrast.reference(light:light)
        let destination=light ? HarborPalette.night:HarborPalette.fog
        for step in 0...50{let candidate=harborMix(with:destination,by:Double(step)/50);if HarborColorContrast.ratio(NSColor(candidate),background)>=4.5{return candidate}}
        return destination
    }
    func harborMix(with other:Color,by fraction:Double)->Color{let a=NSColor(self).usingColorSpace(.deviceRGB) ?? .systemGreen;let b=NSColor(other).usingColorSpace(.deviceRGB) ?? .white;return Color(nsColor:a.blended(withFraction:max(0,min(1,fraction)),of:b) ?? a)}
    var paleThemeColor:Color{let rgb=NSColor(self).usingColorSpace(.deviceRGB) ?? .systemGreen;let minimum=min(rgb.redComponent,min(rgb.greenComponent,rgb.blueComponent));let mix=max(0,(0.72-minimum)/max(0.001,1-minimum));return self.harborMix(with:.white,by:mix)}
}

enum HarborColorContrast {
    private static let cache:NSCache<NSString,NSColor>={let cache=NSCache<NSString,NSColor>();cache.countLimit=512;return cache}()
    static func readable(_ preferred:Color,on background:Color)->Color {
        let key=(preferred.hexString+"/"+background.hexString) as NSString
        if let saved=cache.object(forKey:key){return Color(nsColor:saved)}
        if ratio(NSColor(preferred),NSColor(background))>=4.5{cache.setObject(NSColor(preferred),forKey:key);return preferred}
        let destination=background.readableInk
        for step in 1...50{let candidate=preferred.harborMix(with:destination,by:Double(step)/50);if ratio(NSColor(candidate),NSColor(background))>=4.5{cache.setObject(NSColor(candidate),forKey:key);return candidate}}
        return destination
    }
    static func reference(light:Bool)->NSColor{NSColor(Color(hex:light ? 0xC2C8C4:0x303B35))}
    static func luminance(_ color:NSColor)->Double {
        let value=color.usingColorSpace(.sRGB) ?? .black
        func linear(_ component:CGFloat)->Double{let v=Double(component);return v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
        return 0.2126*linear(value.redComponent)+0.7152*linear(value.greenComponent)+0.0722*linear(value.blueComponent)
    }
    static func ratio(_ a:NSColor,_ b:NSColor)->Double{let x=luminance(a),y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05)}
}
enum InstanceArt{
    private static let cache:NSCache<NSString,NSImage>={let cache=NSCache<NSString,NSImage>();cache.countLimit=64;cache.totalCostLimit=32*1024*1024;return cache}()
    static func image(_ game:GameInstance)->NSImage?{
        let resource:String
        switch game.loader{case "Forge":resource="forge";case "NeoForge":resource="neoforge";case "Fabric":resource="fabric";case "Legacy Fabric":resource="legacyfabric";case "Quilt":resource="quilt";case "Cleanroom":resource="cleanroom";default:resource="grass"}
        let path=game.iconPath ?? NativePaths.resources.appendingPathComponent("Loaders/"+resource+".png").path
        let revision=(try? URL(fileURLWithPath:path).resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key=(path+String(revision)) as NSString
        if let image=cache.object(forKey:key){return image}
        guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),let bitmap=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return nil}
        let image=NSImage(cgImage:bitmap,size:NSSize(width:bitmap.width,height:bitmap.height));cache.setObject(image,forKey:key,cost:bitmap.bytesPerRow*bitmap.height);return image
    }
}
enum BrandArtwork{static let icon=NSImage(contentsOf:NativePaths.resources.appendingPathComponent("Brand/Icon.png"))}

// Rounded-surface Fresnel and wavelength separation, inspired by ReactDrops optical modes.
// It renders only the rim. Native frosted material handles the backdrop; text is never sampled.
