import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// The "changed by X just now" pulse (collaboration.adoc, "When two people change the same
/// thing"; COLLAB-001): on applying a remote change, each node it touched pulses once in the
/// author's colour with a label ("Priya · Fill") for 1.5 s, drawn on the presence overlay so no
/// document tile repaints.  Changes arriving while a node pulses join its label instead of
/// restarting it, so a burst makes at most one pulse per node per 1.5 s; a change whose author is
/// not known yet (not sequenced, or nobody present by that replica) does not pulse.
@MainActor
final class AttributionFlashController {
    static let duration: TimeInterval = 1.5

    struct Flash: Equatable, Sendable {
        var node: SelectionID
        var author: String
        var colorIndex: Int
        var attributes: [String]
        var started: Date

        /// "Priya · Fill, Stroke".
        var label: String { attributes.isEmpty ? author : "\(author) · \(attributes.joined(separator: ", "))" }
        var color: Color { PresencePalette.color(at: colorIndex) }
    }

    /// *Flash changes by others*.
    var isEnabled: @MainActor () -> Bool = { true }
    var now: @MainActor () -> Date = { Date() }
    /// The overlay redraws (a pulse started or ended).
    var onChange: @MainActor () -> Void = {}
    /// How long the controller waits before clearing ended pulses; zero clears on the next read.
    var clearDelay: Duration = .milliseconds(1500)
    private(set) var flashes: [SelectionID: Flash] = [:]
    private var clearing: Task<Void, Never>?

    init() {}

    /// A remote change was applied; `author` wrote it (nil: unknown).
    func changeApplied(_ change: Wiretuner_Doc_V1_Change, author: SessionAuthor?) {
        guard isEnabled(), let author else { return }
        let at = now()
        var started = false
        for (node, attributes) in RegisterNames.touched(by: change) {
            let id = SelectionID(node)
            if var flash = flashes[id], at.timeIntervalSince(flash.started) < Self.duration {
                for attribute in attributes where !flash.attributes.contains(attribute) { flash.attributes.append(attribute) }
                flashes[id] = flash
            } else {
                flashes[id] = Flash(node: id, author: author.name, colorIndex: author.colorIndex, attributes: attributes, started: at)
                started = true
            }
        }
        guard started else { return }
        onChange()
        scheduleClear()
    }

    /// The pulses still running; ended ones are dropped.
    func active() -> [Flash] {
        let at = now()
        flashes = flashes.filter { at.timeIntervalSince($0.value.started) < Self.duration }
        return flashes.values.sorted { $0.node < $1.node }
    }

    /// How far a pulse is through its 1.5 s, 0...1 (its fade).
    func progress(_ flash: Flash) -> Double {
        min(max(now().timeIntervalSince(flash.started) / Self.duration, 0), 1)
    }

    private func scheduleClear() {
        clearing?.cancel()
        let delay = clearDelay
        clearing = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            _ = self.active()
            self.onChange()
        }
    }
}

/// Follow and Spotlight for one window (presence.adoc, "Following someone", "Asking others to
/// follow you"; COLLAB-009): the followed participant's viewport drives the view until the user
/// navigates, clicks *Stop*, presses kbd:[Esc], follows someone else, or the target leaves -- or
/// switches to a branch, which ends following with an offer to open it.  A spotlight shows one
/// banner per rising edge; *Dismiss* hides it until the next edge.
@MainActor
final class FollowController {
    /// A participant asking to be followed.
    struct Banner: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        var text: String { "\(name) wants you to follow them" }
    }

    private(set) var followingID: String?
    private(set) var followingName: String?
    private(set) var followingColor: Color?
    /// The branch the followed person moved to, offered in the bar.
    private(set) var branchOffer: (name: String, branchID: String)?
    private(set) var banners: [Banner] = []
    /// Whether the local user is spotlighting.
    private(set) var isSpotlighting = false
    private var lastSpotlight: [String: Bool] = [:]
    /// Moves the view to a participant's visible rect and zoom.
    var apply: @MainActor (Rect, Double?) -> Void = { _, _ in }
    /// The canvas the window shows (nil: the pasteboard); a followed view on another canvas is
    /// not applied (DOC-012).
    var canvas: OpID?
    /// Following, the bar or the banners changed.
    var onChange: @MainActor () -> Void = {}

    init() {}

    var isFollowing: Bool { followingID != nil }

    /// "Following Priya".
    var barText: String? {
        if let name = followingName { return "Following \(name)" }
        if let offer = branchOffer { return "\(offer.name) switched to a branch" }
        return nil
    }

    func follow(_ participant: RemoteParticipant) {
        followingID = participant.id
        followingName = participant.name
        followingColor = participant.color
        branchOffer = nil
        if let visible = participant.viewport, participant.canvas == canvas { apply(visible, participant.zoom) }
        onChange()
    }

    /// Ends following (local navigation, *Stop*, kbd:[Esc]); returns whether it was following.
    @discardableResult
    func stop() -> Bool {
        guard followingID != nil || branchOffer != nil else { return false }
        followingID = nil
        followingName = nil
        followingColor = nil
        branchOffer = nil
        onChange()
        return true
    }

    /// *Spotlight Me* / *Stop Spotlighting*.
    func toggleSpotlight() {
        isSpotlighting.toggle()
        onChange()
    }

    /// *Follow* on a banner.
    func accept(_ banner: Banner, participants: [RemoteParticipant]) {
        banners.removeAll { $0.id == banner.id }
        if let participant = participants.first(where: { $0.id == banner.id }) { follow(participant) } else { onChange() }
    }

    /// *Dismiss*: gone until the next spotlight from them.
    func dismiss(_ banner: Banner) {
        banners.removeAll { $0.id == banner.id }
        onChange()
    }

    /// Presence changed: the view tracks the target; spotlights raise or clear banners.
    func presenceDidChange(_ participants: [RemoteParticipant], isOffline: Bool) {
        var changed = false
        if let id = followingID {
            if isOffline {
                changed = stop() || changed
            } else if let target = participants.first(where: { $0.id == id }) {
                if !target.branchID.isEmpty {
                    let name = target.name
                    stop()
                    branchOffer = (name, target.branchID)
                    changed = true
                } else if let visible = target.viewport, target.canvas == canvas {
                    // A view on another canvas (a master page's tab) is in that canvas's space.
                    apply(visible, target.zoom)
                }
            } else {
                changed = stop() || changed
            }
        }
        var seen: [String: Bool] = [:]
        for participant in participants {
            seen[participant.id] = participant.spotlight
            let was = lastSpotlight[participant.id] ?? false
            if participant.spotlight, !was, participant.id != followingID {
                banners.append(Banner(id: participant.id, name: participant.name))
                changed = true
            } else if !participant.spotlight, was, banners.contains(where: { $0.id == participant.id }) {
                banners.removeAll { $0.id == participant.id }
                changed = true
            }
        }
        let departed = banners.filter { seen[$0.id] == nil }
        if !departed.isEmpty {
            banners.removeAll { seen[$0.id] == nil }
            changed = true
        }
        lastSpotlight = seen
        if changed { onChange() }
    }
}
