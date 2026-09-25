// Printer's marks and labels (PRINT-006; docs/_includes/printing/printing.adoc, "Printer's
// marks, bleed and labels").  Marks are laid out in paper space -- points, origin at the paper's
// top-left, y down -- around the printed page, so they keep their size and their 0.25 pt line
// weight at every scale; they are drawn in registration colour (black on every plate).  Crop
// marks start `gap` outside the bleed, so a bleed moves them outward by its printed width;
// registration targets sit centred on each side; labels are set in the margin.

import CoreGraphics
import CoreText
import Foundation
import WTGeometry

/// One mark, in paper space.
public enum PrinterMark: Hashable, Sendable {
    /// A crop or tile mark: a hairline from `from` to `to`.
    case line(from: Point, to: Point)
    /// A registration target: a circle with a cross through it.
    case registration(center: Point, radius: Double)

    /// The paper area the mark paints, its line weight included.
    public var bounds: Rect {
        let half = PrinterMarks.lineWidth / 2
        switch self {
        case .line(let from, let to):
            return Rect(from, to).expanded(by: half)
        case .registration(let center, let radius):
            let reach = radius * PrinterMarks.registrationCross + half
            return Rect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
        }
    }
}

/// A line of label text in the sheet's margin.
public struct SheetLabel: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case leading, trailing }

    public var text: String
    /// The baseline's anchor: its left end (`leading`) or right end (`trailing`), paper space.
    public var anchor: Point
    public var alignment: Alignment

    public init(text: String, anchor: Point, alignment: Alignment = .leading) {
        self.text = text
        self.anchor = anchor
        self.alignment = alignment
    }

    /// The label's typeset line.
    var line: CTLine {
        let attributes: [CFString: Any] = [kCTFontAttributeName: PrinterMarks.font, kCTForegroundColorFromContextAttributeName: true]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(string)
    }

    /// The width of the typeset text.
    public var width: Double {
        Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Where the baseline starts.
    public var origin: Point {
        alignment == .leading ? anchor : Point(x: anchor.x - width, y: anchor.y)
    }

    /// The paper area the text covers (ascender to descender).
    public var bounds: Rect {
        let size = PrinterMarks.fontSize
        return Rect(x: origin.x, y: anchor.y - size * 0.8, width: width, height: size)
    }
}

/// Mark sizes and drawing.
public enum PrinterMarks {
    /// Every mark's line weight, points.
    public static let lineWidth = 0.25
    /// A crop mark's length.
    public static let length = 18.0
    /// The space between the bleed (or the page) and a mark.
    public static let gap = 6.0
    /// A registration target's radius.
    public static let radius = 5.0
    /// How far a target's cross reaches, in radii.
    static let registrationCross = 1.5
    /// Label type size.
    public static let fontSize = 6.5
    /// The margin the marks need around the printed page: what *Fit on paper* and tiling leave.
    public static let margin = gap + length + gap

    nonisolated(unsafe) static let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)

    /// Crop marks at the corners of `trim` (paper) that `corners` keeps, `inset` (the printed
    /// bleed per axis) outside it plus the gap.
    static func crop(trim: Rect, bleed: (x: Double, y: Double), corners: (Point) -> Bool = { _ in true }) -> [PrinterMark] {
        var marks: [PrinterMark] = []
        let dx = gap + bleed.x, dy = gap + bleed.y
        for (x, sx) in [(trim.minX, -1.0), (trim.maxX, 1.0)] {
            for (y, sy) in [(trim.minY, -1.0), (trim.maxY, 1.0)] where corners(Point(x: x, y: y)) {
                marks.append(.line(from: Point(x: x + sx * dx, y: y), to: Point(x: x + sx * (dx + length), y: y)))
                marks.append(.line(from: Point(x: x, y: y + sy * dy), to: Point(x: x, y: y + sy * (dy + length))))
            }
        }
        return marks
    }

    /// Registration targets centred on each side of `frame` (the printed area, paper).
    static func registration(frame: Rect) -> [PrinterMark] {
        let reach = gap + length / 2
        return [
            .registration(center: Point(x: frame.midX, y: frame.minY - reach), radius: radius),
            .registration(center: Point(x: frame.midX, y: frame.maxY + reach), radius: radius),
            .registration(center: Point(x: frame.minX - reach, y: frame.midY), radius: radius),
            .registration(center: Point(x: frame.maxX + reach, y: frame.midY), radius: radius),
        ]
    }

    /// Draws `marks` and `labels` into `context`, whose user space is paper space (y down), in
    /// registration colour: black, which is 100% on every plate.
    public static func draw(_ marks: [PrinterMark], labels: [SheetLabel], into context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let black = CGColor(gray: 0, alpha: 1)
        context.setStrokeColor(black)
        context.setFillColor(black)
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)
        for mark in marks {
            switch mark {
            case .line(let from, let to):
                context.move(to: CGPoint(x: from.x, y: from.y))
                context.addLine(to: CGPoint(x: to.x, y: to.y))
            case .registration(let center, let radius):
                let reach = radius * registrationCross
                context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.move(to: CGPoint(x: center.x - reach, y: center.y))
                context.addLine(to: CGPoint(x: center.x + reach, y: center.y))
                context.move(to: CGPoint(x: center.x, y: center.y - reach))
                context.addLine(to: CGPoint(x: center.x, y: center.y + reach))
            }
        }
        context.strokePath()
        for label in labels {
            let origin = label.origin
            context.saveGState()
            // Paper space is y down; text is set y up about its baseline.
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(label.line, context)
            context.restoreGState()
        }
    }
}
