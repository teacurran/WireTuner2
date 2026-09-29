import AppKit
import Observation
import SwiftUI
import WTSync

/// The sync state machine of saving.adoc ("Sync state machine"), as `WTSync` publishes it; WTApp
/// never infers it from network state.
typealias SyncState = WTSync.SyncState

/// What the sync popover offers (saving.adoc, "The sync indicator").
enum SyncAction: String, CaseIterable, Sendable {
    case retryNow
    case reviewMerge
    case signIn
    case exportPackage
    /// Local mode instead of signing in (D-079), from *Sign in to sync*.
    case useWithoutAccount

    var title: String {
        switch self {
        case .retryNow: "Retry Now"
        case .reviewMerge: "Review Merge…"
        case .signIn: "Sign In…"
        // The package File > Save a Copy As… writes (D-079; `file.exportPackage`).
        case .exportPackage: "Save a Copy As…"
        case .useWithoutAccount: "Use Without an Account"
        }
    }
}

extension WTSync.SyncState {
    /// The toolbar symbol (saving.adoc, "Client").
    var symbolName: String {
        switch self {
        case .opening: "icloud"
        case .saved: "checkmark.icloud"
        // saving.adoc names `arrow.up.icloud`, which SF Symbols does not have.
        case .syncing, .uploadingBlobs, .uploadingBacklog: "icloud.and.arrow.up"
        case .offline: "icloud.slash"
        case .needsReview, .storageFull, .error: "exclamationmark.icloud"
        case .readOnly: "lock.icloud"
        case .needsSignIn: "person.icloud"
        // Local mode (D-079): kept on this Mac, nothing to sync.
        case .localOnly: "internaldrive"
        }
    }

    /// The subtitle and the indicator's label.
    var label: String { description }

    /// Drawn in the attention colour: the user has something to do.
    var needsAttention: Bool {
        switch self {
        case .needsReview, .needsSignIn, .storageFull, .error: true
        default: false
        }
    }

    /// The popover's actions in this state.
    var actions: [SyncAction] {
        switch self {
        case .offline, .storageFull: [.retryNow]
        case .readOnly(.accessRemoved): [.retryNow]
        case .needsReview: [.reviewMerge]
        case .needsSignIn: [.signIn, .useWithoutAccount]
        case .error: [.retryNow, .exportPackage]
        default: []
        }
    }

    /// Changes or images made on this Mac have not all reached the cloud (the quit sheet).
    var hasWaitingWork: Bool {
        switch self {
        case .saved, .opening, .readOnly(.role), .readOnly(.clientTooOld), .localOnly: false
        case .offline(let count): count > 0
        default: true
        }
    }

    /// Why a `readOnly` document is view only (the popover says which).
    var readOnlyReason: String? {
        guard case .readOnly(let reason) = self else { return nil }
        return switch reason {
        case .role: "Your role on this document is viewer or commenter."
        case .clientTooOld: "This document uses features newer than this version of WireTuner."
        case .roleInsufficient: "Your role was changed while you were offline; your changes are kept on this Mac."
        case .accessRemoved: "Your access to this document was removed."
        }
    }
}

/// The popover's details behind the state (saving.adoc, "The sync indicator").
struct SyncDetails: Equatable, Sendable {
    /// When the document was last fully synced.
    var lastSynced: Date?
    /// Who else has the document open.
    var collaborators: [String] = []
    /// The error text of `error`.
    var errorDetail: String?
}

/// Where a window reads its document's sync state: `DocumentSession` (a `WTSync.SyncClient`
/// per open document) in the app, `StubSyncStatus` for memory documents and tests.
@MainActor
protocol SyncStatusProviding: AnyObject {
    var state: SyncState { get }
    var details: SyncDetails { get }
    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> UUID
    func stopObserving(_ token: UUID)
    /// Runs a popover action.
    func perform(_ action: SyncAction)
}

/// A sync state without a session: whatever it is told (*Saved to cloud* for a memory document;
/// any state in tests and the harness); actions are recorded.
@MainActor
@Observable
final class StubSyncStatus: SyncStatusProviding {
    var state: SyncState {
        didSet { if state != oldValue { notify() } }
    }
    var details = SyncDetails() {
        didSet { if details != oldValue { notify() } }
    }
    private(set) var performed: [SyncAction] = []

    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    init(state: SyncState = .saved) {
        self.state = state
    }

    private func notify() {
        for observer in observers.values { observer() }
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

    func perform(_ action: SyncAction) {
        performed.append(action)
    }
}

/// The window's title and subtitle (saving.adoc): the title is the document's name alone -- there
/// is no unsaved marker, every change is kept -- and the subtitle is the sync state.
enum DocumentTitle {
    static func subtitle(for state: SyncState) -> String { state.description }
}

/// What the status bar's SwiftUI host shows: the sync glyph.
@MainActor
@Observable
final class StatusBarModel {
    var syncState: SyncState = .saved

    init() {}
}

/// The status bar's cloud glyph (workspace.adoc, "Sync indicator").
struct SyncIndicatorView: View {
    let model: StatusBarModel

    var body: some View {
        Image(systemName: model.syncState.symbolName)
            .foregroundStyle(model.syncState.needsAttention ? SwiftUI.Color.orange : SwiftUI.Color.secondary)
            .help(model.syncState.label)
            .accessibilityLabel(model.syncState.label)
            .accessibilityIdentifier("status.sync")
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
