import SwiftUI
import CoreGraphics

/// Sample the original artwork once, off the main thread. Fully transparent RGB never affects the palette.
struct FolderColorPair:Sendable,Equatable {
    struct RGB:Sendable,Equatable {
        let r:Double,g:Double,b:Double
        func mixed(with other:Self,amount:Double)->Self{let t=min(1,max(0,amount));return .init(r:r+(other.r-r)*t,g:g+(other.g-g)*t,b:b+(other.b-b)*t)}
        var color:Color{Color(.sRGB,red:r,green:g,blue:b,opacity:1)}
        func distance(_ other:Self)->Double{pow(r-other.r,2)+pow(g-other.g,2)+pow(b-other.b,2)}
    }
    let first:RGB,second:RGB
    static func analyze(_ image:CGImage)->Self? {
        let side=40
        var pixels=[UInt8](repeating:0,count:side*side*4)
        let success=pixels.withUnsafeMutableBytes{buffer->Bool in
            guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:buffer.baseAddress,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
            context.interpolationQuality = .medium;context.draw(image,in:CGRect(x:0,y:0,width:side,height:side));return true
        }
        guard success else{return nil}
        struct Point{let rgb:RGB,weight:Double}
        var points:[Point]=[],bins:[Int:(Double,Double,Double,Double)]=[:]
        for i in stride(from:0,to:pixels.count,by:4){
            let alpha=Double(pixels[i+3])/255;guard alpha>=0.1 else{continue}
            let rgb=RGB(r:min(1,Double(pixels[i])/255/alpha),g:min(1,Double(pixels[i+1])/255/alpha),b:min(1,Double(pixels[i+2])/255/alpha))
            points.append(Point(rgb:rgb,weight:alpha))
            let key=(Int(rgb.r*7)<<6)|(Int(rgb.g*7)<<3)|Int(rgb.b*7),old=bins[key] ?? (0,0,0,0)
            bins[key]=(old.0+rgb.r*alpha,old.1+rgb.g*alpha,old.2+rgb.b*alpha,old.3+alpha)
        }
        let ranked=bins.sorted{a,b in a.value.3==b.value.3 ? a.key<b.key:a.value.3>b.value.3}
        guard let dominant=ranked.first else{return nil}
        func center(_ bin:(Double,Double,Double,Double))->RGB{.init(r:bin.0/bin.3,g:bin.1/bin.3,b:bin.2/bin.3)}
        var a=center(dominant.value),b=a
        let total=points.reduce(0){$0+$1.weight}
        // Reject isolated highlights as seeds; refine both major colour masses with alpha-weighted k-means.
        let candidates=ranked.filter{$0.value.3>=max(total*0.025,dominant.value.3*0.20)}
        if let distant=candidates.max(by:{a.distance(center($0.value))<a.distance(center($1.value))}){b=center(distant.value)}
        var firstWeight=total,secondWeight=0.0
        for _ in 0..<8{
            var sums=[(0.0,0.0,0.0,0.0),(0.0,0.0,0.0,0.0)]
            for point in points{let index=point.rgb.distance(a)<=point.rgb.distance(b) ? 0:1;let old=sums[index],w=point.weight;sums[index]=(old.0+point.rgb.r*w,old.1+point.rgb.g*w,old.2+point.rgb.b*w,old.3+w)}
            if sums[0].3>0{a=center(sums[0])};if sums[1].3>0{b=center(sums[1])}else{b=a}
            firstWeight=sums[0].3;secondWeight=sums[1].3
        }
        return firstWeight>=secondWeight ? Self(first:a,second:b):Self(first:b,second:a)
    }
}
/// Only the semi-transparent underlay moves; source artwork never changes size or position per frame.
enum FolderFlowField {
    static func sample(x:Double,y:Double,time:Double)->Double {
        let wave=sin(x*4.6+sin(y*3.1+time*0.31)+time*0.23)+cos(y*5.2+sin(x*2.8-time*0.27))-sin((x+y)*3.3-time*0.19)
        return min(1,max(0,0.5+wave/6))
    }
}
struct FolderFlowBackdrop:View {
    let colors:FolderColorPair
    var frozenTime:Double?=nil
    @Environment(\.harborReduceMotion) private var reduceMotion
    @State private var visible=false
    @Environment(\.scenePhase) private var scenePhase
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/60,paused:reduceMotion || !visible || scenePhase != .active || frozenTime != nil)){timeline in
            canvas(time:frozenTime ?? (reduceMotion ? 0:timeline.date.timeIntervalSinceReferenceDate))
        }.onAppear{visible=true}.onDisappear{visible=false}
    }
    private func canvas(time:Double)->some View {
        Canvas(opaque:false,rendersAsynchronously:true){context,size in
            context.opacity=0.62
            context.addFilter(.blur(radius:max(7,min(size.width,size.height)*0.11)))
            context.drawLayer{layer in
                layer.fill(Path(CGRect(origin:.zero,size:size).insetBy(dx:-30,dy:-30)),with:.color(colors.first.mixed(with:colors.second,amount:0.5).color))
                // Four broad source-colour lobes replace 143 tiny cells without reducing frame cadence.
                for index in 0..<4{
                    let phase=time*0.24+Double(index)*1.83
                    let center=CGPoint(x:size.width*CGFloat(0.5+0.52*sin(phase+sin(phase*0.37))),y:size.height*CGFloat(0.5+0.5*cos(phase*0.79+Double(index))))
                    let radius=max(size.width,size.height)*CGFloat(0.53+0.24*FolderFlowField.sample(x:Double(index)*0.29,y:0.65,time:time))
                    let color=(index%2==0 ? colors.first:colors.second).color
                    layer.fill(Path(ellipseIn:CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2)),with:.radialGradient(Gradient(stops:[.init(color:color.opacity(0.95),location:0),.init(color:color.opacity(0.6),location:0.45),.init(color:color.opacity(0),location:1)]),center:center,startRadius:0,endRadius:radius))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
