import SwiftUI

private struct PhoneCredit: Decodable, Identifiable {
    let id: String
    let name: String
    let avatar: String
    let contributions: [String]
    let role: String?
    let description: String?
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
            Section("开发人员") {
                ForEach(entries.filter { $0.category == "author" || $0.category == "developer" }) { entry in
                    person(entry)
                }
            }
            Section("贡献名单") {
                ForEach(entries.filter { $0.category == nil }) { entry in
                    person(entry)
                }
            }
        }.harborPageBackground().harborMotionPolicy()
            .navigationTitle("开发者与贡献").navigationBarTitleDisplayMode(.inline)
    }
    private func person(_ entry: PhoneCredit) -> some View {
        let filename = entry.avatar as NSString
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if let image = HarborArtwork.image(filename.deletingPathExtension, pixels: 160, fileExtension: filename.pathExtension) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }.frame(width: 52, height: 52).clipShape(Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.name).font(.headline)
                if let role = entry.role { Text(role).font(.subheadline).foregroundStyle(.secondary) }
                if let description = entry.description {
                    Text(description).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entry.contributions, id: \.self) { Text($0).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                if let url = entry.url {
                    Link("GitHub 主页", destination: url)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityHint("打开 \(entry.name) 的 GitHub 个人主页")
                }
            }
        }.padding(.vertical, 10)
    }
}
