import AVFoundation
import SwiftUI

enum HarborSound:String,CaseIterable {
    case focus, select, navigate, open, close, launch, success, error, startup
}

/// Downloaded interface recordings. Players are prepared once and never run a persistent audio loop.
@MainActor final class HarborAudio {
    static let shared=HarborAudio()
    private var players:[HarborSound:AVAudioPlayer]=[:]
    private var enabled=true
    private var volume:Float=0.48
    private var lastFocus=Date.distantPast
    private var bank:Data?
    private var entries:[String:[String:Int]]=[:]
    private var audioOffset=0
    func configure(enabled:Bool,volume:Double){self.enabled=enabled;self.volume=Float(max(0,min(1,volume)));if !enabled{for player in players.values{player.stop()}}}
    private func cueData(_ cue:HarborSound)->Data?{
        if bank==nil,let url=Bundle.main.url(forResource:"Interface",withExtension:"soundbank"),let bytes=try? Data(contentsOf:url,options:.mappedIfSafe),bytes.count>12,String(decoding:bytes.prefix(8),as:UTF8.self)=="MCHSFX01"{
            let length=Int(bytes[8]) | Int(bytes[9])<<8 | Int(bytes[10])<<16 | Int(bytes[11])<<24
            guard length>0,length<100_000,12+length<bytes.count,let header=(try? JSONSerialization.jsonObject(with:bytes.subdata(in:12..<(12+length)))) as? [String:Any],let index=header["entries"] as? [String:[String:Int]] else{return nil}
            bank=bytes;entries=index;audioOffset=12+length
        }
        guard let bytes=bank,let entry=entries[cue.rawValue],let offset=entry["offset"],let length=entry["length"],offset>=0,length>0,audioOffset+offset+length<=bytes.count else{return nil}
        return bytes.subdata(in:(audioOffset+offset)..<(audioOffset+offset+length))
    }
    func play(_ cue:HarborSound){
        guard enabled else{return}
        if cue == .focus {guard Date().timeIntervalSince(lastFocus)>0.09 else{return};lastFocus=Date()}
        if players[cue]==nil,let data=cueData(cue){players[cue]=try? AVAudioPlayer(data:data);players[cue]?.prepareToPlay()}
        guard let player=players[cue] else{return}
        player.currentTime=0;player.volume=volume*(cue == .focus ? 0.32:1);player.play()
    }
}

/// WinHarbor spring interaction with native system glass and shared sound feedback.
struct HarborButtonStyle:ButtonStyle {
    var prominent=false
    @Environment(\.harborAccent) private var accent
    @Environment(\.harborThemeRuntime) private var customization
    @Environment(\.harborClarity) private var clarity
    @Environment(\.harborAppearance) private var appearance
    @Environment(\.harborFrosted) private var frosted
    @Environment(\.harborReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .font(.system(size:12,weight:.medium))
            .foregroundStyle(prominent ? customization.buttonInk:customization.primaryText)
            .environment(\.harborIconInk,prominent ? customization.buttonInk:nil)
            .padding(.horizontal,16).padding(.vertical,9)
            .background{ZStack{HarborMaterial(shape:Capsule(),appearance:appearance,interactive:true);if prominent{Capsule().fill(customization.buttonFill.opacity(frosted ? 0.8:1))}}}
            .contentShape(.interaction,Capsule())
            .overlay(Capsule().stroke(customization.border ?? .white.opacity(prominent ? 0.25:0.12),lineWidth:0.6))

            .scaleEffect(configuration.isPressed ? (reduceMotion ? 0.98:0.94):1)
            .offset(y:configuration.isPressed && !reduceMotion ? 1:0)
            .opacity(enabled ? 1:0.42)
            .animation(reduceMotion ? .linear(duration:0.1):.spring(response:0.32,dampingFraction:0.68),value:configuration.isPressed)
            .harborOnChange(of:configuration.isPressed){_,pressed in if pressed && enabled{HarborAudio.shared.play(.select)}}
            .onHover{inside in if inside && enabled{HarborAudio.shared.play(.focus)}}
    }
}

struct HarborBareButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View{
        configuration.label.frame(minWidth:28,minHeight:28).contentShape(.interaction,RoundedRectangle(cornerRadius:9)).opacity(configuration.isPressed ? 0.72:1)
            .harborOnChange(of:configuration.isPressed){_,pressed in if pressed{HarborAudio.shared.play(.select)}}
            .onHover{inside in if inside{HarborAudio.shared.play(.focus)}}
    }
}
