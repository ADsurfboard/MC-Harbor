import AppKit
import SwiftUI

/// Uses production views against the generated NBT fixture; never uses player accounts or worlds.
@main struct WorldEditorPreviewApp:App {
    @StateObject private var model:LauncherModel
    init(){
        let root=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("qa-world-ui")
        setenv("SHENGGAN_DATA_DIR",root.appendingPathComponent("data").path,1)
        setenv("SHENGGAN_SKIP_INTRO","1",1)
        let value=LauncherModel();let run=root.appendingPathComponent("game/versions/World Editor QA")
        let game=GameInstance(id:"World Editor QA",version:"1.20.1",loader:"Forge",directory:run.path,runDirectory:run.path,iconPath:nil,modified:Date())
        value.games=[game];value.preferences.gameRoot=root.appendingPathComponent("game").path;value.preferences.selectedGame=game.id
        value.inspectedGame=game
        if let world=LocalContent.read(run.appendingPathComponent("saves")).first{value.modal = .worldEditor(game,world)}
        _model=StateObject(wrappedValue:value)
    }
    var body:some Scene{WindowGroup("MC Harbor · 隔离验收"){LauncherRoot(model:model).frame(minWidth:1040,minHeight:700)}.defaultSize(width:1180,height:840).windowStyle(.hiddenTitleBar)}
}
