import AppKit
import Observation
import SwiftUI

/// What the title bar and the status bar's cloud glyph show about syncing (workspace.adoc,
/// "The document window"; saving.adoc).
enum SyncState: Equatable, Sendable {
    case synced
    case syncing
    /// Offline with this many local changes waiting to upload.
    case offline(waiting: Int)
    /// A merge needs the user's review (reconcile.adoc).
    case reviewNeeded

    /// "Syncing", "Offline (12 changes waiting)", "Review needed"; nil when synced.
    var titleSuffix: String? {
        switch self {
        case .synced: nil
        case .syncing: "Syncing"
        case let .offline(waiting): waiting == 1 ? "Offline (1 change waiting)" : "Offline (\(waiting) changes waiting)"
        case .reviewNeeded: "Review needed"
        }
    }

    var symbolName: String {
        switch self {
        case .synced: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .offline: "icloud.slash"
        case .reviewNeeded: "exclamationmark.icloud"
        }
    }

    var label: String { titleSuffix ?? "Synced" }
}

/// "<name>", "<name> — Syncing", "<name> — Offline (12 changes waiting)", "<name> — Review
/// needed" (BASIC-003).  There is no unsaved marker: every change is kept.
enum DocumentTitle {
    static func format(name: String, state: SyncState) -> String {
        state.titleSuffix.map { "\(name) — \($0)" } ?? name
    }
}

/// Where a window reads its document's sync state.  `WTSync`'s sync client conforms when
/// SYNC-001 lands; until then `StubSyncStatus` holds whatever it is told (always *synced* in
/// the app; any state in tests and the harness).
@MainActor
protocol SyncStatusProviding: AnyObject {
    var state: SyncState { get }
    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID
    func stopObserving(_ token: UUID)
}

@MainActor
@Observable
final class StubSyncStatus: SyncStatusProviding {
    var state: SyncState {
        didSet { if state != oldValue { for observer in observers.values { observer() } } }
    }

    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    init(state: SyncState = .synced) {
        self.state = state
    }

    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ token: UUID) {
        observers[token] = nil
    }
}

/// What the status bar's SwiftUI hosts show: the sync glyph and the collaborators' avatars.
@MainActor
@Observable
final class StatusBarModel {
    var syncState: SyncState = .synced
    var participants: [RemoteParticipant] = []
    @ObservationIgnored var onParticipant: @MainActor (RemoteParticipant) -> Void = { _ in }

    init() {}
}

/// The cloud glyph (workspace.adoc, "Sync indicator").
struct SyncIndicatorView: View {
    let model: StatusBarModel

    var body: some View {
        Image(systemName: model.syncState.symbolName)
            .foregroundStyle(model.syncState == .reviewNeeded ? SwiftUI.Color.orange : SwiftUI.Color.secondary)
            .help(model.syncState.label)
            .accessibilityLabel(model.syncState.label)
            .accessibilityIdentifier("status.sync")
    }
}

/// The avatars of everyone with the document open; clicking one jumps to them (PRES epic).
struct AvatarStripView: View {
    let model: StatusBarModel

    var body: some View {
        HStack(spacing: -4) {
            ForEach(model.participants) { participant in
                let color = participant.color
                Button { model.onParticipant(participant) } label: {
                    Text(Self.initials(participant.name))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(SwiftUI.Color(red: color.red, green: color.green, blue: color.blue)))
                }
                .buttonStyle(.plain)
                .help(participant.name)
                .accessibilityIdentifier("status.avatar.\(participant.id)")
            }
        }
        .accessibilityIdentifier("status.avatars")
    }

    /// "Priya Shah" → "PS"; one word → its first letter.
    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// A tab's collaborator dots (`NSWindowTab.accessoryView`): one small dot per person with the
/// document open, in their presence colour.
@MainActor
final class TabPresenceDotsView: NSView {
    static let dotSize: CGFloat = 6

    private(set) var colors: [CGColor] = []

    init(participants: [RemoteParticipant]) {
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(max(participants.count, 1)) * (Self.dotSize + 2), height: Self.dotSize))
        update(participants)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("tab.presence")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabPresenceDotsView is built in code")
    }

    func update(_ participants: [RemoteParticipant]) {
        colors = participants.map { CGColor(red: $0.color.red, green: $0.color.green, blue: $0.color.blue, alpha: 1) }
        setAccessibilityValue("\(participants.count)")
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(max(colors.count, 1)) * (Self.dotSize + 2), height: Self.dotSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: CGFloat(index) * (Self.dotSize + 2), y: 0, width: Self.dotSize, height: Self.dotSize))
        }
    }
}
