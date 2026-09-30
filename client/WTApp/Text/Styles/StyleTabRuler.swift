import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Style Behavior sheet's text ruler (text-styles.adoc, "Style behavior"; TYPE-035): the text
/// ruler (`TextRulerView`, TYPE-023) over the style's tab stops and indents instead of a
/// paragraph's.  Its gestures edit the sheet's settings -- a stop dropped from the well, dragged,
/// Option-dragged into a copy or dragged off, an indent marker dragged -- and btn:[OK] writes them
/// (`TextStyleBehaviorModel.command`); *No selection* beside it unsets the tabs and indents.
@MainActor
struct StyleTabRuler: TextRulerSource {
    /// The ruler's length, points (one view point each).
    static let length = 300.0

    let model: TextStyleBehaviorModel

    var width: Double { Self.length }
    var scale: Double { 1 }

    var stops: [(id: OpID, stop: Wiretuner_Doc_V1_TabStop)] {
        model.tabs.enumerated().map { (OpID(counter: UInt64($0.offset + 1), replica: 0), $0.element) }
    }

    var paragraph: Wiretuner_Doc_V1_ParagraphSettings { model.attrs.paragraph }
    var leftIndent: Double { paragraph.hasLeftIndent ? paragraph.leftIndent : 0 }
    var firstLine: Double { leftIndent + (paragraph.hasFirstLineIndent ? paragraph.firstLineIndent : 0) }
    var rightIndent: Double { width - (paragraph.hasRightIndent ? paragraph.rightIndent : 0) }

    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    func place(_ kind: Wiretuner_Doc_V1_TabKind, at position: Double) -> (any WTModel.Command)? {
        guard position >= 0, position <= width else { return nil }
        var tabs = model.tabs
        tabs.append(.with {
            $0.kind = kind
            $0.position = Self.rounded(position)
        })
        model.tabs = tabs
        return nil
    }

    func dragStop(from: Double, to: Double, offRuler: Bool, duplicate: Bool) -> (any WTModel.Command)? {
        guard let index = model.tabs.firstIndex(where: { abs($0.position - from) < TextTabs.tolerance }) else { return nil }
        var tabs = model.tabs
        if offRuler {
            if !duplicate { tabs.remove(at: index) }
        } else {
            var stop = tabs[index]
            stop.position = Self.rounded(min(max(to, 0), width))
            if duplicate { tabs.append(stop) } else { tabs[index] = stop }
        }
        model.tabs = tabs
        return nil
    }

    func dragIndent(_ indent: TextRulerModel.Indent, by delta: Double) -> (any WTModel.Command)? {
        guard delta.isFinite, delta != 0 else { return nil }
        let first = paragraph.hasFirstLineIndent ? paragraph.firstLineIndent : 0
        switch indent {
        case .left:
            // The left marker moves alone: the first line keeps its place.
            model.attrs.paragraph.leftIndent = leftIndent + delta
            model.attrs.paragraph.firstLineIndent = first - delta
        case .firstLine:
            model.attrs.paragraph.firstLineIndent = first + delta
        case .both:
            model.attrs.paragraph.leftIndent = leftIndent + delta
        case .right:
            model.attrs.paragraph.rightIndent = (paragraph.hasRightIndent ? paragraph.rightIndent : 0) - delta
        }
        return nil
    }
}

/// The ruler in the sheet: a `TextRulerView` showing `StyleTabRuler`.
struct StyleTabRulerView: NSViewRepresentable {
    let model: TextStyleBehaviorModel

    static func makeRuler(_ model: TextStyleBehaviorModel) -> TextRulerView {
        let view = TextRulerView(frame: NSRect(x: 0, y: 0, width: TextRulerView.wellWidth + StyleTabRuler.length + 8, height: TextRulerModel.height))
        view.setBoundsOrigin(NSPoint(x: -TextRulerView.wellWidth, y: 0))
        view.model = StyleTabRuler(model: model)
        view.setAccessibilityIdentifier("behavior.ruler")
        return view
    }

    func makeNSView(context: Context) -> TextRulerView { Self.makeRuler(model) }

    func updateNSView(_ view: TextRulerView, context: Context) {
        // Reading the settings here makes SwiftUI redraw the ruler when they change.
        _ = (model.tabs.count, model.attrs.paragraph)
        view.model = StyleTabRuler(model: model)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextRulerView, context: Context) -> CGSize? {
        nsView.frame.size
    }
}
