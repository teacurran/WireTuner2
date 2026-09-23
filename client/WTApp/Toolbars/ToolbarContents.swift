import Foundation

/// The buttons of every customized toolbar and the set menu:View[Toolbars] hid, as one value
/// (customizing.adoc, "Customizing toolbars").  A toolbar without an entry shows its factory
/// buttons; Reset Toolbars removes every entry.  Local to this Mac.
struct ToolbarContents: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = ToolbarContents.currentVersion
    /// Customized toolbars only.
    var items: [ToolbarID: [CommandID]] = [:]
    /// The toolbars menu:View[Toolbars] hid, to bring back the same set; empty while shown.
    var hiddenByViewMenu: [ToolbarID] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case version, items, hiddenByViewMenu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        let raw = try container.decodeIfPresent([String: [CommandID]].self, forKey: .items) ?? [:]
        items = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in ToolbarID(rawValue: key).map { ($0, value) } })
        hiddenByViewMenu = try container.decodeIfPresent([ToolbarID].self, forKey: .hiddenByViewMenu) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(Dictionary(uniqueKeysWithValues: items.map { ($0.rawValue, $1) }), forKey: .items)
        try container.encode(hiddenByViewMenu, forKey: .hiddenByViewMenu)
    }

    /// The toolbar's buttons: customized, else `defaults`.
    func items(_ toolbar: ToolbarID, defaults: [CommandID]) -> [CommandID] {
        items[toolbar] ?? defaults
    }

    /// Inserts `command` at `index` (clamped; the end when nil).  A button already on the
    /// toolbar moves there instead: a toolbar holds a command once.
    mutating func insert(_ command: CommandID, into toolbar: ToolbarID, at index: Int?, defaults: [CommandID]) {
        var list = items(toolbar, defaults: defaults)
        var target = index ?? list.count
        if let existing = list.firstIndex(of: command) {
            list.remove(at: existing)
            if existing < target { target -= 1 }
        }
        list.insert(command, at: min(max(target, 0), list.count))
        items[toolbar] = list
    }

    mutating func remove(_ command: CommandID, from toolbar: ToolbarID, defaults: [CommandID]) {
        var list = items(toolbar, defaults: defaults)
        guard let index = list.firstIndex(of: command) else { return }
        list.remove(at: index)
        items[toolbar] = list
    }
}

/// Reads and writes `ToolbarContents` as `Application Support/WireTuner/Toolbars.json`.
struct ToolbarStore: Sendable {
    static let fileName = "Toolbars.json"

    let url: URL

    static var defaultURL: URL {
        PanelLayoutStore.defaultURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// Nil when nothing was saved or the file is unreadable.
    func load() -> ToolbarContents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ToolbarContents.self, from: data)
    }

    func save(_ contents: ToolbarContents) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(contents).write(to: url, options: .atomic)
    }
}
