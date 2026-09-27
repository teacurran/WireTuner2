import AppKit
import Observation
import SwiftUI
import WTSync

/// The rest of the sync indicator (IO-001, IO-002; saving.adoc, "The sync indicator", "Closing and
/// quitting with changes waiting"): VoiceOver hears a window's state when it changes -- once per
/// change of state, never for a count ticking -- the menu:Window[Sync Activity] window lists what
/// is still in flight across documents, open or closed, and the library window badges each
/// document with its session's state.

/// Announces a window's sync state to VoiceOver when its kind changes.
@MainActor
final class SyncAnnouncer {
    /// The last kind announced (the case, without its count).
    private(set) var announced: String?
    /// Posts the announcement; replaceable in tests.
    var post: @MainActor (String) -> Void

    init(element: AnyObject?, post: (@MainActor (String) -> Void)? = nil) {
        self.post = post ?? { [weak element] text in
            NSAccessibility.post(element: element ?? NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// The state's case, without its payload: `offline(3)` and `offline(4)` are one kind.
    static func kind(_ state: SyncState) -> String {
        Mirror(reflecting: state).children.first?.label ?? state.description
    }

    /// Announces `state` when its kind differs from the last one announced.  The first state seen
    /// is the one the window opened with and is not announced.
    func update(_ state: SyncState) {
        let kind = Self.kind(state)
        defer { announced = kind }
        guard let announced, announced != kind else { return }
        post(state.description)
    }
}

/// One row of the Sync Activity window.
struct SyncActivityRow: Identifiable, Equatable {
    let id: String
    let title: String
    let state: SyncState
    /// "Window closed" for a background session, "Started at launch" for a headless upload.
    let note: String?

    var detail: String { WaitingDocument(id: id, title: title, state: state).detail }
}

/// menu:Window[Sync Activity]: every document whose session has something in flight or waiting
/// -- open windows, closed windows still uploading and the launch's headless uploads.
@MainActor
@Observable
final class SyncActivityModel {
    @ObservationIgnored let sessions: DocumentSessions

    init(sessions: DocumentSessions) {
        self.sessions = sessions
    }

    var rows: [SyncActivityRow] {
        func active(_ state: SyncState) -> Bool { state != .saved && state != .opening }
        let open = sessions.sessions.values.filter { active($0.status.state) }
            .map { SyncActivityRow(id: $0.document.id, title: $0.document.title, state: $0.status.state, note: nil) }
        let closed = sessions.background.values
            .map { SyncActivityRow(id: $0.document.id, title: $0.document.title, state: $0.status.state, note: "Window closed") }
        let launch = sessions.headless.values.filter { active($0.state) }
            .map { SyncActivityRow(id: $0.documentID, title: $0.title, state: $0.state, note: "Started at launch") }
        return (open + closed + launch).sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
}

struct SyncActivityView: View {
    let model: SyncActivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.rows.isEmpty {
                Text("Everything has reached the cloud.").foregroundStyle(.secondary).accessibilityIdentifier("syncActivity.empty")
            }
            List(model.rows) { row in
                HStack {
                    Image(systemName: row.state.symbolName).foregroundStyle(row.state.needsAttention ? .orange : .secondary)
                    VStack(alignment: .leading) {
                        Text(row.title)
                        Text([row.detail, row.note].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("syncActivity.row.\(row.id)")
            }
        }
        .padding(12)
        .frame(minWidth: 360, minHeight: 200)
    }
}

/// Opens the Sync Activity window, one at a time.
@MainActor
final class SyncActivityWindow {
    static let id: CommandID = "window.syncActivity"
    let model: SyncActivityModel
    private(set) var window: NSWindow?

    init(sessions: DocumentSessions) {
        model = SyncActivityModel(sessions: sessions)
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let made = NSWindow(contentViewController: NSHostingController(rootView: SyncActivityView(model: model)))
        made.title = "Sync Activity"
        made.identifier = NSUserInterfaceItemIdentifier("sync-activity")
        made.isReleasedWhenClosed = false
        made.setFrameAutosaveName("SyncActivity")
        window = made
        made.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }

    var command: Command {
        Command(id: Self.id, title: "Sync Activity", menu: MenuPath(StandardCommands.Menu.window, section: StandardCommands.Section.windowPanels),
                keywords: ["sync", "upload", "cloud", "offline"], action: .perform { [weak self] in self?.show() })
    }
}

/// The library window's state badge of a document with a running session: nothing when it is
/// saved (the *Available offline* badge says the rest).
enum LibrarySyncBadge {
    static func badge(_ state: SyncState?) -> (symbol: String, help: String)? {
        guard let state, state != .saved, state != .opening else { return nil }
        return (state.symbolName, state.description)
    }
}
