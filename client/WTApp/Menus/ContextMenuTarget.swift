import Foundation
import WTGeometry
import WTRender

/// The kinds of object a canvas context menu distinguishes (context-menus.adoc, "A single
/// object").  Until `WTModel` lands, hit testing can tell paths, text, bitmaps, groups and
/// clipping groups apart from the display list; the other kinds come from their epics' nodes
/// (and from stub targets in tests).
enum ContextObjectKind: String, CaseIterable, Hashable, Sendable {
    case path, text, bitmap, importedGraphic, group, blend, clip, connector, symbolInstance, chart, envelope

    var context: MenuContext {
        switch self {
        case .path: .path
        case .text: .text
        case .bitmap: .bitmap
        case .importedGraphic: .importedGraphic
        case .group: .group
        case .blend: .blend
        case .clip: .clip
        case .connector: .connector
        case .symbolInstance: .symbolInstance
        case .chart: .chart
        case .envelope: .envelope
        }
    }

    /// The kind a display item reads as.
    init(item: DisplayItem) {
        switch item {
        case .fill, .stroke, .path: self = .path
        case .image: self = .bitmap
        case .text: self = .text
        case let .group(group): self = group.clip == nil ? .group : .clip
        }
    }
}

/// What a context menu is for (context-menus.adoc; BASIC-018 and BASIC-019).
enum ContextMenuTarget: Equatable, Sendable {
    /// One object, or a selection containing the object clicked.
    case objects([ContextObjectKind])
    /// Empty pasteboard, or a page when `overPage`.
    case pasteboard(overPage: Bool)
    case guide(locked: Bool)
    /// A collaborator's cursor or selection outline.
    case presence(participantID: String, name: String)
    /// A row or empty area of a panel: the owning panel's registered commands for `context`.
    case panel(MenuContext)
    /// A document tab.
    case tab
    /// The text menu while a text-editing session is active.
    case textEditing

    /// The contexts whose registered commands join the menu (feature epics add commands with
    /// `contexts` and they appear without editing the catalog).
    var contexts: Set<MenuContext> {
        switch self {
        case let .objects(kinds):
            var result = Set(kinds.map(\.context))
            if kinds.count > 1 { result.insert(.multiple) }
            return result
        case let .pasteboard(overPage): return overPage ? [.pasteboard, .page] : [.pasteboard]
        case .guide: return [.guide]
        case .presence: return [.presence]
        case let .panel(context): return [context]
        case .tab: return [.tab]
        case .textEditing: return [.textEditing]
        }
    }

    /// Replaces `<name>` in presence titles.
    var name: String? {
        if case let .presence(_, name) = self { return name }
        return nil
    }
}

/// Finds what is under a canvas point: the topmost object (REND-003 through the selection
/// controller), a guide, a presence marker, a page, or the pasteboard.  Guides and presence
/// markers come from hooks their epics fill (GRID and SYNC-009); both answer nothing until then.
@MainActor
struct ContextMenuResolver {
    var guide: @MainActor (Point) -> ContextMenuTarget? = { _ in nil }
    var presence: @MainActor (Point) -> ContextMenuTarget? = { _ in nil }

    /// The target at `viewPoint`, applying the select-before-menu rule: an object outside the
    /// selection is selected first (as the Pointer would); one inside it keeps the selection
    /// and the menu is for all of it.  Empty pasteboard leaves the selection alone.
    func target(at viewPoint: Point, viewport: Viewport, document: DocumentHandle, selection: SelectionController) -> ContextMenuTarget {
        if let hit = selection.pick(at: viewPoint, viewport: viewport, subselect: false) {
            if !selection.model.selection.contains(hit.id) {
                selection.model.set(Selection([hit.id]))
            }
            let kinds = selection.model.ids.compactMap { id in
                document.object(for: id).map { $0.kind == .blend ? .blend : ContextObjectKind(item: $0.item) }
            }
            return .objects(kinds.isEmpty ? [.path] : kinds)
        }
        if let guide = guide(viewPoint) { return guide }
        if let presence = presence(viewPoint) { return presence }
        let point = viewport.toPasteboard(viewPoint)
        return .pasteboard(overPage: document.pages.contains { $0.contains(point) })
    }
}
