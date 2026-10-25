import SwiftUI

struct NativeDownloadsView:View {
    @ObservedObject var model:LauncherModel
    @State private var targetID=""
    private let categories:[(String,String)]=[("minecraft","游戏"),("mods","模组"),("resourcepacks","资源包"),("shaderpacks","光影"),("saves","地图"),("modpacks","整合包"),("tasks","任务")]
    private var kind:ContentKind?{ContentKind(rawValue:model.downloadCategory)}
    private var target:GameInstance?{model.games.first{$0.id==targetID} ?? model.selected}
    private var catalog:GameInstance{let directory=URL(fileURLWithPath:model.preferences.gameRoot).appendingPathComponent("versions/catalog");return GameInstance(id:"catalog",version:"",loader:"Minecraft",directory:directory.path,runDirectory:model.preferences.gameRoot,iconPath:nil,modified:.distantPast)}
    var body:some View {
        VStack(spacing:0) {
            navigation
            if model.downloadCategory == "minecraft" {
                NativeMinecraftDownloadsView(model:model)
            } else if model.downloadCategory == "tasks" {
                DownloadJobs(model:model)
            } else if let kind {
                VStack(spacing:14) {
                    HStack {
                        Text(kind.title).font(.system(size:34,weight:.semibold))
                        Spacer()
                        if kind != .modpacks {
                            Picker("安装到",selection:$targetID) {
                                ForEach(model.games) { game in
                                    Text(model.displayName(game)+" · "+game.version).tag(game.id)
                                }
                            }.frame(maxWidth:300)
                        }
                    }.padding(.horizontal,28).padding(.top,15)
                    if let chosen = kind == .modpacks ? catalog:target {
                        AddonBrowser(model:model,game:chosen,kind:kind,embedded:true)
                            .id(kind.rawValue+chosen.id)
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                            .harborGlass(appearance:model.appearance,radius:24)
                            .padding(.horizontal,20).padding(.bottom,20)
                    } else {
                        ContentUnavailableView("先安装 Minecraft 实例",systemImage:"shippingbox")
                    }
                }
            }
        }.task { if targetID.isEmpty { targetID=model.selected?.id ?? "" } }
    }
    private var navigation:some View {
        HStack(spacing:5) {
            ForEach(categories,id:\.0) { id,title in
                Button {
                    model.downloadCategory=id
                    HarborAudio.shared.play(.navigate)
                } label: {
                    HStack(spacing:6) {
                        Text(title)
                        if id == "tasks",model.works.contains(where:{$0.active}) {
                            Circle().fill(model.themeColor).frame(width:5,height:5)
                        }
                    }
                    .font(.system(size:12,weight:model.downloadCategory==id ? .semibold:.regular))
                    .padding(.horizontal,14).frame(height:34)
                    .background {
                        if model.downloadCategory==id {
                            Capsule().fill(model.themeColor.opacity(0.13)).glassEffect(.clear.interactive(),in:.capsule)
                        }
                    }
                }.buttonStyle(HarborBareButtonStyle())
            }
            Spacer(minLength:0)
        }.padding(.horizontal,28).padding(.vertical,12)
    }
}

private struct DownloadJobs:View {
    @ObservedObject var model:LauncherModel
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:18){Text("任务").font(.system(size:34,weight:.semibold));if model.works.isEmpty{ContentUnavailableView("没有下载任务",systemImage:"arrow.down.circle")};ForEach(model.works){work in VStack(alignment:.leading,spacing:12){HStack{Text(work.title).font(.system(size:15,weight:.medium));Spacer();if work.active{Button("取消"){model.cancel(work)}.buttonStyle(HarborButtonStyle())}else{Image(systemName:work.error ? "exclamationmark.circle":"checkmark.circle").foregroundStyle(work.error ? Color.orange:Color.secondary)}};if let progress=work.progress{ProgressView(value:progress)}else if work.active{ProgressView().controlSize(.small)};if !work.detail.isEmpty{Text(work.detail).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)}}.padding(22).harborGlass(appearance:model.appearance,radius:22)}}.padding(28)}}
}
