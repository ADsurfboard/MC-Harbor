import AppKit
import SwiftUI

struct FrostPreview:View {
    @State private var blur=36.0
    var body:some View {
        VStack(spacing:20){
            Text("MC Harbor · Frost material check").font(.system(size:20,weight:.medium))
            ZStack{
                HStack(spacing:0){ForEach(0..<28){i in Rectangle().fill(i%2==0 ? Color.white:Color.black)}}
                VStack{Spacer();HStack{Color.red;Color.green;Color.blue}.frame(height:65)}
                Text("WALLPAPER DETAIL").font(.system(size:35,weight:.bold)).foregroundStyle(.orange).offset(y:-70)
                Text("Foreground stays sharp").font(.system(size:22,weight:.semibold)).foregroundStyle(.white).frame(width:480,height:195).background(FrostedSurface(blur:blur,radius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(.white.opacity(0.4)))
            }.frame(height:310).clipped()
            HStack{Text("Blur");Slider(value:$blur,in:0...45);Text(String(format:"%.0f",blur)).frame(width:35)}
        }.padding(25).frame(width:720).background(Color.gray.opacity(0.1))
    }
}
@main struct PreviewApp:App{var body:some Scene{WindowGroup("MC Harbor Material Check"){FrostPreview()}.defaultSize(width:770,height:470)}}
