import AppKit
import SwiftUI

struct HarborContributor: Decodable, Identifiable {
    let id: String
    let name: String
    let avatar: String
    let contributions: [String]
    let description: String?
    let role: String?
    let category: String?
    let url: URL?
}

enum HarborContributions {
    static let entries: [HarborContributor] = {
        guard let data = try? Data(contentsOf: NativePaths.resources.appendingPathComponent("Contributors/contributors.json")),
              let items = try? JSONDecoder().decode([HarborContributor].self, from: data) else { return [] }
        return items
    }()
}

private struct ContributorAvatar: View {
    let entry: HarborContributor
    var body: some View {
        Group {
            if let image = NSImage(contentsOf: NativePaths.resources.appendingPathComponent("Contributors/" + entry.avatar)) {
                Image(nsImage: image).resizable().scaledToFill().scaleEffect(entry.id == "flowerbank" ? 1.17 : 1)
            } else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit() }
        }.frame(width: 52, height: 52).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct ContributorsPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            ForEach(HarborContributions.entries.filter { $0.category == nil }) { entry in
                HStack(alignment: .top, spacing: 16) {
                    ContributorAvatar(entry: entry)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(entry.name).font(.system(size: 14, weight: .semibold))
                        if let role = entry.role { Text(role).font(.system(size: 12, weight: .medium)).harborSecondaryText() }
                        ForEach(entry.contributions, id: \.self) { contribution in
                            Text(contribution).font(.system(size: 11)).harborSecondaryText().fixedSize(horizontal: false, vertical: true)
                        }
                        if let url = entry.url { Link("GitHub 主页", destination: url).buttonStyle(HarborButtonStyle()) }
                    }
                }
            }
        }
    }
}

struct DevelopersPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            let developers = HarborContributions.entries.filter { $0.category == "author" || $0.category == "developer" }
            ForEach(developers) { entry in
                HStack(alignment: .top, spacing: 16) {
                    ContributorAvatar(entry: entry)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.name).font(.system(size: 16, weight: .semibold))
                        if let role = entry.role { Text(role).font(.system(size: 12, weight: .medium)) }
                        if let description = entry.description {
                            Text(description).font(.system(size: 12)).harborSecondaryText()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let url = entry.url {
                            Link("GitHub 主页", destination: url).buttonStyle(HarborButtonStyle())
                                .accessibilityHint("打开 \(entry.name) 的 GitHub 个人主页")
                        }
                    }
                }
            }
        }
    }
}
