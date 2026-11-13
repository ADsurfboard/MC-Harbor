import SwiftUI

private struct PhoneCredit: Decodable, Identifiable {
    let id: String
    let name: String
    let avatar: String
    let contributions: [String]
    let role: String?
    let category: String?
    let url: URL?
}

struct HarborPeopleView: View {
    private var entries: [PhoneCredit] {
        let bundle = Bundle(for: HarborRootFactory.self)
        guard let url = bundle.url(forResource: "contributors", withExtension: "json"),
              let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([PhoneCredit].self, from: data) else { return [] }
        return entries
    }
    var body: some View {
        List {
            Section("项目作者") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ADsurfboard").font(.headline)
                    Text("项目发起人、主要作者与维护负责人。macOS、iOS 及其他非 Windows 版本继续由作者独立开发与维护。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("作者 GitHub", destination: URL(string: "https://github.com/ADsurfboard")!).frame(minHeight: 44)
                }.padding(.vertical, 8)
            }
            Section("平台开发者") {
                ForEach(entries.filter { $0.category == "developer" }) { entry in
                    person(entry, includeContributions: false)
                }
            }
            Section("贡献名单") {
                ForEach(entries) { entry in person(entry, includeContributions: true) }
            }
        }.navigationTitle("开发者与贡献").navigationBarTitleDisplayMode(.inline)
    }
    private func person(_ entry: PhoneCredit, includeContributions: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let image = HarborArtwork.image((entry.avatar as NSString).deletingPathExtension, pixels: 160) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(Circle()).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.name).font(.headline)
                if let role = entry.role { Text(role).font(.subheadline).foregroundStyle(.secondary) }
                if includeContributions {
                    ForEach(entry.contributions, id: \.self) { Text($0).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                }
                if let url = entry.url { Link("GitHub 主页", destination: url).frame(minHeight: 44).contentShape(Rectangle()) }
            }
        }.padding(.vertical, 10)
    }
}
