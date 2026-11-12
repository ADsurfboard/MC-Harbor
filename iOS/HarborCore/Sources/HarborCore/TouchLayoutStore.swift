import Foundation

public actor TouchLayoutStore {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func layouts() throws -> [TouchLayout] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url), let layout = try? TouchLayout.decode(data) else { return nil }
            return layout
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func save(_ input: TouchLayout) throws {
        var layout = input; try layout.sanitize()
        let data = try JSONEncoder().encode(layout)
        try data.write(to: directory.appendingPathComponent(layout.id.uuidString).appendingPathExtension("json"), options: .atomic)
    }
    public func importLayout(_ data: Data) throws -> TouchLayout {
        var layout = try TouchLayout.decode(data)
        layout.id = UUID() // An import never silently overwrites a player's existing profile.
        try save(layout)
        return layout
    }
    public func exportLayout(_ layout: TouchLayout) throws -> Data {
        var copy = layout; try copy.sanitize()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(copy)
    }
    public func delete(_ id: UUID) throws {
        let file = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
