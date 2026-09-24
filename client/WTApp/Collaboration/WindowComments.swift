import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// A thread being started: the pin is placed and the composer is open, but nothing is written
/// until btn:[Comment] (comments.adoc, "Adding a comment"); kbd:[Esc] discards it with its pin.
struct PendingThread: Equatable {
    /// Pasteboard point of the pin.
    var point: Point
    var anchor: OpID?
}

/// Everything comments add to one document window: the thread model rebuilt from the merged
/// state on each change, the unread overlay (a comment by someone else counts as unread until its
/// thread is displayed), the pin layer above the presence layer, the open thread and its popover,
/// the pending thread of the Comment tool, and the mention notice.
@MainActor
@Observable
final class WindowComments {
    static let pinRadius = 11.0
    static let resolvedColor = PinColor(white: 0.6)
    static let unreadColor = PinColor(red: 0.1, green: 0.45, blue: 1)
    /// Tools that draw points: pins hide while one is active (comments.adoc, "Showing and hiding pins").
    static let drawingTools: Set<ToolID> = ["pen", "bezigon", "freeform", "pencil"]

    @ObservationIgnored weak var window: DocumentWindowController?
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let features: CommentsFeatures
    @ObservationIgnored let layer = CanvasOverlayLayer()
    private(set) var model = CommentThreadModel(EngineState())
    private(set) var revision = 0
    /// Comments displayed on this Mac (or present when the window opened).
    @ObservationIgnored private(set) var read: Set<OpID> = []
    /// Every comment id seen, for spotting new ones.
    @ObservationIgnored private(set) var known: Set<OpID> = []
    private(set) var openThread: OpID?
    private(set) var pending: PendingThread?
    /// The pin the pointer is over (its first line shows).
    var hovered: OpID? {
        didSet { if hovered != oldValue { setNeedsDisplay() } }
    }
    /// The panel's filter; *Pins Follow Filter* draws only what it lists.
    var filter = CommentFilter()
    /// The people and team of the document, loaded on install.
    private(set) var members: [CommentMember] = []
    /// A pin shown briefly while *Show Pins* is off (a thread selected in the panel).
    private(set) var flashed: OpID?
    /// Mention notices shown, by banner action id.
    @ObservationIgnored private(set) var notices: [UUID: OpID] = [:]
    @ObservationIgnored private var readAt = -1
    @ObservationIgnored private var observation: DocumentHandle.ObservationToken?
    @ObservationIgnored private(set) var popover: NSPopover?
    @ObservationIgnored private var previousViewportChange: (@MainActor (Viewport) -> Void)?

    init(window: DocumentWindowController, features: CommentsFeatures) {
        self.window = window
        document = window.documentHandle
        self.features = features
    }

    var account: String { features.account().id }
    var permissions: CommentPermissions { CommentPermissions(role: features.role(document.id), account: account) }
    var preferences: PreferenceStore { features.preferences }

    /// Adds the pin layer over the canvas and follows the document.
    func install() {
        guard let window else { return }
        let canvas = window.canvas
        layer.anchorPoint = .zero
        layer.frame = canvas.bounds
        layer.contentsScale = canvas.overlayScale
        layer.drawer = { [weak self] ctx in self?.draw(in: ctx) }
        canvas.layer?.insertSublayer(layer, above: canvas.presenceLayer)
        previousViewportChange = canvas.onViewportChange
        canvas.onViewportChange = { [weak self] viewport in
            self?.previousViewportChange?(viewport)
            self?.viewportDidChange()
        }
        observation = document.observe { [weak self] change in self?.documentDidChange(change) }
        refresh()
        read = known
        refresh(force: true)
        let features = features
        let id = document.id
        Task { [weak self] in
            let members = await features.members(id)
            self?.members = members
        }
        let banner = window.collaboration.banner
        let previous = banner.onAction
        banner.onAction = { [weak self] id in
            if let self, let thread = self.notices.removeValue(forKey: id) {
                banner.actions.removeAll { $0.id == id }
                window.bannerDidChange()
                self.show(thread)
            } else {
                previous(id)
            }
        }
        let dismiss = banner.onDismissAction
        banner.onDismissAction = { [weak self] id in
            if self?.notices.removeValue(forKey: id) != nil {
                banner.actions.removeAll { $0.id == id }
                window.bannerDidChange()
            } else {
                dismiss(id)
            }
        }
    }

    func tearDown() {
        if let observation { document.stopObserving(observation) }
        observation = nil
        popover?.close()
        popover = nil
        layer.removeFromSuperlayer()
    }

    // MARK: The model

    /// Rebuilds the model when the document changed since the last build.
    func refresh(force: Bool = false) {
        guard force || readAt != document.changeCount else { return }
        readAt = document.changeCount
        let state = document.state
        let me = account
        var unread: [OpID: Set<OpID>] = [:]
        let all = CommentThreadModel(state, pages: document.pageList)
        for thread in all.threads {
            let ids = thread.comments.filter { !$0.deleted && $0.author != me && !read.contains($0.id) }.map(\.id)
            if thread.id == openThread { read.formUnion(ids) } else if !ids.isEmpty { unread[thread.id] = Set(ids) }
            known.formUnion(thread.comments.map(\.id))
        }
        model = CommentThreadModel(state, pages: document.pageList, unread: unread)
        revision += 1
        if let openThread, model[openThread] == nil { close() }
    }

    /// A change was applied: the model follows, and a new comment by someone else that mentions
    /// this account (or its team) shows the notice once.
    func documentDidChange(_ change: ContentChange) {
        let before = known
        refresh()
        setNeedsDisplay()
        features.panel.touch()
        guard change.summary.origin == .remote else { return }
        let me = account
        for thread in model.threads {
            for comment in thread.comments where !before.contains(comment.id) && comment.author != me && !comment.deleted {
                guard comment.mentions.contains(me) || mentionsMyTeam(comment) else { continue }
                announce(comment, in: thread)
            }
        }
    }

    private func mentionsMyTeam(_ comment: CommentEntry) -> Bool {
        let teams = members.filter(\.isTeam).map(\.id)
        return comment.mentions.contains { teams.contains($0) }
    }

    /// "Priya mentioned you" with btn:[Show].
    func announce(_ comment: CommentEntry, in thread: CommentThread) {
        guard let window, !notices.values.contains(thread.id) else { return }
        let id = UUID()
        notices[id] = thread.id
        window.collaboration.banner.actions.append(BannerAction(id: id, text: "\(name(of: comment.author)) mentioned you", button: "Show"))
        window.bannerDidChange()
    }

    /// A display name for an account: the roster's, else the account id.
    func name(of account: String) -> String {
        if account == self.account { return features.account().name.isEmpty ? "You" : features.account().name }
        return members.first { $0.id == account }?.name ?? (account.isEmpty ? "Someone" : account)
    }

    /// The unread comments in the document (the Comments panel's count).
    var unreadTotal: Int { model.unreadTotal }

    // MARK: Pins

    /// Whether pins draw now: *Show Pins*, and no drawing tool.
    var showsPins: Bool {
        guard preferences[PreferenceCatalog.Sync.showCommentPins] else { return false }
        guard let tool = window?.toolManager?.activeToolID else { return true }
        return !Self.drawingTools.contains(tool)
    }

    /// The threads whose pins are drawn: the open ones (and resolved ones with *Show Resolved
    /// Pins*), only those the panel lists with *Pins Follow Filter*; with pins hidden, only the
    /// one briefly shown.
    var visiblePins: [CommentThread] {
        let pins = model.pins(showResolved: preferences[PreferenceCatalog.Sync.showResolvedPins])
        guard showsPins else { return pins.filter { $0.id == flashed } }
        guard preferences[PreferenceCatalog.Sync.pinsFollowFilter] else { return pins }
        let listed = Set(filter.apply(model, account: account, members: members).map(\.id))
        return pins.filter { listed.contains($0.id) }
    }

    /// Where `thread`'s pin sits in view points.
    func pinCenter(_ thread: CommentThread, viewport: Viewport) -> Point? {
        thread.pin.map { viewport.toView($0) }
    }

    /// The topmost drawn pin under `viewPoint`.
    func thread(atView viewPoint: Point, viewport: Viewport) -> CommentThread? {
        visiblePins.reversed().first { thread in
            let center = viewport.toView(thread.pin!)
            return hypot(center.x - viewPoint.x, center.y - viewPoint.y) <= Self.pinRadius + 2
        }
    }

    func setNeedsDisplay() {
        layer.setNeedsDisplay()
    }

    private func viewportDidChange() {
        guard let canvas = window?.canvas else { return }
        if layer.frame != canvas.bounds { layer.frame = canvas.bounds }
        setNeedsDisplay()
        if let openThread, let popover, popover.isShown { position(popover, for: openThread) }
    }

    /// The author's colour: a stable pick from the presence palette.
    static func color(of account: String) -> PinColor {
        PresencePalette.color(at: account.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF })
    }

    /// Draws every visible pin (constant size, numbered, the author's colour or grey when
    /// resolved, a blue badge when unread) and the pending pin, then the hovered pin's first line.
    func draw(in ctx: CGContext) {
        guard let window else { return }
        refresh()
        let viewport = window.canvas.viewport
        for thread in visiblePins {
            let center = viewport.toView(thread.pin!)
            let color = thread.resolved ? Self.resolvedColor : Self.color(of: thread.opener.author)
            Self.drawPin(in: ctx, at: center, label: "\(thread.number)", color: color, unread: thread.unreadCount > 0, open: thread.id == openThread)
        }
        if let pending {
            Self.drawPin(in: ctx, at: viewport.toView(pending.point), label: "+", color: Self.color(of: account), unread: false, open: true)
        }
        if let hovered, let thread = model[hovered], let center = pinCenter(thread, viewport: viewport), !thread.firstLine.isEmpty {
            Self.drawLabel(in: ctx, text: thread.firstLine, at: Point(x: center.x + Self.pinRadius + 4, y: center.y - 8))
        }
    }

    static func drawPin(in ctx: CGContext, at center: Point, label: String, color: PinColor, unread: Bool, open: Bool) {
        let r = pinRadius
        let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(open ? CGColor(gray: 0, alpha: 0.8) : CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(open ? 2.5 : 1.5)
        ctx.strokeEllipse(in: rect)
        if unread {
            ctx.setFillColor(CGColor(srgbRed: unreadColor.red, green: unreadColor.green, blue: unreadColor.blue, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: center.x + r * 0.45, y: center.y - r * 1.15, width: 8, height: 8))
        }
        ctx.restoreGState()
        drawText(label, in: ctx, centeredAt: center, size: 10, color: .white, bold: true)
    }

    static func drawLabel(in ctx: CGContext, text: String, at origin: Point) {
        let clipped = text.count > 60 ? String(text.prefix(59)) + "…" : text
        let attributed = NSAttributedString(string: clipped, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        let box = CGRect(x: origin.x, y: origin.y, width: width + 10, height: 16)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        drawText(clipped, in: ctx, centeredAt: Point(x: box.midX, y: box.midY), size: 11, color: .black, bold: false)
    }

    /// Text centred on a point in the flipped (y down) overlay context.
    static func drawText(_ text: String, in ctx: CGContext, centeredAt center: Point, size: Double, color: NSColor, bold: Bool) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: center.x - bounds.width / 2 - bounds.minX, y: center.y + bounds.height / 2 + bounds.minY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Starting threads

    /// The selected object *Add Comment…* attaches to: the first selected one.
    var selectedAnchor: OpID? { window?.selection.selection.ids.first?.opID }

    /// menu:Object[Add Comment…]: a pending pin at the selection's centre, attached to it.
    @discardableResult
    func commentOnSelection() -> PendingThread? {
        guard permissions.canComment, let anchor = selectedAnchor, let bounds = window?.selection.selectedBounds else { return nil }
        return begin(at: bounds.center, on: anchor)
    }

    /// Places a pending pin at `point` (pasteboard) on `anchor` and opens the composer.
    @discardableResult
    func begin(at point: Point, on anchor: OpID?) -> PendingThread? {
        guard permissions.canComment else { return nil }
        close()
        let thread = PendingThread(point: point, anchor: anchor)
        pending = thread
        setNeedsDisplay()
        presentPopover()
        return thread
    }

    /// btn:[Comment]: the pending thread is written with its opening comment, one change.
    @discardableResult
    func post(_ body: CommentBody) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let pending, let window else { return nil }
        let command = CreateThread(at: pending.point, on: pending.anchor, page: document.pageList.page(containing: pending.point)?.id,
                                   author: account, body: body, in: document.state)
        self.pending = nil
        let task = window.objectEditing.perform(command)
        popover?.close()
        popover = nil
        setNeedsDisplay()
        return Task { [weak self] in
            let change = await task.value
            await self?.document.settle()
            if let self, let created = change?.createdNodes.first {
                self.refresh(force: true)
                self.open(created)
            }
            return change
        }
    }

    /// kbd:[Esc] in the composer: the pending pin goes away.
    func discardPending() {
        guard pending != nil else { return }
        pending = nil
        popover?.close()
        popover = nil
        setNeedsDisplay()
    }

    // MARK: Threads

    /// Opens `thread`: its popover shows at the pin and its comments count as read.
    func open(_ thread: OpID) {
        guard let entry = model[thread] else { return }
        pending = nil
        openThread = thread
        read.formUnion(entry.comments.map(\.id))
        refresh(force: true)
        setNeedsDisplay()
        features.panel.touch()
        presentPopover()
    }

    /// Closes the open thread or composer.
    func close() {
        openThread = nil
        pending = nil
        popover?.close()
        popover = nil
        setNeedsDisplay()
    }

    /// The panel's select: scroll to the pin and open the thread; while pins are hidden the pin
    /// shows until another is chosen.
    func show(_ thread: OpID, zoom: Bool = false) {
        guard let window, let entry = model[thread] else { return }
        if let pin = entry.pin {
            var viewport = window.canvas.viewport
            if zoom { viewport = window.canvas.navigation.zoom(viewport, to: 2) }
            window.canvas.setViewport(window.canvas.navigation.centring(viewport, on: pin))
        }
        flashed = thread
        open(thread)
    }

    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window else { return nil }
        let task = window.objectEditing.perform(command)
        return Task { [weak self] in
            let change = await task.value
            await self?.document.settle()
            self?.refresh(force: true)
            return change
        }
    }

    @discardableResult
    func reply(to thread: OpID, _ body: CommentBody) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard permissions.canComment, let entry = model[thread] else { return nil }
        let opener = entry.openerDeleted ? nil : name(of: entry.opener.author)
        return perform(Reply(to: thread, author: account, body: body, recipient: opener))
    }

    @discardableResult
    func edit(_ comment: OpID, in thread: OpID, _ body: CommentBody) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let entry = model[thread]?.comments.first(where: { $0.id == comment }), permissions.canEdit(entry) else { return nil }
        return perform(EditComment(thread: thread, comment: comment, body: body))
    }

    @discardableResult
    func delete(_ comment: OpID, in thread: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let entry = model[thread]?.comments.first(where: { $0.id == comment }), permissions.canDelete(entry) else { return nil }
        guard window?.confirm("Delete this comment?", "You can undo this until the window closes.") == true else { return nil }
        return perform(DeleteComment(thread: thread, comment: comment, in: document.state))
    }

    @discardableResult
    func deleteThread(_ thread: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard permissions.canDeleteThreads, model[thread] != nil else { return nil }
        guard window?.confirm("Delete this thread?", "Every comment in it is deleted.") == true else { return nil }
        if openThread == thread { close() }
        return perform(DeleteThread(thread))
    }

    @discardableResult
    func setResolved(_ thread: OpID, _ resolved: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let entry = model[thread], permissions.canResolve(entry) else { return nil }
        return perform(SetResolved(thread, resolved: resolved, in: document.state))
    }

    @discardableResult
    func react(_ emoji: String, to comment: OpID, in thread: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard permissions.canComment, model[thread] != nil else { return nil }
        return perform(React(thread: thread, comment: comment, account: account, emoji: emoji, in: document.state))
    }

    /// Drops `thread`'s pin at `point` (pasteboard) on `anchor` (nil: a point pin).
    @discardableResult
    func movePin(_ thread: OpID, to point: Point, on anchor: OpID?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let entry = model[thread], permissions.canMove(entry) else { return nil }
        return perform(MovePin(thread, to: point, on: anchor, page: document.pageList.page(containing: point)?.id, in: document.state))
    }

    /// *Copy Link*: a link that opens the document at the thread.
    func copyLink(_ thread: OpID) {
        let pasteboard = features.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(features.link(document.id, thread).absoluteString, forType: .string)
    }

    // MARK: The popover

    /// The thread popover (or the composer) beside the pin.
    func presentPopover() {
        guard let window, window.canvas.window != nil else { return }
        let model = ThreadViewModel(comments: self)
        let popover = popover ?? NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: CommentThreadView(model: model))
        popover.contentSize = NSSize(width: 320, height: 360)
        self.popover = popover
        position(popover, for: openThread)
    }

    private func position(_ popover: NSPopover, for thread: OpID?) {
        guard let window else { return }
        let viewport = window.canvas.viewport
        let point = pending.map { viewport.toView($0.point) } ?? thread.flatMap { model[$0] }.flatMap { pinCenter($0, viewport: viewport) }
        guard let point else { return }
        let rect = NSRect(x: point.x - Self.pinRadius, y: window.canvas.bounds.height - point.y - Self.pinRadius, width: 2 * Self.pinRadius, height: 2 * Self.pinRadius)
        popover.show(relativeTo: rect, of: window.canvas, preferredEdge: .maxX)
    }
}

