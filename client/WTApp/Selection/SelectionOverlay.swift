import AppKit
import CoreText
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// Draws the selection into the canvas overlay, under the active tool's own overlay: the
/// local selection as outlines in the accent colour with its point glyphs (vector-basics.adoc,
/// "Client", DRAW-003: squares, and for selected curve and connector points circles and
/// triangles; half size with *Smaller handles*; filled or outlined by *Show solid points*; the
/// handles of selected points as 1 px lines ending in a small circle), all in screen space so
/// they keep their size at any zoom, and every collaborator's selection as a 1 px rectangle in their colour, outset
/// from the object's bounds so it never covers handles, with a name tag at its top-right
/// corner (selecting.adoc, "Client"; presence.adoc, "Selections and carets").  Several people
/// on one object get nested rectangles, 2 px apart, their tags stacked upward.  Objects that do
/// not resolve (deleted, or not received yet) draw nothing.  The geometry is computed apart
/// from the drawing so tests assert on it.
@MainActor
struct SelectionOverlay {
    nonisolated static let anchorSize = 5.0
    static let remoteOutset = 3.0
    static let nestSpacing = 2.0
    static let tagFontSize = 10.0
    static let tagPadding = 3.0

    static let handleEndRadius = 2.0

    let document: DocumentHandle
    let viewport: Viewport
    var glyphs = GlyphStyle()

    /// How point glyphs look (the *Smaller handles* and *Show solid points* preferences).
    struct GlyphStyle: Equatable, Sendable {
        var smallerHandles = false
        var solidPoints = true

        /// The glyph's side (or diameter), view points.
        var size: Double { smallerHandles ? SelectionOverlay.anchorSize / 2 : SelectionOverlay.anchorSize }
    }

    /// The shape a point is drawn as.
    enum GlyphShape: Equatable, Sendable {
        case square, circle, triangle
    }

    /// One locally selected object: its outline in view points, its anchors and the handles of
    /// its selected points.
    struct Outline: Equatable {
        let id: SelectionID
        let path: CGPath
        let anchors: [Anchor]
        let handles: [Handle]
    }

    struct Anchor: Equatable {
        let reference: PointReference
        let viewPoint: Point
        let kind: PointKind
        let isSelected: Bool

        /// Unselected curve and connector points draw as squares like corners.
        var shape: GlyphShape {
            guard isSelected else { return .square }
            switch kind {
            case .corner: return .square
            case .curve: return .circle
            case .connector: return .triangle
            }
        }
    }

    /// A handle line from an anchor to its control point, view points.
    struct Handle: Equatable {
        let anchor: Point
        let end: Point
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

    /// The local selection's outlines, in selection order.  A path, rectangle or ellipse is
    /// outlined from its model geometry with a glyph per point; a group by its members' items.
    func outlines(for selection: Selection) -> [Outline] {
        let toView = viewport.pasteboardToView
        return selection.ids.compactMap { id -> Outline? in
            guard let object = document.object(for: id), let item = document.item(for: id) else { return nil }
            let selectedPoints: Set<PointReference>
            if case let .points(points) = selection.subSelection(of: id) { selectedPoints = points } else { selectedPoints = [] }
            let cgPath = CGMutablePath()
            var anchors: [Anchor] = []
            var handles: [Handle] = []
            guard let path = object.path else {
                for leaf in Self.leaves(of: item, path: object.itemPath) {
                    let shape = Self.shape(of: leaf.item)
                    Self.add(shape.path, transform: shape.transform.concatenating(toView), to: cgPath)
                }
                return Outline(id: id, path: cgPath, anchors: [], handles: [])
            }
            let transform = object.transform.concatenating(toView)
            for contour in path.contours where contour.isRenderable {
                Self.add(DocumentDisplayListBuilder.display(VectorPath(contours: [contour])) { _ in true }.path, transform: transform, to: cgPath)
                for point in contour.drawn {
                    let reference = PointReference(node: id.node, contour: contour.id, point: point.id)
                    let selected = selectedPoints.contains(reference)
                    let anchor = transform.apply(point.anchor)
                    anchors.append(Anchor(reference: reference, viewPoint: anchor, kind: point.kind, isSelected: selected))
                    guard selected else { continue }
                    for handle in [point.inHandle, point.outHandle] where handle != .zero {
                        handles.append(Handle(anchor: anchor, end: transform.apply(point.anchor + handle)))
                    }
                }
            }
            return Outline(id: id, path: cgPath, anchors: anchors, handles: handles)
        }
    }

    /// The glyph path of `anchor` at `size` (view points).
    static func glyphPath(_ anchor: Anchor, size: Double) -> CGPath {
        let half = size / 2
        let rect = CGRect(x: anchor.viewPoint.x - half, y: anchor.viewPoint.y - half, width: size, height: size)
        switch anchor.shape {
        case .square:
            return CGPath(rect: rect, transform: nil)
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .triangle:
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
            path.closeSubpath()
            return path
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
            for mark in remoteMarks(for: participants) { drawMark(mark, in: ctx) }
        }
        ctx.setLineWidth(1)
        ctx.setStrokeColor(accent)
        for outline in outlines(for: selection) {
            ctx.addPath(outline.path)
            ctx.strokePath()
            for handle in outline.handles {
                ctx.move(to: handle.anchor.cgPoint)
                ctx.addLine(to: handle.end.cgPoint)
                ctx.strokePath()
                let r = Self.handleEndRadius
                ctx.strokeEllipse(in: CGRect(x: handle.end.x - r, y: handle.end.y - r, width: 2 * r, height: 2 * r))
            }
            for anchor in outline.anchors {
                let glyph = Self.glyphPath(anchor, size: glyphs.size)
                // Solid points: unselected points filled, selected ones hollow; outlined points
                // the other way round, so a selected point always stands out.
                let filled = anchor.isSelected != glyphs.solidPoints
                ctx.setFillColor(filled ? accent : CGColor.white)
                ctx.addPath(glyph)
                ctx.drawPath(using: .fillStroke)
            }
        }
    }

    /// One collaborator's outline and name tag.
    func drawMark(_ mark: RemoteMark, in ctx: CGContext) {
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
