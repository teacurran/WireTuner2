import AppKit
import CoreText
import WTGeometry
import WTRender

/// Draws the selection into the canvas overlay, under the active tool's own overlay: the
/// local selection as outlines in the accent colour with its anchors (sub-selected ones
/// filled), and every collaborator's selection as a 1 px rectangle in their colour, outset
/// from the object's bounds so it never covers handles, with a name tag at its top-right
/// corner (selecting.adoc, "Client"; presence.adoc, "Selections and carets").  Several people
/// on one object get nested rectangles, 2 px apart, their tags stacked upward.  Objects that do
/// not resolve (deleted, or not received yet) draw nothing.  The geometry is computed apart
/// from the drawing so tests assert on it.
@MainActor
struct SelectionOverlay {
    static let anchorSize = 5.0
    static let remoteOutset = 3.0
    static let nestSpacing = 2.0
    static let tagFontSize = 10.0
    static let tagPadding = 3.0

    let document: DocumentHandle
    let viewport: Viewport

    /// One locally selected object: its outline in view points and its anchors.
    struct Outline: Equatable {
        let id: SelectionID
        let path: CGPath
        let anchors: [Anchor]
    }

    struct Anchor: Equatable {
        let reference: PointReference
        let viewPoint: Point
        let isSelected: Bool
    }

    /// One collaborator's mark on one object.
    struct RemoteMark: Equatable {
        let participantID: String
        let name: String
        let color: Color
        let id: SelectionID
        /// The outline rectangle, view points.
        let rect: Rect
        /// How many earlier participants marked the same object.
        let nesting: Int
        /// The name tag's rectangle, view points: its right edge on `rect`'s, stacked above.
        let tagRect: Rect
    }

    // MARK: Geometry

    /// The non-group primitives under `item` with their index paths, in draw order.
    static func leaves(of item: DisplayItem, path: [Int]) -> [(path: [Int], item: DisplayItem)] {
        guard case let .group(group) = item else { return [(path, item)] }
        return group.children.enumerated().flatMap { leaves(of: $0.element, path: path + [$0.offset]) }
    }

    /// The shape and transform of a leaf: path items by their path, images and text by their
    /// frame (a group, never a leaf, has no shape of its own).  The display list's transforms are already flattened, so a child's transform is
    /// its whole transform.
    static func shape(of leaf: DisplayItem) -> (path: DisplayPath, transform: WTGeometry.AffineTransform) {
        switch leaf {
        case let .fill(item): (item.path, item.transform)
        case let .stroke(item): (item.path, item.transform)
        case let .path(item): (item.path, item.transform)
        case let .image(item): (DisplayPath(rect: item.rect), item.transform)
        case let .text(item): (DisplayPath(rect: item.bounds), item.transform)
        case .group: (DisplayPath(), .identity)
        }
    }

    /// Where each element of `path` ends (its anchor), by element index; `close` has none.
    static func anchorPoints(of path: DisplayPath) -> [(element: Int, point: Point)] {
        path.elements.enumerated().compactMap { index, element in
            switch element {
            case let .move(point), let .line(point): (index, point)
            case let .quadCurve(_, end), let .cubicCurve(_, _, end): (index, end)
            case .close: nil
            }
        }
    }

    static func add(_ path: DisplayPath, transform: WTGeometry.AffineTransform, to cgPath: CGMutablePath) {
        let t = transform
        for element in path.elements {
            switch element {
            case let .move(point): cgPath.move(to: t.apply(point).cgPoint)
            case let .line(point): cgPath.addLine(to: t.apply(point).cgPoint)
            case let .quadCurve(control, end): cgPath.addQuadCurve(to: t.apply(end).cgPoint, control: t.apply(control).cgPoint)
            case let .cubicCurve(c1, c2, end): cgPath.addCurve(to: t.apply(end).cgPoint, control1: t.apply(c1).cgPoint, control2: t.apply(c2).cgPoint)
            case .close: cgPath.closeSubpath()
            }
        }
    }

    /// The local selection's outlines, in selection order.
    func outlines(for selection: Selection) -> [Outline] {
        let toView = viewport.pasteboardToView
        return selection.ids.compactMap { id -> Outline? in
            guard let item = document.item(for: id) else { return nil }
            let selectedPoints: Set<PointReference>
            if case let .points(points) = selection.subSelection(of: id) { selectedPoints = points } else { selectedPoints = [] }
            let cgPath = CGMutablePath()
            var anchors: [Anchor] = []
            for leaf in Self.leaves(of: item, path: id.indexPath) {
                let shape = Self.shape(of: leaf.item)
                let transform = shape.transform.concatenating(toView)
                Self.add(shape.path, transform: transform, to: cgPath)
                for anchor in Self.anchorPoints(of: shape.path) {
                    let reference = PointReference(leafPath: leaf.path, element: anchor.element)
                    anchors.append(Anchor(reference: reference, viewPoint: transform.apply(anchor.point), isSelected: selectedPoints.contains(reference)))
                }
            }
            return Outline(id: id, path: cgPath, anchors: anchors)
        }
    }

    /// The width of a name tag reading `name`.
    static func tagSize(for name: String) -> Size {
        let line = CTLineCreateWithAttributedString(tagString(name))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return Size(width: width.rounded(.up) + 2 * tagPadding, height: tagFontSize + 2 * tagPadding)
    }

    /// The tag's text: white on the participant's colour.
    static func tagString(_ name: String) -> NSAttributedString {
        NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: tagFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }

    /// Every collaborator's marks, participants in the order given.
    func remoteMarks(for participants: [RemoteParticipant]) -> [RemoteMark] {
        let toView = viewport.pasteboardToView
        var nestingByID: [SelectionID: Int] = [:]
        var marks: [RemoteMark] = []
        for participant in participants {
            for id in participant.selection {
                guard let bounds = document.item(for: id)?.bounds else { continue }
                let nesting = nestingByID[id, default: 0]
                nestingByID[id] = nesting + 1
                let outset = Self.remoteOutset + Double(nesting) * Self.nestSpacing
                let rect = bounds.applying(toView).expanded(by: outset)
                let size = Self.tagSize(for: participant.name)
                let tag = Rect(x: rect.maxX - size.width, y: rect.minY - Double(nesting + 1) * size.height, width: size.width, height: size.height)
                marks.append(RemoteMark(
                    participantID: participant.id, name: participant.name, color: participant.color, id: id,
                    rect: rect, nesting: nesting, tagRect: tag
                ))
            }
        }
        return marks
    }

    // MARK: Drawing

    /// Draws into the overlay context (view points, y down).
    func draw(in ctx: CGContext, selection: Selection, participants: [RemoteParticipant], showsRemote: Bool, accent: CGColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if showsRemote {
            for mark in remoteMarks(for: participants) { draw(mark, in: ctx) }
        }
        ctx.setLineWidth(1)
        ctx.setStrokeColor(accent)
        for outline in outlines(for: selection) {
            ctx.addPath(outline.path)
            ctx.strokePath()
            for anchor in outline.anchors {
                let half = Self.anchorSize / 2
                let square = CGRect(x: anchor.viewPoint.x - half, y: anchor.viewPoint.y - half, width: Self.anchorSize, height: Self.anchorSize)
                ctx.setFillColor(anchor.isSelected ? accent : CGColor.white)
                ctx.fill(square)
                ctx.stroke(square)
            }
        }
    }

    private func draw(_ mark: RemoteMark, in ctx: CGContext) {
        let color = mark.color.cgColor
        ctx.setLineWidth(1)
        ctx.setStrokeColor(color)
        ctx.stroke(mark.rect.cgRect.insetBy(dx: 0.5, dy: 0.5))
        ctx.setFillColor(color)
        ctx.fill(mark.tagRect.cgRect)
        // The overlay context is y-down; text needs its own flip to stand upright.
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: mark.tagRect.minX + Self.tagPadding, y: mark.tagRect.maxY - Self.tagPadding - 2)
        CTLineDraw(CTLineCreateWithAttributedString(Self.tagString(mark.name)), ctx)
        ctx.restoreGState()
    }
}
