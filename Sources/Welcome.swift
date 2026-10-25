import AppKit
import AVFoundation
import SwiftUI

@MainActor final class WelcomeAudio:ObservableObject {
    private var player:AVAudioPlayer?
    func play(volume:Double,duration:Double){guard let url=Bundle.main.url(forResource:"welcome",withExtension:"mp3") ?? Bundle.main.url(forResource:"welcome",withExtension:"wav") else{return};player=try? AVAudioPlayer(contentsOf:url);player?.volume=Float(volume);player?.prepareToPlay();player?.play()}
    func stop(){player?.setVolume(0,fadeDuration:0.2);DispatchQueue.main.asyncAfter(deadline:.now() + 0.25){self.player?.stop();self.player=nil}}
}
struct WelcomeSequence:View {
    @ObservedObject var model:LauncherModel
    @StateObject private var audio=WelcomeAudio()
    @State private var began=Date()
    @State private var reveal=false
    @State private var leaving=false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.harborReduceMotion) private var customReduceMotion
    private var reduceMotion:Bool{systemReduceMotion || customReduceMotion}
    var body:some View{GeometryReader{geometry in
        ZStack{
            Color(hex:0x07090D).opacity(0.97)
            if !reduceMotion {TimelineView(.animation(minimumInterval:1/60)){time in let t=min(1,time.date.timeIntervalSince(began)/model.preferences.introDuration);Canvas{context,size in
                let spread=sin(min(1,t*1.6) * Double.pi / 2)
                for i in 0..<220{let seed=Double(i);let angle=seed*2.399963;let radius=sqrt(seed/220);let coil=(1-spread)*0.7+spread*0.18;let pulse=sin(seed*7.6+t*5)*0.15;let distance=radius*Double(min(size.width,size.height))*(coil+pulse*0.06);let drift=t*t*Double(i%5-2)*18;let x=Double(size.width/2)+cos(angle+t*0.24)*distance+drift;let y=Double(size.height/2)+sin(angle)*distance*0.62;let opacity=(0.15 + 0.7*Double(i%9)/9)*(t<0.65 ? 1:max(0,(1-t)/0.35));let dot=Double(i%7==0 ? 2.0:1.0);let rect=CGRect(x:x,y:y,width:dot,height:dot);context.fill(Path(ellipseIn:rect),with:.color((i%17==0 ? model.themeColor:Color.white).opacity(opacity)))}
            }.drawingGroup().blur(radius:t<0.18 ? (1-t/0.18)*3:0)}}
            VStack(spacing:17){ShengganMark().frame(width:64,height:64).padding(.bottom,17);Text("欢迎，\(model.preferences.username.trimmingCharacters(in:.whitespacesAndNewlines))").font(.system(size:51,weight:.medium)).tracking(-1.5).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6);Text("MC Harbor").font(.system(size:12,weight:.medium)).tracking(2).foregroundStyle(.white.opacity(0.38))}.opacity(reveal && !leaving ? 1:0).offset(y:reveal ? 0:18).blur(radius:reveal ? 0:14).animation(.smooth(duration:0.85),value:reveal).animation(.easeOut(duration:0.45),value:leaving)
            VStack{Spacer();HStack{Spacer();Button("跳过"){finish()}.buttonStyle(HarborBareButtonStyle()).font(.system(size:11)).foregroundStyle(.white.opacity(0.42)).padding(28)}}
        }.clipShape(RoundedRectangle(cornerRadius:12))
    }.task{
        began=Date();HarborAudio.shared.play(.startup)
        try? await Task.sleep(for:.seconds(0.5));guard !Task.isCancelled else{return}
        withAnimation{reveal=true};if model.preferences.voiceEnabled{audio.play(volume:model.preferences.introVolume,duration:model.preferences.introDuration)}
        try? await Task.sleep(for:.seconds(max(0.5,model.preferences.introDuration-1.05)));guard !Task.isCancelled else{return};leaving=true
        try? await Task.sleep(for:.seconds(0.55));if !Task.isCancelled{finish()}
    }.onDisappear{audio.stop()}.accessibilityElement(children:.contain)}
    private func finish(){audio.stop();withAnimation(.easeInOut(duration:0.55)){model.showIntro=false}}
}
