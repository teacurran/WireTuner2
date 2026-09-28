import AppKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// Where copied objects go: the native pasteboard type `com.villagecompute.wiretuner.objects`
/// (copying.adoc, "Client").  Tests use a private named pasteboard.
@MainActor
protocol ObjectPasteboard: AnyObject {
    func write(_ payload: [UInt8])
    /// The payload on the pasteboard, if any.
    func read() -> [UInt8]?
}

/// An `NSPasteboard` holding the objects payload, under the app's `com.villagecompute.wiretuner.*`
/// namespace: the type the project exports and the one `ImportPasteboard` leaves to the app, so a
/// paste of WireTuner objects never goes through import.  Objects an earlier build put on the
/// pasteboard as `com.wiretuner.objects` are still read.
@MainActor
final class SystemObjectPasteboard: ObjectPasteboard {
    static let type = NSPasteboard.PasteboardType(ImportPasteboard.objectsType)
    /// The type earlier builds wrote; read, never written.
    static let legacyType = NSPasteboard.PasteboardType("com.wiretuner.objects")
    let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func write(_ payload: [UInt8]) {
        pasteboard.clearContents()
        pasteboard.setData(Data(payload), forType: Self.type)
    }

    func read() -> [UInt8]? {
        (pasteboard.data(forType: Self.type) ?? pasteboard.data(forType: Self.legacyType)).map { Array($0) }
    }
}

/// The object commands of one document window (copying.adoc, grouping.adoc, arranging.adoc,
/// transforming.adoc, moving.adoc): the clipboard, Duplicate and Clone with the power-duplicate
/// memory, Group and Ungroup, Lock, Arrange, *Transform Again*, arrow-key nudging.  It is also the
/// window's tools' `CommandSink`, so every move or transformation a tool performs updates the
/// duplicate memory and the last transformation, and any other command clears the memory.
@MainActor
final class ObjectEditing: CommandSink {
    let document: DocumentHandle
    let selection: SelectionController
    var pasteboard: any ObjectPasteboard
    /// *Remember layer info*.
    var rememberLayerInfo: @MainActor () -> Bool = { false }
    /// Where a plain Paste centres the copy (the visible area's centre, pasteboard space).
    var visibleCenter: @MainActor () -> Point? = { nil }
    /// The window's active layer (nil: the drawing layer), chosen in the Layers panel (LIB-004).
    var activeLayer: OpID? {
        didSet { if activeLayer != oldValue { onActiveLayerChange?() } }
    }
    /// Called after the active layer changes (the canvas's hidden-layer warning).
    var onActiveLayerChange: (@MainActor () -> Void)?
    /// The path the Pen and Bezigon are building, shared so a switch between them continues it.
    var pathSession: PathBuildingSession?
    /// The block the Text tool is editing, if any (the Object panel's Text section formats its
    /// selection; Edit menu commands act on its text).
    var textSession: TextEditingSession?
    /// A burst of nudges (key repeat) previews and is written as one change once this long
    /// passes without one (D-076).
    var nudgePause: Duration = .milliseconds(500)
    private(set) var duplicateMemory: DuplicateMemory?
    private(set) var lastTransform: LastTransform?
    private var nudgeEnd: Task<Void, Never>?
    private(set) var isNudging = false
    /// The burst's distance so far and its preview.
    private var nudgeTotal = Vector.zero
    private lazy var nudgeEdit = GestureEdit(document: document)

    init(document: DocumentHandle, selection: SelectionController, pasteboard: any ObjectPasteboard = SystemObjectPasteboard()) {
        self.document = document
        self.selection = selection
        self.pasteboard = pasteboard
        selection.model.observe { [weak self] current in self?.selectionDidChange(current) }
    }

    /// The selected objects' node ids, in selection order.
    var selectedNodes: [OpID] { selection.selection.ids.map(\.opID) }
    var hasSelection: Bool { !selection.selection.isEmpty }

    /// Whether the pasteboard holds objects.
    var canPaste: Bool { pasteboard.read().flatMap { ClipboardPayload(decoding: $0) }.map { !$0.isEmpty } ?? false }

    private func selectionDidChange(_ current: Selection) {
        if let memory = duplicateMemory, Set(current.ids.map(\.opID)) != memory.nodes { duplicateMemory = nil }
    }

    // MARK: CommandSink

    /// Performs `command` for a tool or menu: a move or transformation of exactly the duplicates
    /// feeds the duplicate memory, any other command clears it; a transformation is remembered for
    /// *Transform Again*.
    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        note(command)
        return document.perform(command)
    }

    private func note(_ command: any WTModel.Command) {
        switch command {
        case let move as MoveObjects:
            record(.move, matrix: .translation(move.delta), nodes: move.nodes)
        case let transform as TransformObjects where transform.copies == 0:
            lastTransform = LastTransform(transform)
            record(transform.kind, matrix: transform.effectiveMatrix, nodes: transform.nodes)
        case is DuplicateObjects:
            break
        default:
            duplicateMemory = nil
        }
    }

    private func record(_ kind: TransformKind, matrix: WTGeometry.AffineTransform, nodes: [OpID]) {
        guard var memory = duplicateMemory, memory.applies(to: Set(nodes)) else {
            duplicateMemory = nil
            return
        }
        memory.record(kind, matrix: matrix)
        duplicateMemory = memory
    }

    /// Performs `command` and then selects the objects it created.
    @discardableResult
    private func performSelectingCreated(_ command: any WTModel.Command, then: (@MainActor ([OpID]) -> Void)? = nil) -> Task<Void, Never> {
        let task = perform(command)
        let model = selection.model
        return Task { @MainActor in
            guard let created = await task.value?.createdRoots, !created.isEmpty else { return }
            model.set(Selection(created.map { SelectionID($0) }))
            then?(created)
        }
    }

    // MARK: Clipboard

    /// menu:Edit[Copy].
    func copy() {
        guard hasSelection else { return }
        // The swatches, styles and symbols the objects need in another document travel with them
        // (LIB-013, LIB-022): inside the payload, and the symbols also as their own pasteboard type.
        let state = document.state
        let payload = ClipboardPayload(copying: selectedNodes, from: state, document: document.id).carryingLibrary(from: state)
        pasteboard.write(payload.encoded())
        SymbolClipboard.write(payload, from: state, to: pasteboard)
    }

    /// menu:Edit[Cut]: copies, then deletes what may be deleted.
    @discardableResult
    func cut() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard hasSelection else { return nil }
        copy()
        return perform(CutObjects(selectedNodes))
    }

    private var payload: ClipboardPayload? {
        pasteboard.read().flatMap { ClipboardPayload(decoding: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// menu:Edit[Paste]: on top of the active layer, centred in the visible area.
    @discardableResult
    func paste() -> Task<Void, Never>? {
        guard let payload else { return nil }
        return performSelectingCreated(pasting(Paste(GlyphCanvasUnits.pasted(payload, in: document), placement: .top(layer: activeLayer, center: visibleCenter()),
                                                     rememberLayerInfo: rememberLayerInfo())))
    }

    /// menu:Edit[Special > Paste In Front] / *Paste Behind*: next to the top (or bottom)
    /// selected object, at the copied position.
    @discardableResult
    func paste(inFront: Bool) -> Task<Void, Never>? {
        guard let payload, let anchor = anchor(top: inFront) else { return nil }
        return performSelectingCreated(pasting(Paste(GlyphCanvasUnits.pasted(payload, in: document), placement: inFront ? .inFront(of: anchor) : .behind(anchor))))
    }

    /// A paste of objects copied in another document brings what they need from it: swatches by
    /// COLOR-019's clash rule, styles matched by name (a same-named style kept, the objects' looks
    /// baked as overrides), symbols as a paste of instances takes them (`PasteFromDocument`); a
    /// payload without that
    /// library still brings the symbols of the pasteboard's symbol package (`SymbolClipboard`).
    /// From this document, a plain paste (its carried colours find their own swatches).
    func pasting(_ paste: Paste) -> any WTModel.Command {
        guard paste.payload.sourceDocument != document.id else { return paste }
        if paste.payload.library != nil { return PasteFromDocument(paste) }
        return SymbolClipboard.command(paste, into: document.id, from: pasteboard)
    }

    /// The topmost (or bottommost) selected object in stacking order.
    private func anchor(top: Bool) -> OpID? {
        let ordered = Objects.stackingOrder(selectedNodes, in: document.state)
        return top ? ordered.last : ordered.first
    }

    var canPasteNextToSelection: Bool { hasSelection && canPaste }

    // MARK: Duplicate and Clone

    /// menu:Edit[Duplicate]: 10 pt right and down, or the remembered transformation.
    @discardableResult
    func duplicate() -> Task<Void, Never>? {
        guard hasSelection else { return nil }
        return performSelectingCreated(DuplicateObjects.duplicate(selectedNodes, memory: duplicateMemory)) { [weak self] created in
            self?.duplicateMemory = DuplicateMemory(nodes: Set(created))
        }
    }

    /// menu:Edit[Clone]: exactly on top.
    @discardableResult
    func clone() -> Task<Void, Never>? {
        guard hasSelection else { return nil }
        return performSelectingCreated(DuplicateObjects.clone(selectedNodes))
    }

    // MARK: Modify

    @discardableResult
    func group() -> Task<Void, Never>? {
        guard hasSelection else { return nil }
        return performSelectingCreated(GroupObjects(selectedNodes, layer: activeLayer, rememberLayerInfo: rememberLayerInfo()))
    }

    /// Ungroup: the members stay selected (a converted shape's path is selected instead).  A blend
    /// is released (blends.adoc, "Releasing a blend"): its key objects and the baked steps.
    @discardableResult
    func ungroup() -> Task<Void, Never>? {
        guard hasSelection else { return nil }
        let state = document.state
        let members = selectedNodes.flatMap { node in [.group, .blend].contains(state.nodeKind(node)) ? state.liveChildren(node) : [] }
        let blends = selectedNodes.filter { state.nodeKind($0) == .blend }
        let others = selectedNodes.filter { state.nodeKind($0) != .blend }
        let command: any WTModel.Command = blends.isEmpty ? Ungroup(selectedNodes, rememberLayerInfo: rememberLayerInfo())
            : others.isEmpty ? ReleaseBlend(blends) as any WTModel.Command
            : CompositeCommand("Ungroup", [ReleaseBlend(blends), Ungroup(others, rememberLayerInfo: rememberLayerInfo())])
        let task = perform(command)
        let model = selection.model
        return Task { @MainActor in
            guard let change = await task.value else { return }
            model.set(Selection((members + change.createdRoots).map { SelectionID($0) }))
        }
    }

    var canUngroup: Bool {
        let state = document.state
        return selectedNodes.contains { [.group, .rect, .ellipse, .polygon, .blend].contains(state.nodeKind($0)) }
    }

    @discardableResult
    func setLocked(_ locked: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard hasSelection else { return nil }
        return perform(SetLocked(selectedNodes, locked: locked))
    }

    /// Whether Lock (or Unlock) would change anything: an unlocked (locked) object not in a
    /// locked group is selected.
    func canSetLocked(_ locked: Bool) -> Bool {
        let state = document.state
        return selectedNodes.contains { Objects.isLocked($0, in: state) != locked && !Objects.isInLockedGroup($0, in: state) }
    }

    @discardableResult
    func arrange(_ direction: Arrange.Direction) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard hasSelection else { return nil }
        return perform(Arrange(selectedNodes, direction))
    }

    /// *Transform Again*: the last transformation, on the current selection.
    @discardableResult
    func transformAgain() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard hasSelection, let lastTransform else { return nil }
        return perform(lastTransform.again(selectedNodes))
    }

    var canTransformAgain: Bool { hasSelection && lastTransform != nil }

    /// menu:Extensions[Distort > Add Points] on the selected paths; a live shape among them is
    /// converted to a path in the same change (D-078).
    @discardableResult
    func addPoints() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let paths = selectedNodes.filter(isPathLike)
        guard !paths.isEmpty else { return nil }
        return perform(AddPoints(paths))
    }

    /// Whether a path, or a live shape that a path command converts, is selected.
    var hasSelectedPaths: Bool { selectedNodes.contains(where: isPathLike) }

    private func isPathLike(_ node: OpID) -> Bool {
        document.state.nodeKind(node) == .path || ShapeConversion.isShape(node, in: document.state)
    }

    // MARK: Nudging (OBJ-009)

    /// The command an arrow press performs: the selected points move (point registers) when a
    /// path has a point sub-selection, otherwise the selected objects (`transform`).
    func nudgeCommand(_ delta: Vector) -> (any WTModel.Command)? {
        Self.moveCommand(delta, selection: selection.selection, document: document)
    }

    /// The move of `current` by `delta`: its selected points, or its objects.
    static func moveCommand(_ delta: Vector, selection current: Selection, document: DocumentHandle) -> (any WTModel.Command)? {
        var pointMoves: [any WTModel.Command] = []
        for id in current.ids {
            guard case let .points(points)? = current.subSelection(of: id), !points.isEmpty,
                  let object = document.object(for: id), let path = object.path,
                  let inverse = object.transform.inverted() else { continue }
            let local = inverse.apply(delta)
            let moves = points.sorted().compactMap { reference -> MovePoints.Move? in
                guard let point = path.contour(reference.contour)?.points.first(where: { $0.id == reference.point }) else { return nil }
                return MovePoints.Move(contour: reference.contour, point: reference.point, anchor: point.anchor + local)
            }
            if !moves.isEmpty { pointMoves.append(MovePoints(node: id.opID, moves: moves)) }
        }
        if !pointMoves.isEmpty { return CommandBatch(pointMoves.count == 1 ? pointMoves[0].label : "Move Points", pointMoves) }
        // Connectors follow the objects they join (connectors.adoc): they are not moved themselves.
        let movable = current.ids.map(\.opID).filter { document.state.nodeKind($0) != .connector }
        guard !movable.isEmpty else { return nil }
        return NamedChange.move(MoveOffGrid.command(movable, by: delta, in: document.state), nodes: movable, state: document.state)
    }

    /// An arrow press: nudges by `delta`.  A burst of presses (key repeat) previews the move so
    /// far on the canvas and is written as one change -- one undo step -- once `nudgePause`
    /// passes without a press (D-076: gestures write intent, not input events).
    @discardableResult
    func nudge(by delta: Vector) -> Bool {
        let total = (isNudging ? nudgeTotal : .zero) + delta
        guard let command = nudgeCommand(total) else { return false }
        isNudging = true
        nudgeTotal = total
        nudgeEdit.update(command)
        nudgeEnd?.cancel()
        let pause = nudgePause
        nudgeEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            self?.endNudging()
        }
        return true
    }

    /// Writes the nudge burst as one change (after the pause; tests call it directly).
    @discardableResult
    func endNudging() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard isNudging else { return nil }
        isNudging = false
        nudgeTotal = .zero
        nudgeEnd?.cancel()
        nudgeEnd = nil
        guard let command = nudgeEdit.command else { return nil }
        nudgeEdit.cancel()
        return perform(command)
    }

    /// The nudge for an arrow key code (123 left, 124 right, 125 down, 126 up) at `distance`.
    static func nudgeDelta(keyCode: UInt16, distance: Double) -> Vector? {
        switch keyCode {
        case 123: Vector(dx: -distance, dy: 0)
        case 124: Vector(dx: distance, dy: 0)
        case 125: Vector(dx: 0, dy: distance)
        case 126: Vector(dx: 0, dy: -distance)
        default: nil
        }
    }
}
