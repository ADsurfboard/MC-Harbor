import AppKit
import SwiftUI

struct HarborContributor:Decodable,Identifiable {let id:String;let name:String;let avatar:String;let contributions:[String]}
enum HarborContributions {
    static var entries:[HarborContributor]{guard let data=try? Data(contentsOf:NativePaths.resources.appendingPathComponent("Contributors/contributors.json")),let items=try? JSONDecoder().decode([HarborContributor].self,from:data) else{return []};return items}
}
struct ContributorsPanel:View {
    var body:some View{VStack(alignment:.leading,spacing:23){ForEach(HarborContributions.entries){entry in HStack(alignment:.top,spacing:16){Group{if let image=NSImage(contentsOf:NativePaths.resources.appendingPathComponent("Contributors/"+entry.avatar)){Image(nsImage:image).resizable().scaledToFill().scaleEffect(entry.id=="flowerbank" ? 1.17:1)}else{Image(systemName:"person.crop.circle.fill").resizable().scaledToFit()}}.frame(width:52,height:52).clipShape(Circle());VStack(alignment:.leading,spacing:9){Text(entry.name).font(.system(size:14,weight:.semibold));ForEach(entry.contributions,id:\.self){Text($0).font(.system(size:11)).harborSecondaryText().fixedSize(horizontal:false,vertical:true)}}}}}}
}
