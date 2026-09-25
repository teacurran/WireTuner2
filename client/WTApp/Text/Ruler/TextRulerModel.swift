import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The text ruler's model (tabs-indents.adoc, "The text ruler"; TYPE-023): what the ruler above
/// the Text tool's block shows -- its width, the tab stops and indent markers of the first
/// paragraph the selection touches, the default ticks every half inch past the last stop -- and
/// what its gestures write: one change at mouse-up, on every paragraph the selection touches.
/// Positions are ruler points: points from the column's left edge after the inset.
@MainActor
struct TextRulerModel {
    /// Default tabs every half inch.
    static let defaultSpacing = 36.0
    /// The ruler's height, view points.
    static let height = 20.0
    /// How far off the ruler a dragged stop is removed, view points.
    static let removeDistance = 20.0

    /// The five tab kinds of the tab well, in order.
    static let wellKinds: [Wiretuner_Doc_V1_TabKind] = [.left, .right, .center, .decimal, .wrapping]

    /// An indent marker.
    enum Indent: Equatable {
        case left, firstLine, both, right
    }

    let session: TextEditingSession
    let viewport: Viewport

    var node: OpID? { session.node }
    var text: TextNode? { session.text }

    /// The first paragraph the selection touches.
    var paragraph: TextParagraph? {
        guard let text else { return nil }
        return text.paragraphs(touching: session.selectedRange).first
    }

    var stops: [(id: OpID, stop: Wiretuner_Doc_V1_TabStop)] { paragraph.map(TextTabs.stops) ?? [] }

    /// The block's inset (the ruler's zero is after the left inset).
    var inset: Wiretuner_Doc_V1_Inset { text?.props.block.inset ?? .init() }

    /// The column width the ruler shows, points.
    var width: Double { max(session.localFrame.width - inset.left - inset.right, 0) }

    /// The default ticks: every half inch past the last set stop, up to the width.
    var defaultTicks: [Double] {
        let last = stops.map(\.stop.position).max() ?? 0
        var ticks: [Double] = []
        var position = (floor(last / Self.defaultSpacing) + 1) * Self.defaultSpacing
        while position <= width {
            ticks.append(position)
            position += Self.defaultSpacing
        }
        return ticks
    }

    /// The indent markers' positions (the first line's is relative to the left indent).
    var leftIndent: Double { paragraph?.props.leftIndent ?? 0 }
    var firstLine: Double { leftIndent + (paragraph?.props.firstLineIndent ?? 0) }
    var rightIndent: Double { width - (paragraph?.props.rightIndent ?? 0) }

    // MARK: Placement

    /// Container space → view points.
    private var toView: WTGeometry.AffineTransform { session.toPasteboard.concatenating(viewport.pasteboardToView) }

    /// The ruler's zero (the column's left edge after the inset, at the block's top) in view points.
    var origin: Point { toView.apply(Point(x: inset.left, y: 0)) }

    /// View points per ruler point, and the ruler's angle in view space (radians, y down).
    var scale: Double {
        let axis = toView.apply(Vector(dx: 1, dy: 0))
        return max(hypot(axis.dx, axis.dy), 0.0001)
    }

    var angle: Double {
        let axis = toView.apply(Vector(dx: 1, dy: 0))
        return atan2(axis.dy, axis.dx)
    }

    /// Ruler points of a distance along the ruler, view points.
    func position(_ viewX: Double) -> Double { viewX / scale }

    // MARK: Commands

    private func anchors() -> (Anchor, Anchor)? {
        guard let text else { return nil }
        let range = session.selectedRange
        return (text.anchor(at: range.lowerBound), text.anchor(at: range.upperBound))
    }

    /// Dropping a kind from the tab well at `position`.
    func place(_ kind: Wiretuner_Doc_V1_TabKind, at position: Double) -> (any WTModel.Command)? {
        guard let node, let (from, to) = anchors(), position >= 0, position <= width else { return nil }
        return AddTabStop(node: node, from: from, to: to, stop: .with {
            $0.kind = kind
            $0.position = position.rounded(toPlaces: 2)
        })
    }

    /// The end of a drag of the stop at `from`: moved to `to`, removed when dragged `offRuler`,
    /// duplicated with kbd:[Option].
    func dragStop(from: Double, to: Double, offRuler: Bool, duplicate: Bool) -> (any WTModel.Command)? {
        guard let node, let (start, end) = anchors() else { return nil }
        if offRuler { return duplicate ? nil : DeleteTabStop(node: node, from: start, to: end, at: from) }
        let clamped = min(max(to, 0), width).rounded(toPlaces: 2)
        if duplicate {
            let kind = stops.first { abs($0.stop.position - from) < TextTabs.tolerance }?.stop.kind ?? .left
            return place(kind, at: clamped)
        }
        guard abs(clamped - from) >= TextTabs.tolerance else { return nil }
        return SetTabStop(node: node, from: start, to: end, at: from, stop: .with { $0.position = clamped }, fields: [.position])
    }

    /// The end of a drag of an indent marker by `delta` ruler points.
    func dragIndent(_ indent: Indent, by delta: Double) -> (any WTModel.Command)? {
        guard let node, let (start, end) = anchors(), delta != 0, let props = paragraph?.props else { return nil }
        var value = Wiretuner_Doc_V1_ParagraphProps()
        let fields: [[UInt32]]
        let label: String
        switch indent {
        case .left:
            // The left marker moves alone: the first line keeps its place.
            value.leftIndent = props.leftIndent + delta
            value.firstLineIndent = props.firstLineIndent - delta
            fields = [[4], [6]]
            label = "Left Indent"
        case .firstLine:
            value.firstLineIndent = props.firstLineIndent + delta
            fields = [[6]]
            label = "First Line Indent"
        case .both:
            value.leftIndent = props.leftIndent + delta
            fields = [[4]]
            label = "Left Indent"
        case .right:
            value.rightIndent = props.rightIndent - delta
            fields = [[5]]
            label = "Right Indent"
        }
        for field in [value.leftIndent, value.firstLineIndent, value.rightIndent] where !field.isFinite { return nil }
        return SetParagraph(node: node, from: start, to: end, props: value, fields: fields, label: label)
    }
}

fileprivate extension Double {
    /// Rounded to `places` decimals.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
