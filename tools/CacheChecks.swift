import AppKit
import Foundation

@main struct CacheChecks {
    static func main()throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]);let source=URL(fileURLWithPath:CommandLine.arguments[2]);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=directory.appendingPathComponent("cache-fixture.png");try Data(contentsOf:source).write(to:file)
        let original=HarborImageCache.original(file.path),sameOriginal=HarborImageCache.original(file.path)
        let thumbnail=HarborImageCache.thumbnail(file.path),sameThumbnail=HarborImageCache.thumbnail(file.path)
        print("Thumbnail dimensions:",thumbnail?.size ?? .zero, thumbnail?.representations.map{"\($0.pixelsWide)x\($0.pixelsHigh)"} ?? [])
        var checks=["originalReused":original != nil && original === sameOriginal,"thumbnailReused":thumbnail != nil && thumbnail === sameThumbnail,"existing128PointThumbnailLayout":thumbnail != nil && thumbnail!.size.width<=128 && thumbnail!.size.height<=128]
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(3)],ofItemAtPath:file.path)
        checks["changedOriginalInvalidatesCache"]=HarborImageCache.original(file.path) !== original
        checks["changedThumbnailInvalidatesCache"]=HarborImageCache.thumbnail(file.path) !== thumbnail
        let result:[String:Any]=["checks":checks,"passed":checks.values.filter{$0}.count,"failed":checks.values.filter{!$0}.count]
        let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);try data.write(to:directory.appendingPathComponent("report.json"));print(String(decoding:data,as:UTF8.self));if checks.values.contains(false){exit(1)}
    }
}
