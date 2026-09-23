// A PDF content stream being written: operators with numbers at five decimals.  The PDF operator
// set is the Core Graphics drawing model, so the display list maps onto it one to one.

import Foundation
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

struct PDFContent {
    private(set) var text = ""

    var data: Data { Data(text.utf8) }

    mutating func op(_ operation: String) {
        text += operation
        text += "\n"
    }

    static func n(_ value: Double) -> String {
        PDFValue.number(value)
    }

    mutating func transform(_ t: AffineTransform) {
        guard !t.isIdentity else { return }
        op("\([t.a, t.b, t.c, t.d, t.tx, t.ty].map(PDFContent.n).joined(separator: " ")) cm")
    }

    /// The path's construction operators (quadratics raised to cubics).
    mutating func path(_ path: DisplayPath) {
        var current = Point.zero
        var start = Point.zero
        for element in path.elements {
            switch element {
            case .move(let p):
                op("\(PDFContent.n(p.x)) \(PDFContent.n(p.y)) m")
                current = p
                start = p
            case .line(let p):
                op("\(PDFContent.n(p.x)) \(PDFContent.n(p.y)) l")
                current = p
            case .quadCurve(let control, let end):
                let c1 = current + (control - current) * (2.0 / 3.0)
                let c2 = end + (control - end) * (2.0 / 3.0)
                op("\(PDFContent.n(c1.x)) \(PDFContent.n(c1.y)) \(PDFContent.n(c2.x)) \(PDFContent.n(c2.y)) \(PDFContent.n(end.x)) \(PDFContent.n(end.y)) c")
                current = end
            case .cubicCurve(let c1, let c2, let end):
                op("\(PDFContent.n(c1.x)) \(PDFContent.n(c1.y)) \(PDFContent.n(c2.x)) \(PDFContent.n(c2.y)) \(PDFContent.n(end.x)) \(PDFContent.n(end.y)) c")
                current = end
            case .close:
                op("h")
                current = start
            }
        }
    }

    /// A rectangle path.
    mutating func rectangle(_ rect: Rect) {
        op("\(PDFContent.n(rect.minX)) \(PDFContent.n(rect.minY)) \(PDFContent.n(rect.width)) \(PDFContent.n(rect.height)) re")
    }

    /// Stroke parameters; `hairlineWidth` replaces a zero width.
    mutating func strokeStyle(_ style: StrokeStyle, hairlineWidth: Double) {
        op("\(PDFContent.n(style.isHairline ? hairlineWidth : style.width)) w")
        switch style.cap {
        case .butt: op("0 J")
        case .round: op("1 J")
        case .square: op("2 J")
        }
        switch style.join {
        case .miter: op("0 j \(PDFContent.n(max(style.miterLimit, 1))) M")
        case .round: op("1 j")
        case .bevel: op("2 j")
        }
        let dash = style.effectiveDash
        if !dash.isEmpty {
            op("[\(dash.map(PDFContent.n).joined(separator: " "))] \(PDFContent.n(style.dashPhase)) d")
        }
    }
}
