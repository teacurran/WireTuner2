import AppKit
import WTCRDT
import WTModel

/// The read-only window of a version (history.adoc, "Viewing a version"; COLLAB-022): the
/// document as it was at a row of the timeline, titled "Catalogue — 'Client review 2'
/// (read-only)", with a bar above the canvas offering btn:[Restore], btn:[Restore as Copy…],
/// btn:[Compare with Current] and Inspect mode.  Its document lives in memory and every command is
/// made inert, so nothing done in it can become a change; it is private and never synced, and it
/// is not one of the document windows a relaunch reopens.
@MainActor
final class VersionWindows {
    static let shared = VersionWindows()

    struct Actions {
        var restore: @MainActor () -> Void = {}
        var restoreAsCopy: @MainActor () -> Void = {}
        var compare: @MainActor () -> Void = {}
    }

    /// One open version window and what its bar does.
    @MainActor
    final class Entry {
        let window: DocumentWindowController
        let actions: Actions
        var inspect: InspectModeController?
        var bar: [UUID: @MainActor () -> Void] = [:]
        var closing: NSObjectProtocol?

        init(window: DocumentWindowController, actions: Actions) {
            self.window = window
            self.actions = actions
        }
    }

    private(set) var entries: [Entry] = []

    init() {}

    static func title(document: String, version: String) -> String { "\(document) — ‘\(version)’ (read-only)" }

    /// Opens `state` read-only.
    @discardableResult
    func open(_ state: EngineState, document: String, version: String, environment: DocumentEnvironment, actions: Actions, show: Bool = true) -> DocumentWindowController {
        let model = WTModel.Document(memory: DocumentCore(state: state, replica: UInt64.random(in: 1...UInt64.max)))
        let handle = DocumentHandle(id: "version-\(UUID().uuidString)", title: Self.title(document: document, version: version), model: model)
        let window = DocumentWindowController(document: handle, environment: environment)
        // After the window's own transform (which it installs): nothing passes.
        handle.commandTransform = { InertCommand(label: $0.label) }
        let entry = Entry(window: window, actions: actions)
        let banner = window.collaboration.banner
        let items: [(String, String, @MainActor () -> Void)] = [
            ("Viewing \u{201C}\(version)\u{201D}, read-only", "Restore", actions.restore),
            ("", "Restore as Copy…", actions.restoreAsCopy),
            ("", "Compare with Current", actions.compare),
            ("", "Inspect", { [weak entry] in entry?.toggleInspect() }),
        ]
        for (text, button, action) in items {
            let id = UUID()
            entry.bar[id] = action
            banner.actions.append(BannerAction(id: id, text: text, button: button))
        }
        banner.onAction = { [weak entry] id in entry?.bar[id]?() }
        window.bannerDidChange()
        if let nswindow = window.window {
            entry.closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nswindow, queue: .main) { [weak self, weak entry] _ in
                MainActor.assumeIsolated { if let entry { self?.close(entry) } }
            }
        }
        entries.append(entry)
        if show { window.showWindow(nil) }
        return window
    }

    func close(_ entry: Entry) {
        if let closing = entry.closing { NotificationCenter.default.removeObserver(closing) }
        entries.removeAll { $0 === entry }
    }
}

@MainActor
extension VersionWindows.Entry {
    /// Inspect mode in the version window (its commands stay inert either way).
    func toggleInspect() {
        let inspect = self.inspect ?? InspectModeController(window: window)
        self.inspect = inspect
        inspect.toggle()
    }
}
