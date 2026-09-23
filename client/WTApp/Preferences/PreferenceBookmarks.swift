import AppKit
import UniformTypeIdentifiers

/// What a chooser preference picks (preferences.adoc; BASIC-022).
enum PreferenceChooserKind: Equatable, Sendable {
    case application
    case folder
    case file(types: [UTType])

    /// The chooser keys of the catalog and what each picks.
    static func kind(for id: String) -> PreferenceChooserKind {
        switch id {
        case PreferenceCatalog.Object.externalEditor.id, PreferenceCatalog.Export.previewBrowser.id: .application
        case PreferenceCatalog.Document.missingLinksFolder.id: .folder
        case PreferenceCatalog.Document.newTemplate.id: .file(types: [UTType(filenameExtension: "wiretuner") ?? .data])
        default: .file(types: [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data])
        }
    }
}

/// The files, folders and applications the chooser preferences name, kept as security-scoped
/// bookmarks so the sandboxed app can reach them again after relaunch.  The preference itself
/// stores the path (what the form shows and what syncs); the bookmark is local
/// (`wt.bookmarks.<id>` in the same defaults).  An empty preference -- never chosen, or
/// restored to its default -- resolves to nothing.
@MainActor
struct PreferenceBookmarks {
    static let prefix = "wt.bookmarks."

    let store: PreferenceStore

    var defaults: UserDefaults { store.defaults }

    static func defaultsKey(for id: String) -> String { prefix + id }

    /// Remembers `url` for the chooser `key`: its bookmark, and its path as the value.
    func choose(_ url: URL, for key: AnyPreferenceKey) {
        defaults.set(Self.bookmark(for: url), forKey: Self.defaultsKey(for: key.id))
        store.set(.string(url.path), for: key)
    }

    /// Forgets the choice (the field's Clear button).
    func clear(_ key: AnyPreferenceKey) {
        defaults.removeObject(forKey: Self.defaultsKey(for: key.id))
        store.set(.string(""), for: key)
    }

    /// The chosen URL, from the bookmark; a stale bookmark is renewed.  Nil when nothing is
    /// chosen or the item is gone.
    func url(for key: AnyPreferenceKey) -> URL? {
        guard case let .string(path) = store.value(for: key), !path.isEmpty else { return nil }
        guard let data = defaults.data(forKey: Self.defaultsKey(for: key.id)) else { return URL(filePath: path) }
        var stale = false
        guard let url = Self.resolve(data, stale: &stale) else { return nil }
        if stale { defaults.set(Self.bookmark(for: url), forKey: Self.defaultsKey(for: key.id)) }
        return url
    }

    /// An app-scoped security bookmark where the sandbox grants one, else a plain bookmark.
    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    static func resolve(_ data: Data, stale: inout Bool) -> URL? {
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// The open panel for `key`, configured for what it picks.
    static func openPanel(for key: AnyPreferenceKey) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = key.title
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        switch PreferenceChooserKind.kind(for: key.id) {
        case .application:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(filePath: "/Applications")
        case .folder:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        case let .file(types):
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = types
        }
        return panel
    }

    /// Runs the open panel for `key` and remembers the pick.  `run` is replaceable in tests.
    func runChooser(for key: AnyPreferenceKey, run: @MainActor (NSOpenPanel) -> URL? = PreferenceBookmarks.runModal) {
        guard let url = run(Self.openPanel(for: key)) else { return }
        choose(url, for: key)
    }

    static func runModal(_ panel: NSOpenPanel) -> URL? {
        panel.runModal() == .OK ? panel.url : nil
    }
}
