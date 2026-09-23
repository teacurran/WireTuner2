import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// What the avatar strip at the right end of the window's title bar shows (presence.adoc, "The
/// avatar strip"; COLLAB-006): everyone else in arrival order with the overflow collapsed into
/// "+N", then the local user's own avatar with its menu; offline, the single status line.
@MainActor
@Observable
final class AvatarStripModel {
    /// At most this many avatars; the rest go into the "+N" button.
    static let maximumShown = 6
    static let offlineStatus = "Offline — working alone until you reconnect"

    var participants: [RemoteParticipant] = []
    var isOffline = false
    /// The local user's display name (the own avatar).
    var localName = ""
    /// The person being followed, if any.
    var followingID: String?
    var isSpotlighting = false
    /// The hover cards' activity text (derived from the document: object and page names).
    @ObservationIgnored var activity: @MainActor (RemoteParticipant) -> String = { AvatarStripModel.activity($0) }
    @ObservationIgnored var onFollow: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var onStopFollowing: @MainActor () -> Void = {}
    @ObservationIgnored var onSpotlight: @MainActor () -> Void = {}
    /// The own avatar's display options: the three presence preferences.
    @ObservationIgnored var displayOptions: @MainActor () -> [DisplayOption] = { [] }
    @ObservationIgnored var onDisplayOption: @MainActor (String) -> Void = { _ in }

    /// One of the three display switches, as the own-avatar menu lists it.
    struct DisplayOption: Identifiable, Equatable {
        let id: String
        let title: String
        let isOn: Bool
    }

    init() {}

    /// The avatars drawn individually.
    var shown: [RemoteParticipant] { Array(participants.prefix(Self.maximumShown)) }
    /// The avatars in the "+N" button.
    var overflow: [RemoteParticipant] { Array(participants.dropFirst(Self.maximumShown)) }
    var overflowTitle: String? { overflow.isEmpty ? nil : "+\(overflow.count)" }

    /// The own avatar's menu: *Spotlight Me* (or *Stop Spotlighting*), *Stop Following* while
    /// following, then the display options.
    var ownMenuTitles: [String] {
        [isSpotlighting ? "Stop Spotlighting" : "Spotlight Me"] + (followingID == nil ? [] : ["Stop Following"])
            + displayOptions().map(\.title)
    }

    /// "Priya Shah" → "PS"; one word → its first letter.
    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// The hover card's activity (presence.adoc's table) from the participant's fields; `object`
    /// names an object, `commentAnchor` names the object a comment thread is pinned to (nil when
    /// the node is not a thread), `page` the page their view is on, `branch` a branch id.
    static func activity(
        _ participant: RemoteParticipant, object: (SelectionID) -> String = { _ in "an object" },
        commentAnchor: (SelectionID) -> String? = { _ in nil }, page: (RemoteParticipant) -> Int? = { _ in nil },
        branch: (String) -> String = { _ in "a branch" }
    ) -> String {
        if participant.isFrozen { return "Reconnecting" }
        if participant.isIdle { return "Idle" }
        if !participant.branchID.isEmpty { return "Editing on branch \"\(branch(participant.branchID))\"" }
        if let first = participant.editing.first {
            if let anchor = commentAnchor(first) { return "Commenting on \(anchor)" }
            return participant.editing.count == 1 ? "Editing \(object(first))" : "Editing \(participant.editing.count) objects"
        }
        if participant.selectionCount > 0 {
            return participant.selectionCount == 1 ? "Selected 1 object" : "Selected \(participant.selectionCount) objects"
        }
        if let index = page(participant) { return "Viewing page \(index + 1)" }
        return "Viewing the pasteboard"
    }

    // MARK: Actions

    func follow(_ id: String) { onFollow(id) }
    func stopFollowing() { onStopFollowing() }
    func spotlight() { onSpotlight() }
    func toggle(_ option: String) { onDisplayOption(option) }
}

extension AvatarStripModel {
    /// The activity text for `participant` in `document` (objects by name, pages by the view's
    /// centre).
    static func activity(_ participant: RemoteParticipant, in document: DocumentHandle) -> String {
        let state = document.state
        return activity(
            participant,
            object: { ObjectNaming.name(of: $0.opID, in: state) },
            commentAnchor: { id in
                guard case .commentThread(let thread)? = state.props(id.opID).kind else { return nil }
                return thread.hasAnchor ? ObjectNaming.name(of: OpID(thread.anchor.id), in: state) : "the page"
            },
            page: { participant in
                guard let visible = participant.viewport else { return nil }
                return document.pages.firstIndex { $0.contains(visible.center) }
            }
        )
    }
}

/// One avatar: initials on the participant's colour with a ring, dimmed when idle, with the hover
/// card as its help and a click that follows them.
struct AvatarView: View {
    let participant: RemoteParticipant
    let model: AvatarStripModel

    var body: some View {
        let color = participant.color
        Button(action: AvatarStripView.follow(model, participant.id)) {
            Text(AvatarStripModel.initials(participant.name))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(SwiftUI.Color(red: color.red, green: color.green, blue: color.blue)))
                .overlay(Circle().stroke(SwiftUI.Color(red: color.red, green: color.green, blue: color.blue), lineWidth: model.followingID == participant.id ? 3 : 1).padding(-2))
                .opacity(participant.isIdle || participant.isFrozen ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .help(AvatarStripView.card(participant, model))
        .accessibilityLabel(AvatarStripView.card(participant, model))
        .accessibilityIdentifier("presence.avatar.\(participant.id)")
    }
}

/// The strip: avatars, "+N", the own avatar; offline, the status line.
struct AvatarStripView: View {
    let model: AvatarStripModel

    /// The hover card: name, role, activity.
    static func card(_ participant: RemoteParticipant, _ model: AvatarStripModel) -> String {
        [participant.name, participant.role, model.activity(participant)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func follow(_ model: AvatarStripModel, _ id: String) -> () -> Void {
        { model.follow(id) }
    }

    static func ownAction(_ model: AvatarStripModel, _ title: String) -> () -> Void {
        {
            switch title {
            case "Spotlight Me", "Stop Spotlighting": model.spotlight()
            case "Stop Following": model.stopFollowing()
            default: model.displayOptions().first { $0.title == title }.map { model.toggle($0.id) }
            }
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            if model.isOffline {
                Text(AvatarStripModel.offlineStatus).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("presence.offline")
            } else {
                ForEach(model.shown) { participant in AvatarView(participant: participant, model: model) }
                if let title = model.overflowTitle {
                    Menu(title) {
                        ForEach(model.overflow) { participant in
                            Button(Self.card(participant, model), action: Self.follow(model, participant.id))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("presence.overflow")
                }
            }
            Menu {
                ForEach(model.ownMenuTitles, id: \.self) { title in
                    Button(title, action: Self.ownAction(model, title))
                }
            } label: {
                Text(AvatarStripModel.initials(model.localName.isEmpty ? "Me" : model.localName))
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().stroke(SwiftUI.Color.accentColor, lineWidth: 2))
                    .overlay(alignment: .topTrailing) {
                        if model.isSpotlighting { Circle().fill(SwiftUI.Color.orange).frame(width: 6, height: 6) }
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("presence.me")
        }
        .accessibilityIdentifier("presence.avatars")
    }
}
