import Foundation

/// Reads and writes the current layout as JSON.  Default location:
/// `~/Library/Application Support/WireTuner/PanelLayout.json` (inside the app's sandbox
/// container when sandboxed).  Named layouts (BASIC-030) get their own files beside it.
struct PanelLayoutStore: Sendable {
    enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
    }

    static let directoryName = "WireTuner"
    static let fileName = "PanelLayout.json"

    let url: URL

    init(url: URL) {
        self.url = url
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: directoryName).appending(path: fileName)
    }

    /// `nil` when no layout has been saved yet.
    func load() throws -> PanelLayout? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let layout = try JSONDecoder().decode(PanelLayout.self, from: Data(contentsOf: url))
        guard layout.version == PanelLayout.currentVersion else { throw Failure.unsupportedVersion(layout.version) }
        return layout
    }

    func save(_ layout: PanelLayout) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: url, options: .atomic)
    }
}
