import AppKit
import Observation
import SwiftUI

/// The title bar's cloud indicator and its popover (saving.adoc, "The sync indicator"; IO-002):
/// the state, the details behind it, and the actions that make sense in it.
@MainActor
@Observable
final class SyncIndicatorModel {
    var state: SyncState = .saved
    var details = SyncDetails()
    var isPopoverShown = false
    /// *Storage almost full* for the document's space (`StorageMonitor`, IO-009); nil below 90%.
    var storageNote: String?
    @ObservationIgnored var onAction: @MainActor (SyncAction) -> Void = { _ in }

    init() {}

    /// "Last fully synced 3 minutes ago" / "Not synced yet".
    func lastSyncedText(now: Date = Date()) -> String {
        guard let date = details.lastSynced else { return "Not fully synced yet on this Mac" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last fully synced \(formatter.localizedString(for: date, relativeTo: now))"
    }

    /// "Priya and Tom also have it open" / nil when alone.
    var collaboratorsText: String? {
        let names = details.collaborators
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(list) \(names.count == 1 ? "also has" : "also have") it open"
    }

    /// The popover's explanation line for states that need one.
    var explanation: String? {
        if let reason = state.readOnlyReason { return reason }
        switch state {
        case .error: return details.errorDetail.map { "Something is wrong that WireTuner cannot fix by retrying: \($0)" }
            ?? "Something is wrong that WireTuner cannot fix by retrying."
        case .needsReview: return "Someone else changed some of the same objects. Review the merge before your changes are sent."
        case .needsSignIn: return "Your session expired. Work continues on this Mac; sign in again to sync."
        case .storageFull: return "Your team's storage is full. Changes still sync; new images wait until space is freed."
        case .offline: return "Everything you do is kept on this Mac and syncs when you reconnect."
        default: return nil
        }
    }

    func run(_ action: SyncAction) {
        isPopoverShown = false
        onAction(action)
    }

    func togglePopover() { isPopoverShown.toggle() }
}

/// The popover body.
struct SyncPopoverView: View {
    let model: SyncIndicatorModel

    static func run(_ model: SyncIndicatorModel, _ action: SyncAction) -> () -> Void {
        { model.run(action) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.state.label, systemImage: model.state.symbolName).font(.headline).accessibilityIdentifier("sync.popover.state")
            if let explanation = model.explanation { Text(explanation).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let storage = model.storageNote {
                Label(storage, systemImage: "externaldrive.badge.exclamationmark").font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("sync.popover.storage")
            }
            Text(model.lastSyncedText()).font(.caption).foregroundStyle(.secondary)
            if let collaborators = model.collaboratorsText { Text(collaborators).font(.caption).foregroundStyle(.secondary) }
            if !model.state.actions.isEmpty {
                HStack {
                    ForEach(model.state.actions, id: \.self) { action in
                        Button(action.title, action: Self.run(model, action)).accessibilityIdentifier("sync.action.\(action.rawValue)")
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// The title bar's trailing accessory: the avatar strip, then the cloud indicator whose click
/// opens the popover.
struct TitlebarCollaborationView: View {
    let avatars: AvatarStripModel
    let sync: SyncIndicatorModel

    static func toggle(_ model: SyncIndicatorModel) -> () -> Void {
        { model.togglePopover() }
    }

    var body: some View {
        HStack(spacing: 8) {
            AvatarStripView(model: avatars)
            Button(action: Self.toggle(sync)) {
                Image(systemName: sync.state.symbolName)
                    .foregroundStyle(sync.state.needsAttention ? SwiftUI.Color.orange : SwiftUI.Color.secondary)
            }
            .buttonStyle(.plain)
            .help(sync.state.label)
            .accessibilityLabel(sync.state.label)
            .accessibilityIdentifier("sync.indicator")
            .popover(isPresented: Binding(get: { sync.isPopoverShown }, set: { sync.isPopoverShown = $0 })) {
                SyncPopoverView(model: sync)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }
}
