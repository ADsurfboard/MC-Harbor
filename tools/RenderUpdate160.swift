import AppKit
import SwiftUI

struct WorldIcon:View{let game:GameInstance;var body:some View{EmptyView()}}
struct ShengganMark:View{var body:some View{EmptyView()}}
struct FluidField:View{let dark:Bool;let color:Color;let active:Bool;var body:some View{EmptyView()}}

@main struct RenderUpdate160 {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);setenv("SHENGGAN_DATA_DIR",root.path,1)
        let output=URL(fileURLWithPath:CommandLine.arguments[2]);try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let model=LauncherModel();model.showIntro=false
        let games=NativeScanner.scan(model.preferences.gameRoot);model.games=games
        guard let game=games.first else{fatalError("Missing fixture")}
        model.modMetadata[game.id]=(0..<80).map{i in ModFile(id:"qa-\(i)",name:"\(i) 超长名称模组 Long Minecraft Mod Title For Layout Verification",path:URL(fileURLWithPath:game.runDirectory).appendingPathComponent("mods/qa.jar"),enabled:true,size:12345678,version:"1.20.1-2.3.4",authors:"Long Author Name",modID:"qa_\(i)",iconPath:NativePaths.resources.appendingPathComponent("Loaders/forge.png").path,summary:"A test description")}
        func capture<V:View>(_ name:String,_ view:V,width:CGFloat,height:CGFloat){
            let host=NSHostingView(rootView:view.frame(width:width,height:height).environment(\.colorScheme,model.appearance.isLight ? .light:.dark).foregroundStyle(HarborTheme(appearance:model.appearance,style:model.themeRuntime).primaryText).environment(\.harborAppearance,model.appearance).environment(\.harborReduceMotion,true).preferredColorScheme(model.appearance.isLight ? .light:.dark))
            host.frame=NSRect(x:0,y:0,width:width,height:height);host.layoutSubtreeIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{fatalError("No bitmap")};host.cacheDisplay(in:host.bounds,to:bitmap)
            try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
        }
        for appearance in [HarborAppearance.light,.dark]{model.preferences.appearance=appearance
            capture("resources-"+appearance.rawValue,InstanceWorkspace(model:model,game:game),width:980,height:660)
            capture("folders-"+appearance.rawValue,ModCollectionsView(model:model),width:980,height:660)
            capture("contributors-"+appearance.rawValue,ContributorsPanel().padding(25),width:850,height:450)
        }
        print("Rendered six native SwiftUI views at explicit layout bounds")
    }
}
