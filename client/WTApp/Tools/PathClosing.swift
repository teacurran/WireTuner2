import AppKit
import WTGeometry
import WTModel

/// Closing and opening paths outside the Pen (pen-bezigon.adoc, "Closing and opening a path";
/// DRAW-023): the context menu's *Path > Close / Open* (menu:Modify[Close Path]) and a Pointer or
/// Subselect drag of one end point onto the other end of its open contour.  Each is one change:
/// the Object panel's `SetClosed` fan-out for the menu item, and for the drag the dragged end
/// point deleted with the contour closed, so the two ends become the one point the drag landed
/// on.
@MainActor
enum PathClosing {
    static let noPaths = "Select a path to close or open"

    /// The path section of `selection` (nil without a selected path).
    static func section(_ selection: Selection, document: DocumentHandle) -> ObjectPanelModel.PathSection? {
        ObjectPanelModel(document: document, selection: selection).path
    }

    /// The menu item's command: every selected path's contours closed, or opened when all are
    /// closed already.
    static func toggle(_ selection: Selection, document: DocumentHandle) -> (any WTModel.Command)? {
        guard let section = section(selection, document: document) else { return nil }
        return ObjectPanelModel(document: document, selection: selection).setClosed(section.closed != .on)
    }

    /// The menu item's title: *Open Path* when every selected contour is closed.
    static func title(_ selection: Selection, document: DocumentHandle) -> String {
        section(selection, document: document)?.closed == .on ? "Open Path" : "Close Path"
    }

    /// The drag of exactly one selected end point by `delta` (pasteboard) that lands within
    /// `tolerance` (pasteboard units) of its contour's other end: the dragged point deleted and the
    /// contour closed, labelled "Close Path".  Nil for any other move.
    static func dragClose(_ delta: Vector, selection: Selection, document: DocumentHandle, tolerance: Double) -> (any WTModel.Command)? {
        let references = selection.ids.flatMap { id -> [PointReference] in
            if case let .points(points)? = selection.subSelection(of: id) { return Array(points) }
            return []
        }
        guard references.count == 1, let reference = references.first,
              let object = document.object(for: SelectionID(reference.node)), object.kind == .path,
              let contour = object.path?.contour(reference.contour), !contour.closed else { return nil }
        let drawn = contour.drawn
        guard drawn.count >= 3, let first = drawn.first, let last = drawn.last else { return nil }
        let other: VectorPoint
        if first.id == reference.point {
            other = last
        } else if last.id == reference.point {
            other = first
        } else {
            return nil
        }
        let dragged = reference.point == first.id ? first : last
        let landed = object.transform.apply(dragged.anchor) + delta
        guard landed.distance(to: object.transform.apply(other.anchor)) <= tolerance else { return nil }
        return CommandBatch("Close Path", [
            DeletePoints(node: object.id, points: [(contour.id, dragged.id)]),
            SetClosed(node: object.id, closed: true, contours: [contour.id]),
        ])
    }

    /// menu:Modify[Close Path] / *Open Path*, the path context menu's *Close / Open*.
    static func command(target: @escaping @MainActor () -> ObjectEditing?) -> Command {
        Command(id: ContextMenuCatalog.ID.closePath, title: "Close Path", menu: MenuPath(ContextMenuCatalog.Menu.modify, section: 3),
                contexts: ContextMenuCatalog.objectContexts, keywords: ["open", "close", "path", "closed"],
                validation: {
                    guard let editing = target(), section(editing.selection.selection, document: editing.document) != nil else { return .disabled(noPaths) }
                    return CommandValidation(title: title(editing.selection.selection, document: editing.document))
                },
                action: .perform {
                    guard let editing = target(), let command = toggle(editing.selection.selection, document: editing.document) else { return }
                    editing.perform(command)
                })
    }
}
