import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

// The master page tab (master-pages.adoc, "Editing a master page", "Client"; DOC-012): a second
// canvas over the document's model whose builder draws the master's canvas (`canvasNode` = the
// master, DOC-011), whose background is the master's page at the canvas origin (a master has no
// pasteboard position), and whose commands put what they create on the master
// (`CanvasPlacedCommand`, as a glyph tab's do).  It shares the document's session and presence,
// needs no save, hides the page selector and closes itself when the master is deleted.

/// A master page's canvas: the tab id, the page it draws, the handle.
@MainActor
enum MasterCanvas {
    nonisolated static let marker = "#master-"

    /// The id a master tab's handle goes by: its document's, the master's.
    static func tabID(document: String, master: OpID) -> String { "\(document)\(marker)\(master)" }

    /// Whether `id` names a master tab.
    static func isTab(_ id: String) -> Bool { id.contains(marker) }

    /// The master's page as the tab draws it: its size at the canvas origin, with its bleed; nil
    /// once the master is gone.
    static func frame(of master: OpID, in state: EngineState) -> PageFrame? {
        guard let page = PageList(state).master(master) else { return nil }
        return PageFrame(rect: page.rect, bleed: page.bleed, isActive: true)
    }

    /// The tab's background: the master's page (nothing once it is gone).
    static func background(of master: OpID, in state: EngineState) -> [DisplayItem] {
        frame(of: master, in: state).map { [PageRendering.item([$0], style: DocumentHandle.pageStyle)] } ?? []
    }

    /// The name a master is shown with ("Master" when it has none).
    static func name(of master: OpID, in state: EngineState) -> String {
        let name = state.props(master).masterPage.common.name
        return name.isEmpty ? "Master" : name
    }

    /// A handle drawing `master`'s canvas over `document`'s open model.
    @MainActor
    static func handle(for master: OpID, of document: DocumentHandle) -> DocumentHandle {
        let handle = DocumentHandle(id: tabID(document: document.id, master: master), title: name(of: master, in: document.state),
                                    replicaID: document.replicaID, model: document.model!, canvasNode: master)
        handle.canvasBackground = { state in background(of: master, in: state) }
        handle.refreshBackground()
        return handle
    }
}

extension DocumentHandle {
    /// The master page this handle's canvas draws (a master tab), nil otherwise.
    var masterCanvasNode: OpID? {
        guard let canvasNode, state.store.kind(canvasNode) == MasterPageFields.kind else { return nil }
        return canvasNode
    }

    /// The glyph this handle's canvas draws (a glyph tab), nil on the pasteboard, a master tab or a
    /// symbol window.
    var glyphCanvasNode: OpID? { masterCanvasNode == nil && symbolCanvasNode == nil ? canvasNode : nil }
}

/// Opens master tabs and keeps them in step with their masters.  One per app.
@MainActor
final class MasterTabs {
    static let noSingleMaster = "Select pages that follow one master page"

    /// The open documents (master tabs open through it); nil in tests, which add the tab to the
    /// source window's tab group themselves.
    weak var documents: DocumentController?
    /// Every open master tab by handle id.
    private(set) var tabs: [String: DocumentWindowController] = [:]
    private var tokens: [String: DocumentHandle.ObservationToken] = [:]

    init() {}

    /// The master the Document panel's btn:[Edit] opens: the one master every selected page
    /// follows; nil when they follow none or several.
    static func editableMaster(in window: DocumentWindowController) -> OpID? {
        let masters = Set(window.documentHandle.selectedPages.map(\.master))
        guard masters.count == 1, case let master?? = masters.first else { return nil }
        return master
    }

    /// The document window a tab of `source`'s document belongs to (`source` itself for the
    /// document's own window).
    func documentWindow(of source: DocumentWindowController) -> DocumentWindowController {
        let id = GlyphCanvas.documentID(ofTab: source.documentHandle.id)
        return documents?.windowControllers[id] ?? source
    }

    /// Opens `master` in a tab beside `source` (or brings its tab forward); nil when the master is
    /// not live or the document's model is not open.
    @discardableResult
    func open(_ master: OpID, from source: DocumentWindowController) -> DocumentWindowController? {
        let parent = documentWindow(of: source)
        let document = parent.documentHandle
        guard document.model != nil, PageList(document.state).master(master) != nil else { return nil }
        let id = MasterCanvas.tabID(document: document.id, master: master)
        if let existing = tabs[id] {
            existing.showWindow(nil)
            return existing
        }
        let handle = MasterCanvas.handle(for: master, of: document)
        let controller: DocumentWindowController
        if let documents, let window = source.window {
            controller = documents.open(handle, placement: .with(window))
        } else {
            controller = DocumentWindowController(document: handle, environment: Self.environment(parent.environment, parent: parent))
            source.window?.addTabbedWindow(controller.window!, ordered: .above)
        }
        controller.isPrimaryView = false
        configure(controller, master: master)
        return controller
    }

    /// The environment a master tab of `parent`'s document is made with outside the app's
    /// window factory: the document's session and presence, no close hook of its own.
    static func environment(_ environment: DocumentEnvironment, parent: DocumentWindowController) -> DocumentEnvironment {
        var environment = environment
        let session = parent.session, presence = parent.presence, status = parent.syncStatus
        environment.session = { _ in session }
        environment.makePresence = { _ in presence }
        environment.makeSyncStatus = { _ in status }
        environment.documentDidClose = TypefaceFeatures.keepOpen
        return environment
    }

    /// A master tab's window: no page selector, the master fitted, the title following the
    /// master's name, closed when the master goes.
    func configure(_ controller: DocumentWindowController, master: OpID) {
        let id = controller.documentHandle.id
        tabs[id] = controller
        for control in [controller.statusBar.addPage, controller.statusBar.previousPage, controller.statusBar.pageField, controller.statusBar.nextPage] {
            control.isHidden = true
        }
        if let frame = MasterCanvas.frame(of: master, in: controller.documentHandle.state) {
            controller.setViewport(controller.canvas.navigation.fit(controller.viewport, rect: frame.rect))
        }
        let handle = controller.documentHandle
        tokens[id] = handle.observeStructure { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.masterDidChange(controller, master: master)
        }
        let previous = controller.onClose
        controller.onClose = { [weak self] closed in
            previous?(closed)
            self?.forget(closed)
        }
    }

    /// The master changed: its tab follows its name, and closes once it is deleted.
    func masterDidChange(_ controller: DocumentWindowController, master: OpID) {
        let state = controller.documentHandle.state
        guard PageList(state).master(master) != nil else {
            controller.window?.close()
            forget(controller)
            return
        }
        controller.documentHandle.title = MasterCanvas.name(of: master, in: state)
        controller.documentHandle.refreshBackground()
    }

    /// The tab closed.
    func forget(_ controller: DocumentWindowController) {
        let id = controller.documentHandle.id
        guard tabs.removeValue(forKey: id) != nil else { return }
        if let token = tokens.removeValue(forKey: id) { controller.documentHandle.stopObserving(token) }
    }
}

/// One page a release change released: the page, its master and the copy groups the change
/// made on the page's layers ("Released master content").
struct MasterRelease: Hashable, Sendable {
    let page: OpID
    let master: OpID
    let groups: [OpID]

    /// The releases in `change` (`ReleaseChildPages`: a label ending in the master tag, each
    /// `SetFields` of a page starting that page, the objects created on a layer after it its copy
    /// groups).
    static func releases(in change: Wiretuner_Doc_V1_Change, state: EngineState) -> [MasterRelease] {
        guard let master = MasterContent.releasedMaster(fromLabel: change.label) else { return [] }
        var pages: [(page: OpID, groups: [OpID])] = []
        for (op, id) in zip(change.ops, change.opIDs) {
            switch op.op {
            case .set(let set)? where state.store.kind(OpID(set.node)) == PageFields.kind:
                pages.append((OpID(set.node), []))
            case .create(let create)? where state.nodeKind(OpID(create.parent)) == .layer && !pages.isEmpty:
                pages[pages.count - 1].groups.append(id)
            default:
                break
            }
        }
        return pages.map { MasterRelease(page: $0.page, master: master, groups: $0.groups) }
    }

    /// Whether `change` wrote on `master`'s canvas: the master itself, an object on it, or anything
    /// inside such an object.
    static func writes(_ change: Wiretuner_Doc_V1_Change, on master: OpID, state: EngineState) -> Bool {
        zip(change.ops, change.opIDs).contains { op, id in
            guard let node = target(op, id) else { return false }
            return node == master || canvas(of: node, in: state) == master
        }
    }

    /// The node an op writes.
    static func target(_ op: Wiretuner_Doc_V1_Op, _ id: OpID) -> OpID? {
        switch op.op {
        case .create?: id
        case .set(let set)?: OpID(set.node)
        case .move(let move)?: OpID(move.node)
        case .setDeleted(let flag)?: OpID(flag.node)
        case .elementInsert(let insert)?: OpID(insert.node)
        case .elementMove(let move)?: OpID(move.node)
        case .elementDelete(let delete)?: OpID(delete.node)
        case .textInsert(let insert)?: OpID(insert.node)
        case .textDelete(let delete)?: OpID(delete.node)
        case .textMark(let mark)?: OpID(mark.node)
        default: nil
        }
    }

    /// The canvas `node` or its nearest ancestor with one names, if any.
    static func canvas(of node: OpID, in state: EngineState) -> OpID? {
        var current: OpID? = node
        var steps = 0
        while let at = current, steps < 256 {
            if let common = NavigationFields.common(of: at, in: state), common.hasCanvas { return OpID(common.canvas.id) }
            current = state.store.placement(at)?.parent
            steps += 1
        }
        return nil
    }
}

/// *Update the copies*: the release's live copy groups deleted and the master's current objects
/// copied onto the page again as `ReleaseChildPages` does -- one group per layer holding master
/// objects, at the bottom of the layer, translated by the page's origin, each copy's `canvas`
/// cleared -- in one change.
struct UpdateReleaseCopies: WTModel.Command {
    let release: MasterRelease
    var label: String { "Update the copies" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for group in release.groups where state.isLive(group) {
            builder.append(Ops.setDeleted(group, true))
        }
        let origin = state.props(release.page).page.origin
        var transform = Wiretuner_Doc_V1_Transform()
        transform.a = 1
        transform.d = 1
        transform.tx = origin.x
        transform.ty = origin.y
        for (layer, objects) in MasterContent.objects(of: release.master, in: state) {
            let first = state.liveChildren(layer).first.flatMap { state.store.placement($0)?.position }
            var group = Wiretuner_Doc_V1_NodeProps()
            group.group.common.name = "Released master content"
            group.group.common.transform = transform
            let groupID = builder.append(Ops.create(parent: layer, position: try FractionalIndex.between(nil, first, suffix: builder.nextCounter), props: group))
            var previous: [UInt8]?
            for object in objects {
                let key = try FractionalIndex.between(previous, nil, suffix: builder.nextCounter)
                previous = key
                let copy = try NodeCopier.create(NodeTree(object, state: state), parent: groupID, position: key, schema: state.schema, builder: &builder)
                builder.append(Ops.set(copy, [RegisterPath([state.store.kind(object), 1, 5])], values: Wiretuner_Doc_V1_NodeProps()))
            }
        }
    }
}

/// The master pages' live notices (master-pages.adoc, "Working with others"; DOC-012): when this
/// person released a child page a moment ago and someone else's change writes on that master --
/// "Priya changed Master A while you released page 4", with *Update the copies* -- and when
/// someone deletes a master pages still follow -- "Tom deleted Master A; 2 pages are ordinary
/// pages now", with *Restore*.  The notices go in the window's banner beside the page notices.
@MainActor
final class MasterNotices {
    /// How long a local release counts as "a moment ago".
    static let recent: TimeInterval = PageNotices.recent
    static let updateCopies = "Update the copies"

    unowned let window: DocumentWindowController
    /// When it is now; replaceable in tests.
    var clock: @MainActor () -> Date = { Date() }
    /// This person's recent releases, with when.
    private(set) var releases: [(release: MasterRelease, at: Date)] = []
    private var token: DocumentHandle.ObservationToken?

    init(window: DocumentWindowController) {
        self.window = window
        token = window.documentHandle.observe { [weak self] change in
            if let applied = change.change { self?.documentDidChange(applied) }
        }
    }

    func stop() {
        if let token { window.documentHandle.stopObserving(token) }
        token = nil
    }

    /// The text of the stale-release notice.
    static func staleText(author: String, master: String, page: Int) -> String {
        "\(author) changed \(master) while you released page \(page)"
    }

    /// The text of the deleted-master notice.
    static func deletedText(author: String, master: String, pages: Int) -> String {
        "\(author) deleted \(master); \(pages == 1 ? "1 page is an ordinary page" : "\(pages) pages are ordinary pages") now"
    }

    /// An applied change: this person's releases are remembered; someone else's change may make a
    /// release stale or delete a followed master.  Returns how many notices were posted.
    @discardableResult
    func documentDidChange(_ change: Wiretuner_Doc_V1_Change) -> Int {
        let now = clock()
        releases.removeAll { now.timeIntervalSince($0.at) > Self.recent }
        let document = window.documentHandle
        let state = document.state
        guard change.replica != document.model?.replica else {
            releases += MasterRelease.releases(in: change, state: state).map { ($0, now) }
            return 0
        }
        let author = window.collaboration.session?.author(of: change.replica)?.name ?? "Someone"
        var posted = 0
        for (release, _) in releases where MasterRelease.writes(change, on: release.master, state: state) {
            let page = PageList(state)[release.page]?.number ?? 0
            window.pageNotices.post(Self.staleText(author: author, master: MasterCanvas.name(of: release.master, in: state), page: page),
                                    action: Self.updateCopies, command: UpdateReleaseCopies(release: release))
            posted += 1
        }
        releases.removeAll { MasterRelease.writes(change, on: $0.release.master, state: state) }
        for master in Self.deletedMasters(in: change, state: state) {
            let pages = Self.followers(of: master, in: state)
            guard pages > 0 else { continue }
            window.pageNotices.post(Self.deletedText(author: author, master: MasterCanvas.name(of: master, in: state), pages: pages),
                                    action: "Restore", command: OpsCommand("Restore master page", ops: [Ops.setDeleted(master, false)]))
            posted += 1
        }
        if posted > 0 { window.showNotices() }
        return posted
    }

    /// The masters `change` deleted that are still deleted.
    static func deletedMasters(in change: Wiretuner_Doc_V1_Change, state: EngineState) -> [OpID] {
        change.ops.compactMap { op -> OpID? in
            guard case .setDeleted(let flag)? = op.op, flag.deleted else { return nil }
            let node = OpID(flag.node)
            return state.store.kind(node) == MasterPageFields.kind && !state.isLive(node) ? node : nil
        }
    }

    /// How many live pages name `master` as theirs.
    static func followers(of master: OpID, in state: EngineState) -> Int {
        state.liveChildren(WellKnown.pages).filter { page in
            let props = state.props(page).page
            return props.hasMaster && OpID(props.master.id) == master
        }.count
    }
}
