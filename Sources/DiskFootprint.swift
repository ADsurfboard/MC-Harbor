import Foundation
import SwiftUI

struct InstanceFootprint:Sendable {var logical:Int64=0;var allocated:Int64=0;var files=0;var unreadable=0;var shared=false}
enum DiskFootprint {
    static func measure(_ game:GameInstance)throws->InstanceFootprint {
        let fm=FileManager.default,run=URL(fileURLWithPath:game.runDirectory).standardizedFileURL,instance=URL(fileURLWithPath:game.directory).standardizedFileURL
        var result=InstanceFootprint(),seen:Set<AnyHashable>=[]
        var roots=[instance]
        if run != instance {
            if instance.path.hasPrefix(run.path+"/") {
                result.shared=true
                roots += (try fm.contentsOfDirectory(at:run,includingPropertiesForKeys:nil)).filter{!["versions","assets","libraries","runtime","runtimes","java"].contains($0.lastPathComponent)}
            }else if !run.path.hasPrefix(instance.path+"/"){roots.append(run)}
        }
        let keys:Set<URLResourceKey>=[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.fileAllocatedSizeKey,.totalFileAllocatedSizeKey,.fileResourceIdentifierKey]
        func add(_ url:URL){do{let value=try url.resourceValues(forKeys:keys);guard value.isRegularFile==true,value.isSymbolicLink != true else{return};if let identity=value.fileResourceIdentifier as? AnyHashable{guard seen.insert(identity).inserted else{return}};result.logical += Int64(value.fileSize ?? 0);result.allocated += Int64(value.totalFileAllocatedSize ?? value.fileAllocatedSize ?? value.fileSize ?? 0);result.files += 1}catch{result.unreadable += 1}}
        for root in roots {try Task.checkCancellation();let value=try? root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);if value?.isSymbolicLink==true{continue};if value?.isDirectory != true{add(root);continue};guard let enumerator=fm.enumerator(at:root,includingPropertiesForKeys:Array(keys),options:[],errorHandler:{_,_ in result.unreadable += 1;return true}) else{result.unreadable += 1;continue};var count=0;for case let url as URL in enumerator{count += 1;if count%128==0{try Task.checkCancellation()};if (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true{enumerator.skipDescendants();continue};add(url)}}
        return result
    }
}
struct InstanceSpaceView:View {
    let game:GameInstance
    @State private var result:InstanceFootprint?
    @State private var revision=0
    @State private var error=""
    var body:some View{VStack(alignment:.leading,spacing:8){HStack{Text("占用空间");Spacer();if let result{Text(ByteCountFormatter.string(fromByteCount:result.allocated,countStyle:.file)).fontWeight(.medium)}else if error.isEmpty{ProgressView().controlSize(.mini)};Button{result=nil;revision += 1}label:{Image(systemName:"arrow.clockwise")}.help("重新统计实例文件")};if let result{Text("文件大小 \(ByteCountFormatter.string(fromByteCount:result.logical,countStyle:.file)) · 磁盘分配 \(ByteCountFormatter.string(fromByteCount:result.allocated,countStyle:.file)) · \(result.files) 个文件"+(result.shared ? "\n含此非隔离实例使用的共享游戏数据，不计其他版本与公共下载缓存。":"")+(result.unreadable>0 ? "\n\(result.unreadable) 项无法读取，统计未覆盖这些项目。":"")).font(.system(size:10)).foregroundStyle(.secondary)};if !error.isEmpty{Text(error).font(.system(size:10)).foregroundStyle(.secondary)}}.task(id:game.id+String(revision)){error="";let task=Task.detached(priority:.utility){try DiskFootprint.measure(game)};do{let value=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()});try Task.checkCancellation();result=value}catch{if !Task.isCancelled{self.error=error.localizedDescription}}}}
}
