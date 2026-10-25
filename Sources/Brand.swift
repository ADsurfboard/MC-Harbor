import SwiftUI

enum HarborBrand {
    static let name = "MC Harbor"
    static let shortName = "MC Harbor"
    static let version = "1.4.0"
}

/// Native vector counterpart of the standard icon's folded h. No tile or raster matte.
struct HarborMonogram: View {
    var body: some View {
        ZStack {
            FoldedHBody().fill(LinearGradient(colors:[Color(white:0.98),Color(white:0.91)],startPoint:.top,endPoint:.bottomTrailing))
            FoldedHTop().fill(Color(white:0.995))
            FoldedHUnderfold().fill(LinearGradient(colors:[Color(white:0.70),Color(white:0.93)],startPoint:.topLeading,endPoint:.bottomTrailing))
            FoldedHLeft().fill(LinearGradient(colors:[Color(white:1),Color(white:0.96)],startPoint:.topLeading,endPoint:.bottomTrailing))
        }.aspectRatio(0.87,contentMode:.fit).accessibilityHidden(true)
    }
}
private struct FoldedHLeft:Shape {
    func path(in r:CGRect)->Path{var p=Path();func v(_ x:CGFloat,_ y:CGFloat)->CGPoint{CGPoint(x:r.minX+x*r.width,y:r.minY+y*r.height)}
        p.move(to:v(0.278,0.008));p.addCurve(to:v(0.31,0.035),control1:v(0.297,-0.004),control2:v(0.31,0.006));p.addLine(to:v(0.31,0.825));p.addCurve(to:v(0.285,0.859),control1:v(0.31,0.844),control2:v(0.304,0.85));p.addLine(to:v(0.04,0.976));p.addCurve(to:v(0,0.947),control1:v(0.012,0.991),control2:v(0,0.975));p.addLine(to:v(0,0.179));p.addCurve(to:v(0.022,0.145),control1:v(0,0.164),control2:v(0.006,0.154));p.addLine(to:v(0.278,0.008));p.closeSubpath();return p}
}
private struct FoldedHBody:Shape {
    func path(in r:CGRect)->Path{var p=Path();func v(_ x:CGFloat,_ y:CGFloat)->CGPoint{CGPoint(x:r.minX+x*r.width,y:r.minY+y*r.height)}
        p.move(to:v(0.31,0.372));p.addLine(to:v(0.617,0.218));p.addCurve(to:v(0.677,0.218),control1:v(0.638,0.207),control2:v(0.653,0.207));p.addLine(to:v(0.975,0.344));p.addCurve(to:v(1,0.379),control1:v(0.994,0.352),control2:v(1,0.362));p.addLine(to:v(1,0.968));p.addCurve(to:v(0.963,0.996),control1:v(1,0.991),control2:v(0.985,1.006));p.addLine(to:v(0.71,0.899));p.addCurve(to:v(0.675,0.858),control1:v(0.683,0.889),control2:v(0.675,0.88));p.addLine(to:v(0.675,0.559));p.addCurve(to:v(0.612,0.512),control1:v(0.675,0.517),control2:v(0.656,0.491));p.addLine(to:v(0.31,0.658));p.closeSubpath();return p}
}
private struct FoldedHTop:Shape {
    func path(in r:CGRect)->Path{var p=Path();func v(_ x:CGFloat,_ y:CGFloat)->CGPoint{CGPoint(x:r.minX+x*r.width,y:r.minY+y*r.height)}
        p.move(to:v(0.31,0.372));p.addLine(to:v(0.617,0.218));p.addCurve(to:v(0.677,0.218),control1:v(0.638,0.207),control2:v(0.653,0.207));p.addLine(to:v(0.975,0.344));p.addCurve(to:v(0.994,0.36),control1:v(0.985,0.348),control2:v(0.99,0.351));p.addLine(to:v(0.685,0.507));p.addCurve(to:v(0.632,0.513),control1:v(0.662,0.52),control2:v(0.651,0.522));p.closeSubpath();return p}
}
private struct FoldedHUnderfold:Shape {
    func path(in r:CGRect)->Path{var p=Path();func v(_ x:CGFloat,_ y:CGFloat)->CGPoint{CGPoint(x:r.minX+x*r.width,y:r.minY+y*r.height)}
        p.move(to:v(0.31,0.372));p.addLine(to:v(0.632,0.513));p.addLine(to:v(0.31,0.658));p.closeSubpath();return p}
}
