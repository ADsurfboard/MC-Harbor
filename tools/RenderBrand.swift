import AppKit
import SwiftUI

@main struct RenderBrand {
    @MainActor static func main()throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let mark=ImageRenderer(content:HarborMonogram(darkInk:false).frame(width:446,height:512).padding(24))
        mark.scale=2;mark.isOpaque=false
        guard let cg=mark.cgImage,let png=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else{throw NSError(domain:"Brand",code:1)}
        try png.write(to:output.appendingPathComponent("Mark.png"))
        let dark=ImageRenderer(content:HarborMonogram(darkInk:true).frame(width:446,height:512).padding(24))
        dark.scale=2;dark.isOpaque=false
        if let cg=dark.cgImage,let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]){try data.write(to:output.appendingPathComponent("Mark-dark.png"))}
        // Only the folded h is supplied. macOS owns the icon presentation and surrounding tile.
        let icon=ImageRenderer(content:HarborMonogram(darkInk:false).frame(width:610,height:700).frame(width:1024,height:1024))
        icon.scale=1;icon.isOpaque=false
        guard let cg=icon.cgImage,let png=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else{throw NSError(domain:"Brand",code:3)}
        try png.write(to:output.appendingPathComponent("Icon.png"))
        let preview=ImageRenderer(content:HStack(spacing:18){HarborMonogram(darkInk:false).frame(width:38,height:44);Text(HarborBrand.shortName).font(.system(size:29,weight:.semibold)).tracking(-0.8).foregroundStyle(.white)}.padding(36).frame(width:350,height:120,alignment:.leading).background(Color(red:0.094,green:0.168,blue:0.137)))
        preview.scale=2
        guard let cg=preview.cgImage,let png=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else{throw NSError(domain:"Brand",code:2)}
        try png.write(to:output.appendingPathComponent("wordmark-preview.png"))
    }
}
