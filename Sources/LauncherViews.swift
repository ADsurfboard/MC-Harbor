import AppKit
import QuartzCore
import SwiftUI

@main struct ShengganApp: App {
    @StateObject private var model=LauncherModel()
    var body:some Scene {
        WindowGroup("MC Harbor") { LauncherRoot(model:model).frame(minWidth:1040,minHeight:700) }
            .defaultSize(width:1180,height:780)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing:.newItem){Button("刷新游戏库"){model.scan()}.keyboardShortcut("r");Button("导入整合包…"){model.importPack()}.keyboardShortcut("i")}
                CommandGroup(after:.appInfo){Button("播放欢迎动画"){model.showIntro=true}}
                CommandGroup(replacing:.appSettings){Button("设置…"){model.inspectedGame=nil;model.modal=nil;model.section = .settings}.keyboardShortcut(",")}
            }
    }
}
struct LauncherRoot:View {
    @ObservedObject var model:LauncherModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var presented:Bool{model.inspectedGame != nil || model.modal != nil}
    private var transition:AnyTransition{systemReduceMotion || model.preferences.reduceMotion ? .opacity:.scale(scale:0.955).combined(with:.opacity).combined(with:.offset(y:20))}
    var body:some View {
        let theme=HarborTheme(appearance:model.appearance)
        GeometryReader{geometry in
            ZStack {
                NativeBackdrop(model:model)
                HStack(spacing:0){NativeSidebar(model:model);VStack(spacing:0){topBar;Group{switch model.section{case .library:NativeLibraryView(model:model);case .downloads:NativeDownloadsView(model:model);case .accounts:NativeAccountsView(model:model);case .multiplayer:NativeMultiplayerView(model:model,connection:model.sakura);case .friends:NativeFriendsView(model:model,social:model.social);case .settings:NativeSettingsView(model:model)}}.frame(maxWidth:.infinity,maxHeight:.infinity)}}
                    .blur(radius:presented ? 14:0)
                    .scaleEffect(presented && !systemReduceMotion && !model.preferences.reduceMotion ? 0.987:1)
                    .opacity(model.showIntro ? 0:1)
                    .allowsHitTesting(!presented && !model.showIntro)
                    .accessibilityHidden(presented || model.showIntro)
                if presented {
                    ModalFluidBackdrop(color:model.themeColor,dark:model.appearance == .dark)
                        .contentShape(Rectangle()).allowsHitTesting(true)
                        .onTapGesture{if case .worldEditor = model.modal {}else if model.modal != nil{model.modal=nil}else{model.inspectedGame=nil}}
                        .transition(.opacity)
                }
                if let game=model.inspectedGame {
                    InstanceWorkspace(model:model,game:game)
                        .frame(maxWidth:1120,maxHeight:.infinity)
                        .padding(.horizontal,28).padding(.top,52).padding(.bottom,28)
                        .blur(radius:model.modal != nil ? 12:0)
                        .scaleEffect(model.modal != nil ? 0.987:1)
                        .allowsHitTesting(model.modal==nil)
                        .accessibilityHidden(model.modal != nil)
                        .transition(transition).zIndex(2)
                }
                if let modal=model.modal{HarborModalHost(model:model,modal:modal,available:geometry.size).id(modal.id).transition(transition).zIndex(3)}
                WindowConfigurator().frame(width:0,height:0)
                if let toast=model.toastMessage {VStack{Spacer();HStack{Spacer();HarborToast(message:toast,appearance:model.appearance)}}.padding(24).transition(.opacity.combined(with:.move(edge:.bottom))).zIndex(4)}
                if model.showIntro {WelcomeSequence(model:model).transition(.opacity).zIndex(5)}
            }
        }
        .animation(.spring(response:0.48,dampingFraction:0.86),value:model.inspectedGame?.id)
        .animation(.spring(response:0.48,dampingFraction:0.86),value:model.modal?.id)
        .animation(.smooth(duration:0.6),value:model.showIntro)
        .foregroundStyle(theme.primaryText)
        .buttonStyle(HarborButtonStyle())
        .preferredColorScheme(model.appearance.isLight ? .light:.dark)
        .tint(model.controlTint)
        .environment(\.harborAccent,model.themeColor)
        .environment(\.harborClarity,model.surfaceClarity)
        .environment(\.harborFrosted,model.preferences.frostedGlass)
        .environment(\.harborAppearance,model.appearance)
        .environment(\.harborRainbow,model.preferences.rainbowCorners)
        .environment(\.harborReduceMotion,model.preferences.reduceMotion || systemReduceMotion)
        .alert("MC Harbor",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0{model.errorMessage=nil}})){Button("好"){model.errorMessage=nil}} message:{Text(model.errorMessage ?? "")}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in model.terracotta.stop(synchronous:true);model.sakura.stop();model.social.chat.disconnect();model.social.flush();model.flushPreferences()}
        .onAppear{model.social.connectIfConfigured()}
        .onChange(of:model.section){_,_ in model.search="";HarborAudio.shared.play(.navigate)}
        .onChange(of:model.inspectedGame?.id){old,new in HarborAudio.shared.play(new == nil ? .close:.open)}
        .onChange(of:model.modal?.id){old,new in HarborAudio.shared.play(new == nil ? .close:.open)}
        .onChange(of:model.errorMessage){_,message in if message != nil{HarborAudio.shared.play(.error)}}
    }
    private var topBar:some View {
        HStack(spacing:16){Text(model.section.title).font(.system(size:13,weight:.semibold));Spacer();if let work=model.works.first(where:{$0.active}){ProgressView().controlSize(.mini);Text(work.title).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)};Button{model.scan()}label:{Image(systemName:"arrow.clockwise").font(.system(size:12))}.buttonStyle(HarborBareButtonStyle()).help("刷新")}
            .padding(.horizontal,28).frame(height:54).background(WindowDragRegion())
    }
}
struct NativeSidebar:View {
    @ObservedObject var model:LauncherModel
    var body:some View {
        let theme=HarborTheme(appearance:model.appearance)
        VStack(alignment:.leading,spacing:12){
            HStack(spacing:11){HarborMonogram().frame(width:27,height:32);Text(HarborBrand.shortName).font(.system(size:21,weight:.semibold,design:.default)).tracking(-0.65).foregroundStyle(theme.primaryText).fixedSize(horizontal:true,vertical:false)}.accessibilityElement(children:.ignore).accessibilityLabel(HarborBrand.name).padding(.horizontal,12).padding(.top,28).padding(.bottom,34)
            ForEach(NativeSection.allCases){section in
                Button{withAnimation(.easeInOut(duration:0.2)){model.inspectedGame=nil;model.section=section}}label:{HStack(spacing:12){Image(systemName:section.icon).font(.system(size:16,weight:.medium)).frame(width:24);Text(section.title).font(.system(size:14,weight:.medium));Spacer();if section == .friends{FriendUnreadBadge(chat:model.social.chat)};if section == .library{Text("\(model.games.count)").font(.system(size:11,design:.monospaced)).foregroundStyle(theme.secondaryText)}}.padding(.horizontal,14).frame(height:47).contentShape(RoundedRectangle(cornerRadius:16)).background{if model.section==section{HarborMaterial(shape:RoundedRectangle(cornerRadius:16),appearance:model.appearance,interactive:true)}}}.buttonStyle(HarborPressButtonStyle(pressedScale:0.96,pressedOffset:0))
            }
            Spacer()
            Button{model.inspectedGame=nil;model.section = .accounts}label:{HStack(spacing:11){Group{if let account=model.selectedAccount{MinecraftAvatar(model:model,account:account).frame(width:28,height:28)}else{Image(systemName:"person.crop.circle").font(.system(size:24,weight:.ultraLight))}};VStack(alignment:.leading,spacing:3){Text(model.selectedAccount?.name ?? model.preferences.username).font(.system(size:12,weight:.medium));Text(model.selectedAccount == nil ? "未选择游戏账号":model.selectedAccount?.kind == "microsoft" ? "Microsoft":model.selectedAccount?.kind == "authlibInjector" ? "第三方认证":"离线账号").font(.system(size:10)).foregroundStyle(theme.secondaryText)};Spacer()}.padding(13).harborGlass(appearance:model.appearance,radius:18,interactive:true)}.buttonStyle(HarborPressButtonStyle(pressedScale:0.97,pressedOffset:0))
        }.padding(16).frame(width:210).background{if model.preferences.frostedGlass{HarborMaterial(shape:Rectangle(),appearance:model.appearance)}else{theme.sidebarTint.opacity(0.6)}}
    }
}
struct NativeLibraryView:View {
    @ObservedObject var model:LauncherModel
    var body:some View {
        ScrollView{
            VStack(alignment:.leading,spacing:24){
                HStack(alignment:.bottom){VStack(alignment:.leading,spacing:6){Text("游戏库").font(.system(size:34,weight:.semibold));Text("\(model.games.count) 个游戏").font(.system(size:12)).foregroundStyle(.secondary)};Spacer();Button{model.importPack()}label:{Image(systemName:"square.and.arrow.down")}.buttonStyle(HarborButtonStyle()).controlSize(.large).help("导入整合包");Button{model.section = .downloads}label:{Label("安装",systemImage:"plus")}.buttonStyle(HarborButtonStyle(prominent:true)).controlSize(.large)}
                if let game=model.selected{FeaturedWorld(model:model,game:game)}
                HStack(spacing:12){TextField("搜索游戏",text:$model.search).textFieldStyle(.plain).font(.system(size:13));Image(systemName:"magnifyingglass").foregroundStyle(.secondary)}.padding(13).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:14))
                if model.filteredGames.isEmpty{HarborEmptyState(icon:"square.stack.3d.up",title:"暂无游戏",detail:"",appearance:model.appearance)}
                LazyVGrid(columns:[GridItem(.adaptive(minimum:300,maximum:480),spacing:14)],spacing:14){ForEach(model.filteredGames){game in
                    Button{withAnimation(.smooth(duration:0.2)){model.preferences.selectedGame=game.id}}label:{HStack(spacing:14){WorldIcon(game:model.artworkGame(game)).frame(width:46,height:46);VStack(alignment:.leading,spacing:6){Text(model.displayName(game)).font(.system(size:14,weight:.medium)).lineLimit(1);Text(game.version+" · "+game.loader).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)};Spacer(minLength:0);if model.preferences.favorites.contains(game.id){Image(systemName:"star.fill").font(.system(size:10)).foregroundStyle(.secondary)};Color.clear.frame(width:38,height:38)}.padding(16).frame(maxWidth:.infinity,alignment:.leading).background{ZStack{HarborMaterial(shape:RoundedRectangle(cornerRadius:19),appearance:model.appearance);if model.selected?.id==game.id{RoundedRectangle(cornerRadius:19).fill(model.themeColor.opacity(0.08))}}}.overlay(RoundedRectangle(cornerRadius:19).stroke(model.selected?.id==game.id ? model.themeColor.opacity(0.6):Color.white.opacity(0.2),lineWidth:0.7)).contentShape(RoundedRectangle(cornerRadius:19))}.buttonStyle(HarborPressButtonStyle(pressedScale:0.98,pressedOffset:0)).overlay(alignment:.trailing){InstanceMoreButton{model.inspectedGame=game}.padding(.trailing,16)}.contextMenu{Button("启动"){model.launch(game)};Button("管理"){model.inspectedGame=game};Button("更换图标…"){model.chooseInstanceIcon(game)};Button(model.preferences.favorites.contains(game.id) ? "取消收藏":"收藏"){model.favorite(game)};Button("打开目录"){model.open(game.runDirectory)}}
                }}
            }.padding(.horizontal,28).padding(.top,14).padding(.bottom,28)
        }.scrollIndicators(.hidden)
    }
}
struct FeaturedWorld:View {
    @ObservedObject var model:LauncherModel
    let game:GameInstance
    var body:some View {
        HStack(spacing:10){
            VStack(alignment:.leading,spacing:16){Text(game.loader).font(.system(size:11,weight:.medium)).foregroundStyle(.secondary);Text(model.displayName(game)).font(.system(size:43,weight:.semibold)).tracking(-1.2).lineLimit(2).minimumScaleFactor(0.75);Text(game.version).font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary);Spacer(minLength:15);HStack(spacing:12){Button{model.launch(game)}label:{Label(model.running.contains(game.id) ? "运行中":"启动游戏",systemImage:"play.fill").font(.system(size:14,weight:.semibold)).padding(.horizontal,12).padding(.vertical,4)}.buttonStyle(HarborButtonStyle(prominent:true)).controlSize(.large).disabled(model.running.contains(game.id));Button{model.inspectedGame=game}label:{Image(systemName:"slider.horizontal.3").frame(width:25,height:25)}.buttonStyle(HarborButtonStyle()).controlSize(.large)}}.frame(maxWidth:.infinity,alignment:.leading)
            ZStack{WorldSculpture().frame(width:220,height:220);if let image=InstanceArt.image(model.artworkGame(game)){Image(nsImage:image).resizable().interpolation(.high).scaledToFit().frame(width:94,height:94).clipShape(RoundedRectangle(cornerRadius:22)).offset(y:-7).shadow(color:.black.opacity(0.12),radius:18,y:14)}}.frame(width:230)
        }.padding(30).frame(height:273).harborGlass(appearance:model.appearance,radius:28,interactive:true).overlay(OpticalRim(radius:28,strength:0.76,color:model.themeColor,clarity:model.surfaceClarity)).accessibilityElement(children:.contain)
    }
}
struct ShengganMark:View {
    var body:some View{HarborMonogram(darkInk:false)}
}
struct WorldIcon:View {
    let game:GameInstance
    var body:some View{Group{if let image=InstanceArt.image(game){Image(nsImage:image).resizable().interpolation(.high).scaledToFit()}else{ZStack{RoundedRectangle(cornerRadius:13).fill(.primary.opacity(0.035));Image(systemName:"cube.transparent").font(.system(size:23,weight:.ultraLight)).foregroundStyle(.primary.opacity(0.55))}}}.clipShape(RoundedRectangle(cornerRadius:13))}
}
struct WorldSculpture:View {
    @Environment(\.harborAccent) private var accent
    @Environment(\.harborClarity) private var clarity
    @Environment(\.harborAppearance) private var appearance
    var body:some View{ZStack{ForEach(0..<3){index in HarborMaterial(shape:ProjectedGlassPlate(),appearance:appearance).frame(width:210,height:128).overlay(ProjectedGlassPlate().stroke(.white.opacity(0.23),lineWidth:0.7)).offset(y:CGFloat(index-1)*25)}}.accessibilityHidden(true)}
}
/// Project the outline before applying system glass; transformed backdrop filters create stray lines.
struct ProjectedGlassPlate:Shape {
    func path(in r:CGRect)->Path{var p=Path();func point(_ x:CGFloat,_ y:CGFloat)->CGPoint{CGPoint(x:r.minX+x*r.width,y:r.minY+y*r.height)};p.move(to:point(0.35,0.06));p.addCurve(to:point(0.55,0.035),control1:point(0.40,0),control2:point(0.48,0));p.addLine(to:point(0.93,0.35));p.addCurve(to:point(0.93,0.58),control1:point(1.02,0.43),control2:point(1.02,0.51));p.addLine(to:point(0.63,0.93));p.addCurve(to:point(0.42,0.97),control1:point(0.57,1.005),control2:point(0.49,1.005));p.addLine(to:point(0.065,0.72));p.addCurve(to:point(0.06,0.48),control1:point(-0.02,0.66),control2:point(-0.015,0.56));p.addLine(to:point(0.35,0.06));p.closeSubpath();return p}
}
struct NativeBackdrop:View {
    @ObservedObject var model:LauncherModel
    @Environment(\.scenePhase) private var phase
    var body:some View{ZStack{
        HarborWallpaperView(settings:model.preferences.wallpaper,appearance:model.appearance,pauseWhenInactive:true,animationEnabled:model.preferences.wallpaper.kind == .video)
        if model.appearance == .theme{model.themeColor.opacity(0.24).allowsHitTesting(false)}
        if model.preferences.fluidBackground && model.preferences.wallpaper.kind == .harbor{FluidField(dark:model.appearance == .dark,color:model.themeColor,active:phase == .active && !model.preferences.reduceMotion).opacity(0.62)}
    }.ignoresSafeArea()}
}
struct FluidField:View {
    let dark:Bool;let color:Color;let active:Bool
    var body:some View{CompositedFluid(dark:dark,color:color,active:active && !ProcessInfo.processInfo.isLowPowerModeEnabled).allowsHitTesting(false).accessibilityHidden(true)}
}

/// The compositor moves soft fluid lobes without rebuilding the SwiftUI tree every frame.
private struct CompositedFluid:NSViewRepresentable {
    let dark:Bool;let color:Color;let active:Bool
    func makeNSView(context:Context)->FluidLayerView{FluidLayerView()}
    func updateNSView(_ view:FluidLayerView,context:Context){view.configure(color:NSColor(color),dark:dark,active:active)}
}
private final class FluidLayerView:NSView {
    private let lobes=(0..<3).map{_ in CAGradientLayer()}
    private var running=false
    private var lastSize=CGSize.zero
    private var configuredColor:NSColor?
    private var configuredDark:Bool?
    override var isOpaque:Bool{false}
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;layer?.masksToBounds=true
        for lobe in lobes{lobe.type = .radial;lobe.startPoint=CGPoint(x:0.5,y:0.5);lobe.endPoint=CGPoint(x:1,y:1);lobe.locations=[0,0.5,1];layer?.addSublayer(lobe)}
    }
    required init?(coder:NSCoder){nil}
    func configure(color:NSColor,dark:Bool,active:Bool){
        if configuredDark != dark || configuredColor?.isEqual(color) != true {
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer?.backgroundColor=(dark ? NSColor(calibratedRed:0.035,green:0.055,blue:0.042,alpha:1):NSColor(calibratedWhite:0.97,alpha:1)).cgColor
        for (index,lobe) in lobes.enumerated(){let alpha=(dark ? 0.55:0.24)*(index==1 ? 0.7:1);lobe.colors=[color.withAlphaComponent(alpha).cgColor,color.withAlphaComponent(alpha*0.32).cgColor,color.withAlphaComponent(0).cgColor]}
        CATransaction.commit()
        configuredColor=color;configuredDark=dark
        }
        if running != active{running=active;updateMotion()}
    }
    override func layout(){super.layout();guard bounds.size != lastSize else{return};lastSize=bounds.size
        CATransaction.begin();CATransaction.setDisableActions(true)
        let centers:[CGPoint]=[.init(x:0.1,y:0.18),.init(x:0.85,y:0.72),.init(x:0.56,y:0.08)]
        for (index,lobe) in lobes.enumerated(){lobe.bounds=CGRect(x:0,y:0,width:bounds.width*(index==1 ? 1.4:1.1),height:bounds.height*(index==2 ? 0.95:1.3));lobe.position=CGPoint(x:bounds.width*centers[index].x,y:bounds.height*centers[index].y);lobe.transform=CATransform3DMakeRotation(CGFloat(index)*0.7,0,0,1)}
        CATransaction.commit();updateMotion()
    }
    private func updateMotion(){
        for (index,lobe) in lobes.enumerated(){lobe.removeAnimation(forKey:"fluid");guard running,bounds.width>0 else{continue}
            let movement=CABasicAnimation(keyPath:"position");movement.fromValue=lobe.position;movement.toValue=CGPoint(x:lobe.position.x+bounds.width*(index==1 ? -0.24:0.22),y:lobe.position.y+bounds.height*(index==2 ? 0.24:-0.17))
            let stretch=CABasicAnimation(keyPath:"transform.scale");stretch.fromValue=0.94;stretch.toValue=1.18
            let group=CAAnimationGroup();group.animations=[movement,stretch];group.duration=Double(17+index*4);group.autoreverses=true;group.repeatCount = .infinity;group.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut);lobe.add(group,forKey:"fluid")
        }
    }
}
