import AppKit
import Foundation
import WTGeometry
import WTInterchange
import WTModel

/// The app's half of *Add to WireTuner Document* (IMG-026; importing.adoc, "From another app's
/// Share menu"): the share extension writes the shared items into the app group's
/// `Inbox/<uuid>/` and opens `wiretuner-share://inbox/<uuid>?app=<name>[&option=1]`; the app
/// drains that folder into the frontmost document at the centre of the view, stacked by the
/// *Keep both offset*, one change per item labelled "Add from <app>" -- or, with no document open
/// or kbd:[Option] held, into a new document -- then deletes the folder.  Folders a crash left
/// behind are removed at launch.
@MainActor
final class ShareInbox {
    static let scheme = "wiretuner-share"
    static let appGroup = "group.com.villagecompute.wiretuner"
    /// How old an inbox folder must be to count as left behind.
    static let staleAge: TimeInterval = 24 * 3600

    /// The inbox folder: the app group container's `Inbox` (Application Support without one).
    var root: URL
    /// The frontmost document window.
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// Places files in a window; the app's is the import path.
    var place: @MainActor ([URL], DocumentWindowController, String) async -> Int = { _, _, _ in 0 }
    /// Opens a new document (the chooser's *New Document*) and returns its window.
    var newDocument: @MainActor () -> DocumentWindowController? = { nil }
    var now: @MainActor () -> Date = { Date() }

    init(root: URL = ShareInbox.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group.appending(path: "Inbox")
        }
        return URL.applicationSupportDirectory.appending(path: "WireTuner").appending(path: "Inbox")
    }

    /// A hand-off URL's inbox id, source app and whether kbd:[Option] was held; nil for any
    /// other URL.
    static func parse(_ url: URL) -> (id: String, app: String, option: Bool)? {
        guard url.scheme == scheme, url.host() == "inbox" else { return nil }
        let id = url.lastPathComponent
        guard !id.isEmpty, id != "/", UUID(uuidString: id) != nil else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let app = query.first { $0.name == "app" }?.value ?? "another app"
        let option = query.first { $0.name == "option" }?.value == "1"
        return (id, app, option)
    }

    /// Whether `url` is a share hand-off (the app then drains it).
    func opens(_ url: URL) -> Bool {
        guard Self.parse(url) != nil else { return false }
        Task { await drain(url) }
        return true
    }

    /// The items of `url`'s inbox folder, placed; returns how many.
    @discardableResult
    func drain(_ url: URL) async -> Int {
        guard let (id, app, option) = Self.parse(url) else { return 0 }
        let folder = root.appending(path: id)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        defer { try? FileManager.default.removeItem(at: folder) }
        guard !files.isEmpty else { return 0 }
        let target = option ? newDocument() : (window() ?? newDocument())
        guard let target else { return 0 }
        return await place(files, target, app)
    }

    /// Removes inbox folders older than a day.
    func removeStale() {
        let limit = now().addingTimeInterval(-Self.staleAge)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < limit { try? FileManager.default.removeItem(at: folder) }
        }
    }

    /// The app's placing: each file converted with its format's remembered options, its blobs
    /// stored, and placed centred in the view (stacked by the *Keep both offset*) as one change
    /// "Add from <app>".
    static func place(_ urls: [URL], on window: DocumentWindowController, from app: String, imports: ImportController) async -> Int {
        let document = window.documentHandle
        let context = imports.context
        var placed = 0
        for (index, url) in urls.enumerated() {
            do {
                let scene = try await imports.convert(url, context: context)
                let poster = try await imports.storeBlobs(of: scene, for: document)
                let offset = Double(index) * context.keepBothOffset
                let origin = ImportController.centred(scene.bounds, in: window.objectEditing.visibleCenter() ?? Point(x: 0, y: 0), offset: offset)
                let command = CompositeCommand("Add from \(app)", [PlaceImportedScene(scene, placement: .at(origin), layer: window.objectEditing.activeLayer, poster: poster)])
                if await window.objectEditing.perform(command).value != nil { placed += 1 }
            } catch {
                window.statusBar.show(message: "“\(url.lastPathComponent)” could not be added: \(error.localizedDescription)")
            }
        }
        return placed
    }
}
