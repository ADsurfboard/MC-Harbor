import AppKit
import ImageIO

/// Reuse decoded artwork without changing source pixels, resolution or animation settings.
enum HarborImageCache {
    private static let artwork:NSCache<NSString,NSImage> = {let cache=NSCache<NSString,NSImage>();cache.countLimit=160;cache.totalCostLimit=16*1024*1024;return cache}()
    private static let originals:NSCache<NSString,NSImage> = {let cache=NSCache<NSString,NSImage>();cache.countLimit=4;cache.totalCostLimit=64*1024*1024;return cache}()
    private static func key(_ path:String,_ size:Int)->NSString{let attrs=try? FileManager.default.attributesOfItem(atPath:path);let date=(attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0;let bytes=(attrs?[.size] as? NSNumber)?.int64Value ?? 0;return "\(path)|\(size)|\(date)|\(bytes)" as NSString}
    static func original(_ path:String)->NSImage?{let id=key(path,0);if let image=originals.object(forKey:id){return image};guard let image=NSImage(contentsOfFile:path) else{return nil};let cost=min(32*1024*1024,max(1,Int(image.size.width*image.size.height*4)));originals.setObject(image,forKey:id,cost:cost);return image}
    static func thumbnail(_ path:String,pixels:Int=128)->NSImage?{let id=key(path,pixels);if let image=artwork.object(forKey:id){return image};guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:pixels,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return nil};let image=NSImage(cgImage:cg,size:.zero);artwork.setObject(image,forKey:id,cost:cg.width*cg.height*4);return image}
}
