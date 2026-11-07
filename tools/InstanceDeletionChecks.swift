import Foundation
struct GameInstance {let id:String;let directory:String}
@main struct InstanceDeletionChecks {
 static func main()throws{
    let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("harbor-delete-"+UUID().uuidString),versions=root.appendingPathComponent("versions")
    defer{try? fm.removeItem(at:root)}
    try fm.createDirectory(at:versions,withIntermediateDirectories:true)
    let one=versions.appendingPathComponent("One"),two=versions.appendingPathComponent("Two"),shared=root.appendingPathComponent("shared-save.txt")
    try fm.createDirectory(at:one,withIntermediateDirectories:true);try fm.createDirectory(at:two,withIntermediateDirectories:true);try Data("saved".utf8).write(to:shared)
    let game=GameInstance(id:"One",directory:one.path)
    try Data(#"{"inheritsFrom":"One"}"#.utf8).write(to:two.appendingPathComponent("Two.json"))
    do{_ = try InstanceDeletion.validatedDirectory(game,root:root.path);fatalError("dependent accepted")}catch{print("PASS dependent-instance-protected")}
    try fm.removeItem(at:two.appendingPathComponent("Two.json"))
    do{_ = try InstanceDeletion.validatedDirectory(GameInstance(id:"One",directory:root.path),root:root.path);fatalError("outside accepted")}catch{print("PASS outside-library-protected")}
    let link=versions.appendingPathComponent("Linked");try fm.createSymbolicLink(at:link,withDestinationURL:one)
    do{_ = try InstanceDeletion.validatedDirectory(GameInstance(id:"Linked",directory:link.path),root:root.path);fatalError("symlink accepted")}catch{print("PASS symlink-protected")}
    let trash=try InstanceDeletion.moveToTrash(game,root:root.path)
    guard !fm.fileExists(atPath:one.path),fm.fileExists(atPath:shared.path),fm.fileExists(atPath:two.path),let trash,fm.fileExists(atPath:trash.path) else{fatalError("trash or isolation failed")}
    try fm.removeItem(at:trash);print("PASS instance-trash-and-shared-data-protected")
 }
}
