import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Named views (BASIC-015, document-view.adoc "Named views"): shared `custom_view` nodes (kind 260,
/// BASIC block), children of the `settings` node in menu:View[Custom] order.  The name is
/// `CommonProps.name` (empty reads as "View n"); magnification, scroll position and drawing mode
/// are one ATOMIC `target` register, so two concurrent redefines never mix one person's zoom with
/// the other's scroll.  Recalling a view is local (it moves only this window) and never writes to
/// the document.
public enum NamedViews {
    /// The `custom_view` kind (`NodeProps.custom_view`).
    public static let kind: UInt32 = 260
    /// `CommonProps.name`.
    static let name = RegisterPath([kind, 1, 1])
    /// `CustomViewProps.target`.
    static let target = RegisterPath([kind, 2])

    /// The live named views in menu order, after the read-time rules: only children of
    /// `settings` count (a view under any other parent is ignored), and a magnification outside
    /// 6%...25,600% is clamped (0, unset, reads 100%).
    public static func list(_ state: EngineState) -> [NamedView] {
        let nodes = state.liveChildren(WellKnown.settings).filter { state.store.kind($0) == kind }
        return nodes.enumerated().map { index, node in
            let props = state.props(node).customView
            return NamedView(id: node, storedName: props.common.name, number: index + 1, target: NamedViewTarget(props.target))
        }
    }

    /// The live view `id`, or nil (deleted, unknown or not a named view).
    public static func view(_ id: OpID, in state: EngineState) -> NamedView? {
        list(state).first { $0.id == id }
    }

    /// The Zoom tool's kbd:[Shift]-drag: the target that fits `rect` (pasteboard) in a view of
    /// `viewSize` points, centred, at the largest magnification that shows all of it (clamped),
    /// in drawing mode `mode`.  The New View sheet opens with it.
    public static func target(fitting rect: Rect, viewSize: Size, mode: Wiretuner_Doc_V1_DrawingMode) -> NamedViewTarget {
        let width = max(rect.width, 1e-9), height = max(rect.height, 1e-9)
        let magnification = NamedViewTarget.clamped(min(viewSize.width / width, viewSize.height / height))
        let origin = Point(x: rect.midX - viewSize.width / 2 / magnification, y: rect.midY - viewSize.height / 2 / magnification)
        return NamedViewTarget(magnification: magnification, scrollOrigin: origin, mode: mode)
    }

    static func requireView(_ id: OpID, in state: EngineState) throws -> NamedView {
        guard let view = view(id, in: state) else { throw NamedViewError.notAView(id) }
        return view
    }

    static func values(_ body: (inout Wiretuner_Doc_V1_CustomViewProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        var view = Wiretuner_Doc_V1_CustomViewProps()
        body(&view)
        props.customView = view
        return props
    }
}

/// Why a named-view command could not build its change.
public enum NamedViewError: Error, Equatable, Sendable {
    case notAView(OpID)
}

/// A place in the document: magnification, the pasteboard point at the window's top-left and the
/// drawing mode.  No rotation: the angle someone holds their trackpad at is not a place.
public struct NamedViewTarget: Hashable, Sendable {
    public var magnification: Double
    public var scrollOrigin: Point
    public var mode: Wiretuner_Doc_V1_DrawingMode

    public init(magnification: Double, scrollOrigin: Point, mode: Wiretuner_Doc_V1_DrawingMode = .preview) {
        self.magnification = magnification
        self.scrollOrigin = scrollOrigin
        self.mode = mode
    }

    /// The stored target read with the clamp.
    init(_ stored: Wiretuner_Doc_V1_ViewTarget) {
        magnification = Self.clamped(stored.magnification == 0 ? 1 : stored.magnification)
        scrollOrigin = Point(x: stored.scrollOrigin.x.isFinite ? stored.scrollOrigin.x : 0, y: stored.scrollOrigin.y.isFinite ? stored.scrollOrigin.y : 0)
        mode = stored.mode
    }

    /// `magnification` clamped to 6%...25,600% (100% when not finite).
    static func clamped(_ magnification: Double) -> Double {
        guard magnification.isFinite else { return 1 }
        return min(max(magnification, 0.06), 256)
    }

    /// The stored value, magnification clamped.
    var proto: Wiretuner_Doc_V1_ViewTarget {
        var value = Wiretuner_Doc_V1_ViewTarget()
        value.magnification = Self.clamped(magnification)
        value.scrollOrigin = PathEditing.proto(scrollOrigin)
        value.mode = mode
        return value
    }
}

/// One named view as the Custom submenu, the magnification pop-up and the Edit Views sheet list it.
public struct NamedView: Hashable, Sendable, Identifiable {
    public var id: OpID
    /// `CommonProps.name` as stored (may be empty).
    public var storedName: String
    /// The view's 1-based place in the menu.
    public var number: Int
    public var target: NamedViewTarget

    /// The name the menu shows: the stored name, or "View n".
    public var name: String { storedName.isEmpty ? "View \(number)" : storedName }
}

/// menu:View[Custom > New…] and the Zoom tool's kbd:[Shift]-drag: a named view after the others,
/// "New View".
public struct CreateCustomView: Command {
    public var name: String
    public var target: NamedViewTarget
    public var label: String { "New View" }

    public init(name: String, target: NamedViewTarget) {
        self.name = name
        self.target = target
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let last = state.liveChildren(WellKnown.settings).last.flatMap { state.store.placement($0)?.position }
        let position = try PathEditing.keys(between: last, and: nil, count: 1)[0]
        let props = NamedViews.values { view in
            view.common.name = String(name.prefix(256))
            view.target = target.proto
        }
        builder.append(Ops.create(parent: WellKnown.settings, position: position, props: props))
    }
}

/// The Edit Views sheet's btn:[Redefine]: the view takes the window's current target, one ATOMIC
/// write, "Redefine View".
public struct RedefineCustomView: Command {
    public var view: OpID
    public var target: NamedViewTarget
    public var label: String { "Redefine View" }

    public init(_ view: OpID, target: NamedViewTarget) {
        self.view = view
        self.target = target
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try NamedViews.requireView(view, in: state)
        builder.append(Ops.set(view, [NamedViews.target], values: NamedViews.values { $0.target = target.proto }))
    }
}

/// The Edit Views sheet's inline rename, "Rename View".  An empty name reads as "View n".
public struct RenameCustomView: Command {
    public var view: OpID
    public var name: String
    public var label: String { "Rename View" }

    public init(_ view: OpID, to name: String) {
        self.view = view
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try NamedViews.requireView(view, in: state)
        let name = String(self.name.prefix(256))
        guard name != current.storedName else { return }
        builder.append(Ops.set(view, [NamedViews.name], values: NamedViews.values { $0.common.name = name }))
    }
}

/// The Edit Views sheet's btn:[Delete], "Delete View".
public struct DeleteCustomView: Command {
    public var views: [OpID]
    public var label: String { "Delete View" }

    public init(_ views: [OpID]) {
        self.views = views
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let live = Set(NamedViews.list(state).map(\.id))
        var seen: Set<OpID> = []
        for view in views where live.contains(view) && seen.insert(view).inserted {
            builder.append(Ops.setDeleted(view))
        }
    }
}

/// The Edit Views sheet's drag-reorder: a `MoveNode` under `settings` to menu place `index`
/// (0-based, clamped) among the named views, "Reorder Views".
public struct MoveCustomView: Command {
    public var view: OpID
    public var index: Int
    public var label: String { "Reorder Views" }

    public init(_ view: OpID, to index: Int) {
        self.view = view
        self.index = index
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try NamedViews.requireView(view, in: state)
        var others = NamedViews.list(state).map(\.id)
        others.removeAll { $0 == view }
        let target = min(max(index, 0), others.count)
        guard target != current.number - 1 else { return }
        let key: (OpID) -> [UInt8]? = { state.store.placement($0)?.position }
        let lo = target > 0 ? key(others[target - 1]) : nil
        let hi = target < others.count ? key(others[target]) : nil
        let position = try PathEditing.keys(between: lo, and: hi, count: 1)[0]
        builder.append(Ops.move(view, parent: WellKnown.settings, position: position))
    }
}

/// menu:View[Custom > Previous] (the local `ViewState.previous_view` pair, never shared): the two
/// most recently recalled named views.  Previous recalls the one before the latest, swapping the
/// pair, and needs two live views in it; a deleted view drops out of the pair.
public struct NamedViewRecall: Hashable, Sendable {
    /// The view recalled last.
    public var latest: OpID?
    /// The one before it.
    public var before: OpID?

    public init(latest: OpID? = nil, before: OpID? = nil) {
        self.latest = latest
        self.before = before
    }

    /// The pair `ViewState` holds (`previous_view`, `previous_view_2`; zero ids read as unset).
    public init(_ state: Wiretuner_Doc_V1_ViewState) {
        latest = state.hasPreviousView ? OpID(state.previousView) : nil
        before = state.hasPreviousView2 ? OpID(state.previousView2) : nil
    }

    /// Writes the pair into `viewState`.
    public func store(into viewState: inout Wiretuner_Doc_V1_ViewState) {
        if let latest { viewState.previousView = latest.proto } else { viewState.clearPreviousView() }
        if let before { viewState.previousView2 = before.proto } else { viewState.clearPreviousView2() }
    }

    /// After recalling `view` (from the menu, the pop-up or Previous).
    public mutating func recalled(_ view: OpID) {
        guard view != latest else { return }
        before = latest
        latest = view
    }

    /// The pair with deleted views dropped (the later one moves up).
    public func live(in state: EngineState) -> NamedViewRecall {
        let views = Set(NamedViews.list(state).map(\.id))
        let kept = [latest, before].compactMap { $0 }.filter(views.contains)
        return NamedViewRecall(latest: kept.first, before: kept.count > 1 ? kept[1] : nil)
    }

    /// Whether Previous is enabled: two live recalled views.
    public func canGoBack(in state: EngineState) -> Bool {
        live(in: state).before != nil
    }

    /// Previous: the view to recall (the one before the latest), with the pair swapped; nil when
    /// disabled.
    public func previous(in state: EngineState) -> (view: NamedView, recall: NamedViewRecall)? {
        let pair = live(in: state)
        guard let before = pair.before, let latest = pair.latest, let view = NamedViews.view(before, in: state) else { return nil }
        return (view, NamedViewRecall(latest: before, before: latest))
    }
}
