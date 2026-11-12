import SwiftUI

enum HarborNoticePolicy { static let lifetime=3.5 }
private struct HarborPerformanceKey:EnvironmentKey{static let defaultValue=false}
extension EnvironmentValues{var harborPerformanceMode:Bool{get{self[HarborPerformanceKey.self]}set{self[HarborPerformanceKey.self]=newValue}}}
struct HarborMotionPolicy {
    let performance:Bool,reduceMotion:Bool,systemReduceMotion:Bool
    var staticEffects:Bool{performance || reduceMotion || systemReduceMotion}
    var transitions:Bool{!performance}
    var interactiveGlass:Bool{!staticEffects}
}

struct HarborActivityIndicator:View {
    @Environment(\.harborPerformanceMode) private var performance
    var body:some View{Group{if performance{Image(systemName:"hourglass").foregroundStyle(.secondary).accessibilityLabel("处理中")}else{ProgressView()}}}
}
