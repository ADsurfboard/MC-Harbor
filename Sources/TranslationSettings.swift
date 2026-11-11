import SwiftUI
import AppKit

struct TranslationSettingsPanel:View {
    @ObservedObject var model:LauncherModel
    @State private var provider=DomesticTranslation.provider
    @State private var endpoint=DomesticTranslation.aliEndpoint
    @State private var key=""
    @State private var message=""
    @State private var test=""
    @State private var remember=KeychainStore.remembersSession
    @State private var testing=false
    var body:some View{VStack(alignment:.leading,spacing:14){
        Text("翻译与账号授权").font(.system(size:17,weight:.semibold))
        Picker("在线翻译",selection:$provider){Text("B站 Index-Translate（国内，无需密钥）").tag("bilibili");Text("阿里云 Qwen-MT（自备密钥）").tag("aliyun")}.harborOnChange(of:provider){_,value in DomesticTranslation.provider=value}
        Text("先读取资源内中文与社区译库；剩余文本使用所选服务。下载来源仍可单独选择自动、官方优先或国内镜像优先。模组语言文件与任务文本只在你执行在线汉化时发送；账号令牌不发送给翻译服务。").font(.system(size:11)).harborSecondaryText()
        if provider=="aliyun"{TextField("阿里云北京地域兼容接口完整地址",text:$endpoint).textFieldStyle(.roundedBorder);SecureField("API Key（留空保留已保存密钥）",text:$key).textFieldStyle(.roundedBorder);HStack{Button("保存阿里翻译设置"){do{try DomesticTranslation.configureAli(endpoint:endpoint,key:key);key="";message="设置已保存，密钥仅保存在本机钥匙串"}catch{message=error.localizedDescription}};Button("删除密钥",role:.destructive){DomesticTranslation.removeAliKey();message="密钥已删除"}}.buttonStyle(HarborButtonStyle());Text("阿里云可能按其套餐计费。请使用自己账号对应地域的接口与密钥。").font(.system(size:10)).harborSecondaryText()}
        HStack{Button(testing ? "检测中…":"测试翻译"){testing=true;Task{defer{testing=false};do{test=try await DomesticTranslation.query("Improves performance and reduces memory usage.",toChinese:true)}catch{test=error.localizedDescription}}}.buttonStyle(HarborButtonStyle()).disabled(testing);Text(test).font(.system(size:11)).textSelection(.enabled)}
        if !message.isEmpty{Text(message).font(.system(size:11)).textSelection(.enabled)}
        Divider().opacity(0.3)
        Toggle("本次运行记住已授权的账号凭据",isOn:$remember).harborOnChange(of:remember){_,value in UserDefaults.standard.set(value,forKey:"harbor.rememberCredentials");if !value{KeychainStore.clearSession()}}
        Text("首次需要凭据时由 macOS 控制是否询问。授权成功后可在本次运行内复用，退出即清空；不会把令牌写入普通配置。系统弹窗可选择“始终允许”，但应用签名变化或钥匙串锁定后，macOS 仍可能重新确认。").font(.system(size:11)).harborSecondaryText()
    }.padding(24).frame(maxWidth:.infinity,alignment:.leading).harborGlass(appearance:model.appearance,radius:24)}
}
