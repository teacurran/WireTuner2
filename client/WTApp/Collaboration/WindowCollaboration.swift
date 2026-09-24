import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync

/// What the bar above the canvas shows: "Following Priya" with *Stop*, the offer to open the branch
/// the followed person moved to, and the spotlight banners with *Follow* and *Dismiss*
/// (presence.adoc, "Following someone", "Asking others to follow you").
@MainActor
@Observable
final class CollaborationBannerModel {
    var followText: String?
    var offersBranch = false
    var banners: [FollowController.Banner] = []
    var warning: String?
    /// Notices with a button (the page notices' *Reapply mine*, *Restore page*).
    var actions: [BannerAction] = []
    @ObservationIgnored var onAction: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored var onDismissAction: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored var onStop: @MainActor () -> Void = {}
    @ObservationIgnored var onFollow: @MainActor (FollowController.Banner) -> Void = { _ in }
    @ObservationIgnored var onDismiss: @MainActor (FollowController.Banner) -> Void = { _ in }

    init() {}

    var isEmpty: Bool { followText == nil && banners.isEmpty && warning == nil && actions.isEmpty }
}

/// A notice in the bar above the canvas with one button and *Dismiss*.
struct BannerAction: Identifiable, Equatable {
    let id: UUID
    let text: String
    let button: String
}

struct CollaborationBannerView: View {
    let model: CollaborationBannerModel

    static func stop(_ model: CollaborationBannerModel) -> () -> Void { { model.onStop() } }
    static func follow(_ model: CollaborationBannerModel, _ banner: FollowController.Banner) -> () -> Void { { model.onFollow(banner) } }
    static func dismiss(_ model: CollaborationBannerModel, _ banner: FollowController.Banner) -> () -> Void { { model.onDismiss(banner) } }
    static func act(_ model: CollaborationBannerModel, _ action: BannerAction) -> () -> Void { { model.onAction(action.id) } }
    static func dismissAction(_ model: CollaborationBannerModel, _ action: BannerAction) -> () -> Void { { model.onDismissAction(action.id) } }

    var body: some View {
        VStack(spacing: 2) {
            if let warning = model.warning {
                Text(warning).font(.callout).frame(maxWidth: .infinity).padding(4).background(SwiftUI.Color.yellow.opacity(0.35))
                    .accessibilityIdentifier("canvas.warning")
            }
            if let text = model.followText {
                HStack {
                    Text(text).font(.callout.bold())
                    Spacer()
                    Button(model.offersBranch ? "Dismiss" : "Stop", action: Self.stop(model)).accessibilityIdentifier("follow.stop")
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(SwiftUI.Color.accentColor.opacity(0.18))
                .accessibilityIdentifier("follow.bar")
            }
            ForEach(model.actions) { action in
                HStack {
                    Text(action.text).font(.callout)
                    Spacer()
                    Button(action.button, action: Self.act(model, action)).accessibilityIdentifier("notice.action")
                    Button("Dismiss", action: Self.dismissAction(model, action)).accessibilityIdentifier("notice.dismiss")
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(SwiftUI.Color.yellow.opacity(0.25))
                .accessibilityIdentifier("notice.banner")
            }
            ForEach(model.banners) { banner in
                HStack {
                    Text(banner.text).font(.callout)
                    Spacer()
                    Button("Follow", action: Self.follow(model, banner)).accessibilityIdentifier("spotlight.follow")
                    Button("Dismiss", action: Self.dismiss(model, banner)).accessibilityIdentifier("spotlight.dismiss")
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(SwiftUI.Color.orange.opacity(0.18))
                .accessibilityIdentifier("spotlight.banner")
            }
        }
    }
}

/// Everything collaboration adds to one document window (COLLAB-001, 006, 007, 009; IO-002;
/// SYNC-007): the title-bar strip and cloud indicator, the presence overlay's inputs (cursor
/// clock, pulses, the followed person's colour), Follow and Spotlight with the bar above the
/// canvas, the outgoing presence, the review sheet, and the session's notices.
@MainActor
final class WindowCollaboration {
    weak var controller: DocumentWindowController?
    let session: DocumentSession?
    let presence: any PresenceProviding
    let syncStatus: any SyncStatusProviding
    let avatars = AvatarStripModel()
    let sync = SyncIndicatorModel()
    let follow = FollowController()
    let flashes = AttributionFlashController()
    let cursorClock = CursorLabelClock()
    let banner = CollaborationBannerModel()
    let review = ReviewSheetController()
    let publisher: LocalPresencePublisher?
    private(set) var accessory: NSTitlebarAccessoryViewController?
    let bannerHost: NSHostingView<CollaborationBannerView>
    /// Objects selected since the last document change: a remote deletion of one is announced.
    private(set) var recentSelection: Set<SelectionID> = []
    private var presenceToken: UUID?
    private var statusToken: UUID?
    private var sessionToken: UUID?
    private var labelTimer: Task<Void, Never>?
    /// When the overlay redraws after a cursor stops (its label hides then).
    var labelTimeout: Duration = .seconds(CursorLabelClock.labelTimeout)
    /// How many times the label timeout redrew the overlay.
    private(set) var labelTimeouts = 0

    init(session: DocumentSession?, presence: any PresenceProviding, syncStatus: any SyncStatusProviding) {
        self.session = session
        self.presence = presence
        self.syncStatus = syncStatus
        publisher = session.map { LocalPresencePublisher(presence: $0.localPresence) }
        bannerHost = NSHostingView(rootView: CollaborationBannerView(model: banner))
        bannerHost.translatesAutoresizingMaskIntoConstraints = false
        // Only its height follows the content: the window's layout gives it the canvas's width.
        bannerHost.sizingOptions = [.intrinsicContentSize]
        bannerHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bannerHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// Wires everything to `controller` once its views exist.
    func install(on controller: DocumentWindowController) {
        self.controller = controller
        let preferences = controller.environment.preferences
        let hosting = NSHostingView(rootView: TitlebarCollaborationView(avatars: avatars, sync: sync))
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hosting
        accessory.layoutAttribute = .trailing
        controller.window?.addTitlebarAccessoryViewController(accessory)
        self.accessory = accessory

        avatars.localName = controller.environment.userName()
        avatars.activity = { [weak controller] participant in
            controller.map { AvatarStripModel.activity(participant, in: $0.documentHandle) } ?? AvatarStripModel.activity(participant)
        }
        avatars.onFollow = { [weak self] id in self?.follow(id) }
        avatars.onStopFollowing = { [weak self] in self?.stopFollowing() }
        avatars.onSpotlight = { [weak self] in self?.toggleSpotlight() }
        avatars.displayOptions = { Self.displayOptions(preferences) }
        avatars.onDisplayOption = { id in Self.toggle(id, preferences) }
        sync.onAction = { [weak self] action in self?.syncStatus.perform(action) }
        follow.apply = { [weak controller] visible, zoom in controller?.follow(visible: visible, zoom: zoom) }
        follow.onChange = { [weak self] in self?.followDidChange() }
        flashes.isEnabled = { preferences[PreferenceCatalog.General.flashRemoteChanges] }
        flashes.onChange = { [weak controller] in controller?.canvas.setNeedsPresenceDisplay() }
        banner.onStop = { [weak self] in self?.stopFollowing() }
        banner.onFollow = { [weak self] item in
            guard let self else { return }
            self.follow.accept(item, participants: self.presence.participants)
        }
        banner.onDismiss = { [weak self] item in self?.follow.dismiss(item) }
        publisher?.setSharing(preferences[PreferenceCatalog.Sync.sharePresence])

        presenceToken = presence.observe { [weak self] in self?.presenceDidChange() }
        statusToken = syncStatus.observe { [weak self] in self?.syncStatusDidChange() }
        sessionToken = session?.observe { [weak self] notice in self?.handle(notice) }
        preferences.observe { [weak self] change in self?.preferenceDidChange(change.id) }
        presenceDidChange()
        syncStatusDidChange()
    }

    // MARK: Presence

    func presenceDidChange() {
        let participants = presence.participants
        avatars.participants = participants
        avatars.isOffline = presence.isOffline
        if cursorClock.update(participants) { scheduleLabelTimeout() }
        follow.presenceDidChange(participants, isOffline: presence.isOffline)
        controller?.canvas.setNeedsPresenceDisplay()
    }

    private func scheduleLabelTimeout() {
        labelTimer?.cancel()
        let delay = labelTimeout
        labelTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.labelTimeouts += 1
            self.controller?.canvas.setNeedsPresenceDisplay()
        }
    }

    /// The overlay's draw: everyone else, the pulses, the followed person's border.
    func drawPresence(in ctx: CGContext) {
        guard let controller else { return }
        let overlay = PresenceOverlay(document: controller.documentHandle, viewport: controller.canvas.viewport)
        overlay.draw(in: ctx, participants: presence.participants, options: PresenceDisplayOptions(preferences: controller.environment.preferences),
                     clock: cursorClock, flashes: flashes.active(), progress: { [flashes] in flashes.progress($0) },
                     following: follow.followingColor)
    }

    // MARK: Follow and Spotlight

    func follow(_ id: String) {
        guard let participant = presence.participants.first(where: { $0.id == id }) else { return }
        follow.follow(participant)
    }

    func stopFollowing() {
        follow.stop()
    }

    func toggleSpotlight() {
        follow.toggleSpotlight()
    }

    private func followDidChange() {
        banner.followText = follow.barText
        banner.offersBranch = follow.branchOffer != nil
        banner.banners = follow.banners
        avatars.followingID = follow.followingID
        avatars.isSpotlighting = follow.isSpotlighting
        publisher?.spotlight(follow.isSpotlighting)
        publisher?.following(follow.followingID)
        controller?.bannerDidChange()
        controller?.canvas.setNeedsPresenceDisplay()
    }

    // MARK: Sync

    func syncStatusDidChange() {
        sync.state = syncStatus.state
        sync.details = syncStatus.details
        controller?.updateTitle()
    }

    private func handle(_ notice: SessionNotice) {
        guard let controller else { return }
        switch notice {
        case .reviewNeeded(let review):
            if controller.isPrimaryView { controller.presentReview(review) }
        case .openReview(let review):
            if controller.isPrimaryView { controller.presentReview(review) }
        case .merged(let review):
            let offer = review.decision == .suggestReview ? " — File ▸ Review Merge… shows what changed" : ""
            controller.statusBar.show(message: review.toast + offer)
        case .message(let text):
            controller.statusBar.show(message: text)
        }
    }

    // MARK: Document and selection

    /// A change was drawn: remote ones pulse and announce deletions of selected objects.
    func contentDidChange(_ change: ContentChange) {
        defer { recentSelection = Set(controller?.selection.model.ids ?? []) }
        guard change.summary.origin == .remote, let applied = change.change, !applied.ops.isEmpty, let controller else { return }
        let author = session?.author(of: applied.replica)
        flashes.changeApplied(applied, author: author)
        let deleted = applied.ops.compactMap { op -> SelectionID? in
            guard case .setDeleted(let delete)? = op.op, delete.deleted else { return nil }
            return SelectionID(OpID(delete.node))
        }.filter(recentSelection.contains)
        if let first = deleted.first {
            let name = ObjectNaming.name(of: first.opID, in: controller.documentHandle.state)
            controller.statusBar.show(message: author.map { "\(name) deleted by \($0.name)" } ?? "\(name) deleted by someone else")
        }
    }

    func selectionDidChange(_ selection: Selection) {
        recentSelection.formUnion(selection.ids)
        publisher?.selection(selection)
    }

    // MARK: Preferences

    static let displayPreferences = [PreferenceCatalog.Sync.showCursors, PreferenceCatalog.Sync.showCursorNames, PreferenceCatalog.Sync.showSelections]

    static func displayOptions(_ preferences: PreferenceStore) -> [AvatarStripModel.DisplayOption] {
        displayPreferences.map { AvatarStripModel.DisplayOption(id: $0.id, title: $0.title, isOn: preferences[$0]) }
    }

    static func toggle(_ id: String, _ preferences: PreferenceStore) {
        guard let key = displayPreferences.first(where: { $0.id == id }) else { return }
        preferences.set(!preferences[key], for: key)
    }

    private func preferenceDidChange(_ id: String) {
        if id == PreferenceCatalog.Sync.sharePresence.id, let controller {
            publisher?.setSharing(controller.environment.preferences[PreferenceCatalog.Sync.sharePresence])
        }
        if Self.displayPreferences.contains(where: { $0.id == id }) { controller?.canvas.setNeedsPresenceDisplay() }
    }

    /// The window closed.
    func tearDown() {
        if let presenceToken { presence.stopObserving(presenceToken) }
        if let statusToken { syncStatus.stopObserving(statusToken) }
        if let sessionToken { session?.stopObserving(sessionToken) }
        labelTimer?.cancel()
        publisher?.pointer(nil)
    }
}
