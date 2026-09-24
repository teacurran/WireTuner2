import CoreServices
import Foundation
import WTModel

/// The Scripts folder (scripting.adoc, "Where scripts live": `~/Library/Application
/// Support/WireTuner/Scripts/`): the `.js` files the Scripts menu lists, subfolders as submenus,
/// and `wiretuner.d.ts` with a README copied in on first launch so an external editor completes
/// and type-checks the `wt` API.
struct ScriptsFolder: Sendable {
    /// One script file: its path below the folder (the submenus, then the name).
    struct Entry: Hashable, Sendable {
        let url: URL
        /// Subfolder names, outermost first.
        let folders: [String]
        /// The menu title: the file name without `.js`.
        let title: String

        /// The stable command id (`script:<relative path>`).
        var commandID: CommandID { CommandID("script:" + (folders + [url.lastPathComponent]).joined(separator: "/")) }
    }

    static let readmeName = "README.txt"
    static let readme = """
    WireTuner Scripts

    Every .js file in this folder appears in the Scripts menu; subfolders become submenus.  Scripts
    run on the front document with the wt API, and each change they make is an ordinary, undoable
    document change.  wiretuner.d.ts describes the wt API for editors such as Visual Studio Code:
    add `/// <reference path="wiretuner.d.ts" />` at the top of a script for completion.

    Nothing here runs on its own: a script runs when you choose it from the Scripts menu, the
    command palette or a shortcut, or click Run in the Script Editor.
    """

    let url: URL

    /// `~/Library/Application Support/WireTuner/Scripts` (inside the app's container).
    static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(components: "WireTuner", "Scripts")
    }

    /// Creates the folder and writes `wiretuner.d.ts` (whenever it differs from this build's) and
    /// the README (when missing).  Returns whether the typings were written.
    @discardableResult
    func installTypings() throws -> Bool {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        let readme = url.appending(path: Self.readmeName)
        if !manager.fileExists(atPath: readme.path) { try Data(Self.readme.utf8).write(to: readme) }
        let typings = url.appending(path: ScriptTypings.fileName)
        let data = Data(ScriptTypings.declarations.utf8)
        guard (try? Data(contentsOf: typings)) != data else { return false }
        try data.write(to: typings, options: .atomic)
        return true
    }

    /// The `.js` files, subfolders included, sorted by path.
    func entries() -> [Entry] {
        let base = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [Entry] = []
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "js" {
            let components = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let folders = Array(components.dropFirst(base.count).dropLast())
            result.append(Entry(url: file, folders: folders, title: file.deletingPathExtension().lastPathComponent))
        }
        return result.sorted { ($0.folders + [$0.title]).joined(separator: "/") < ($1.folders + [$1.title]).joined(separator: "/") }
    }
}

/// Watches a folder tree with FSEvents and calls `onChange` on the main queue (a script added,
/// renamed or removed shows in the menu without relaunching).
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init?(url: URL, latency: TimeInterval = 0.3, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
