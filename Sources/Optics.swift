import AppKit
import MetalKit
import SwiftUI
import ImageIO

private struct AccentKey:EnvironmentKey{static let defaultValue=Color(hex:0x29825B)}
private struct ClarityKey:EnvironmentKey{static let defaultValue=0.82}
private struct RainbowKey:EnvironmentKey{static let defaultValue=true}
private struct FrostedKey:EnvironmentKey{static let defaultValue=false}
private struct AppearanceKey:EnvironmentKey{static let defaultValue=HarborAppearance.ultraClear}
extension EnvironmentValues{
    var harborAccent:Color{get{self[AccentKey.self]}set{self[AccentKey.self]=newValue}}
    var harborClarity:Double{get{self[ClarityKey.self]}set{self[ClarityKey.self]=newValue}}
    var harborRainbow:Bool{get{self[RainbowKey.self]}set{self[RainbowKey.self]=newValue}}
    var harborFrosted:Bool{get{self[FrostedKey.self]}set{self[FrostedKey.self]=newValue}}
    var harborAppearance:HarborAppearance{get{self[AppearanceKey.self]}set{self[AppearanceKey.self]=newValue}}
}
extension Color{
    init(hexString:String){let clean=hexString.trimmingCharacters(in:CharacterSet(charactersIn:"#"));self.init(hex:UInt32(clean,radix:16) ?? 0x29825B)}
    var hexString:String{let rgb=NSColor(self).usingColorSpace(.deviceRGB) ?? .systemGreen;return String(format:"#%02X%02X%02X",Int(rgb.redComponent*255),Int(rgb.greenComponent*255),Int(rgb.blueComponent*255))}
    var readableInk:Color{let rgb=NSColor(self).usingColorSpace(.deviceRGB) ?? .systemGreen;return rgb.redComponent*0.2126+rgb.greenComponent*0.7152+rgb.blueComponent*0.0722 > 0.65 ? .black:.white}
    var paleThemeColor:Color{let rgb=NSColor(self).usingColorSpace(.deviceRGB) ?? .systemGreen;let minimum=min(rgb.redComponent,min(rgb.greenComponent,rgb.blueComponent));let mix=max(0,(0.72-minimum)/max(0.001,1-minimum));return self.mix(with:.white,by:mix)}
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
// It renders only the rim. SwiftUI's system glass handles the backdrop; text is never sampled.
struct OpticalRim:NSViewRepresentable{
    @Environment(\.harborRainbow) private var enabled
    var radius:CGFloat
    var strength:Double
    var color:Color
    var clarity:Double
    func makeNSView(context:Context)->RimMetalView{RimMetalView()}
    func updateNSView(_ view:RimMetalView,context:Context){view.isHidden = !enabled;guard enabled else{return};view.radius=Float(radius);view.strength=Float(strength*0.55);view.clarity=Float(clarity);let c=NSColor(color).usingColorSpace(.deviceRGB) ?? .systemGreen;view.accent=SIMD4(Float(c.redComponent),Float(c.greenComponent),Float(c.blueComponent),1);view.needsDisplay=true}
}
final class RimMetalView:MTKView,MTKViewDelegate{
    private static var sharedPipeline:MTLRenderPipelineState?
    private static var sharedQueue:MTLCommandQueue?
    var radius:Float=24
    var strength:Float=0.7
    var clarity:Float=0.8
    var accent=SIMD4<Float>(0.16,0.5,0.35,1)
    private var queue:MTLCommandQueue?
    private var pipeline:MTLRenderPipelineState?
    override var isOpaque:Bool{false}
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    override init(frame:CGRect,device:MTLDevice?){super.init(frame:frame,device:device ?? MTLCreateSystemDefaultDevice());configure()}
    convenience init(){self.init(frame:.zero,device:MTLCreateSystemDefaultDevice())}
    required init(coder:NSCoder){super.init(coder:coder);configure()}
    private func configure(){
        guard let device else{return};colorPixelFormat = .bgra8Unorm;clearColor=MTLClearColorMake(0,0,0,0);isPaused=true;enableSetNeedsDisplay=true;framebufferOnly=true;layer?.isOpaque=false;delegate=self;queue=device.makeCommandQueue()
        if let shared=Self.sharedPipeline{pipeline=shared;queue=Self.sharedQueue;return}
        do{let library=try device.makeLibrary(source:Self.shader,options:nil);let descriptor=MTLRenderPipelineDescriptor();descriptor.vertexFunction=library.makeFunction(name:"rimVertex");descriptor.fragmentFunction=library.makeFunction(name:"rimFragment");let attachment=descriptor.colorAttachments[0]!;attachment.pixelFormat=colorPixelFormat;attachment.isBlendingEnabled=true;attachment.sourceRGBBlendFactor = .one;attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha;attachment.sourceAlphaBlendFactor = .one;attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha;pipeline=try device.makeRenderPipelineState(descriptor:descriptor);Self.sharedPipeline=pipeline;Self.sharedQueue=queue}catch{NSLog("Optical rim: %@",error.localizedDescription)}
    }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){needsDisplay=true}
    func draw(in view:MTKView){guard let drawable=currentDrawable,let pass=currentRenderPassDescriptor,let queue,let pipeline,let command=queue.makeCommandBuffer(),let encoder=command.makeRenderCommandEncoder(descriptor:pass) else{return}
        let scale=Float(drawableSize.width/max(bounds.width,1));let r=min(radius,Float(min(bounds.width,bounds.height)/2));var uniforms=RimUniforms(size:SIMD2(Float(drawableSize.width),Float(drawableSize.height)),radius:max(2,r*scale),strength:strength,light:SIMD2(0.7,-0.7),clarity:clarity,pad:0,accent:accent)
        encoder.setRenderPipelineState(pipeline);encoder.setFragmentBytes(&uniforms,length:MemoryLayout<RimUniforms>.stride,index:0);encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6);encoder.endEncoding();command.present(drawable);command.commit()
    }
    private struct RimUniforms{var size:SIMD2<Float>;var radius:Float;var strength:Float;var light:SIMD2<Float>;var clarity:Float;var pad:Float;var accent:SIMD4<Float>}
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    struct V {float4 position [[position]];};
    struct U {float2 size;float radius;float strength;float2 light;float clarity;float pad;float4 accent;};
    vertex V rimVertex(uint id [[vertex_id]]) {float2 p[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};return {float4(p[id],0,1)};}
    float sdf(float2 p,float2 size,float r){float2 q=abs(p-size*.5)-(size*.5-r);return length(max(q,0.0))+min(max(q.x,q.y),0.0)-r;}
    fragment float4 rimFragment(V in [[stage_in]],constant U &u [[buffer(0)]]){
      float2 p=in.position.xy;float scale=max(1.0,u.radius/28.0);float d=sdf(p,u.size,u.radius);
      float2 n=normalize(float2(sdf(p+float2(0.6,0),u.size,u.radius)-sdf(p-float2(0.6,0),u.size,u.radius),sdf(p+float2(0,0.6),u.size,u.radius)-sdf(p-float2(0,0.6),u.size,u.radius))+0.00001);
      float2 cornerA=float2(u.size.x-u.radius,u.radius),cornerB=float2(u.radius,u.size.y-u.radius);
      float focus=min(1.0,exp(-pow(length(p-cornerA)/(u.radius*0.8),3.0))+exp(-pow(length(p-cornerB)/(u.radius*0.75),3.0)));
      float curvature=smoothstep(0.1,0.65,abs(n.x*n.y)*2.0);float optical=focus*(0.38+curvature*0.62);
      float shoulder=clamp(0.5+dot(n,normalize(u.light))*0.5,0.0,1.0);
      float thickness=(0.55+1.3*curvature)*scale;float x=(d+thickness*0.64)/max(scale,1.0);
      float red=exp(-pow((x+1.7)/1.9,2.0));float green=exp(-pow(x/1.6,2.0));float blue=exp(-pow((x-1.8)/1.95,2.0));
      float3 spectrum=float3(red*0.85+blue*0.23,green*0.78+blue*0.3,blue*0.96+red*0.25);
      float fresnel=pow(1.0-clamp(abs(d)/max(thickness,1.0),0.0,1.0),2.0);
      float white=exp(-pow((d+0.75*scale)/max(0.65*scale,0.6),2.0))*(0.2+0.6*shoulder);
      float dark=exp(-pow((d+thickness+1.2*scale)/max(0.9*scale,0.7),2.0))*optical*0.23;
      float alpha=clamp((max(max(spectrum.r,spectrum.g),spectrum.b)*optical*0.85+white*focus*0.5+dark)*u.strength,0.0,0.9);
      float3 rgb=spectrum*0.32+float3(0.85)*white*0.8+u.accent.rgb*0.02*fresnel;
      rgb=mix(rgb,float3(0.015,0.027,0.023),dark*1.8);alpha*=1.0-smoothstep(0.0,1.5*scale,d);
      return float4(clamp(rgb,0.0,1.0)*alpha,alpha);
    }
    """
}
