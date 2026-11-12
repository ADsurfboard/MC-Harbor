import Foundation
import ImageIO

struct CollectionVisual:Sendable {
    let bitmap:HarborDecodedBitmap
    let colors:FolderColorPair?
}
/// Local and remote artwork share one decode and one palette analysis across cards and their transmission layers.
actor CollectionArtworkLoader {
    static let shared=CollectionArtworkLoader()
    private var values:[String:(Date,CollectionVisual)]=[:]
    private var flights:[String:Task<CollectionVisual?,Never>]=[:]
    private var bytes=0
    func visual(_ address:String)async->CollectionVisual? {
        let url:URL,key:String
        if address.hasPrefix("https://"){
            guard let resolved=ResourceMirror.artworkURL(address) else{return nil};url=resolved;key=url.absoluteString
        }else{
            url=URL(fileURLWithPath:address)
            guard let attrs=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.isRegularFileKey]),attrs.isRegularFile==true,(attrs.fileSize ?? Int.max)<=16_000_000 else{return nil}
            key=url.path+"|"+String(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0)+"|"+String(attrs.fileSize ?? 0)
        }
        if let value=values[key]{values[key]=(Date(),value.1);return value.1}
        if let task=flights[key]{return await task.value}
        let task=Task.detached(priority:.utility){()->CollectionVisual? in
            let data:Data
            if url.isFileURL{guard let loaded=try? Data(contentsOf:url,options:.mappedIfSafe) else{return nil};data=loaded}
            else{guard let loaded=try? await HarborHTTP.data(url,limit:4_000_000) else{return nil};data=loaded}
            guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return nil}
            return CollectionVisual(bitmap:HarborDecodedBitmap(image:image),colors:FolderColorPair.analyze(image))
        }
        flights[key]=task;let visual=await task.value;flights.removeValue(forKey:key)
        if let visual{
            let cost=visual.bitmap.image.width*visual.bitmap.image.height*4
            while bytes+cost>24_000_000 || values.count>=128{guard let oldest=values.min(by:{$0.value.0<$1.value.0}) else{break};bytes-=oldest.value.1.bitmap.image.width*oldest.value.1.bitmap.image.height*4;values.removeValue(forKey:oldest.key)}
            values[key]=(Date(),visual);bytes+=cost
        }
        return visual
    }
}
