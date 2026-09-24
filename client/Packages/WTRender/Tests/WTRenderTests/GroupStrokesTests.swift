import Testing
import WTGeometry
@testable import WTRender
import struct WTRender.StrokeStyle

/// OBJ-017: a group's *Transform as unit* -- off, member strokes keep their nominal width however
/// the group is scaled; on, they scale with it.
@Suite struct GroupStrokesTests {
    /// A horizontal 1 pt line member in a group scaled 300%, rendered at 1×, and the number of
    /// dark rows it paints in the middle column.
    static func paintedRows(asUnit: Bool) throws -> Int {
        let matrix = AffineTransform.scale(3).concatenating(.translation(x: 10, y: 40.5))
        let line = ReferenceCorpus.path(ReferenceCorpus.line(0, 0, 30, 0), [ReferenceCorpus.stroke(.black, width: 1)]).transformed(by: matrix)
        let group = DisplayItem.group(GroupItem(children: GroupStrokes.children([line], groupTransform: matrix, mode: GroupStrokeMode(transformAsUnit: asUnit))))
        let image = try #require(CoreGraphicsRenderer(background: .white).renderBitmap(ReferenceCorpus.list([group]), viewport: Viewport(size: Size(width: 128, height: 96))))
        let surface = try #require(BitmapSurface(drawing: image))
        return (0..<surface.height).filter { surface.pixel(x: 50, y: $0).red < 128 }.count
    }

    @Test func aGroupScaled300PercentStrokesAt1ptOffAnd3ptOn() throws {
        #expect(try Self.paintedRows(asUnit: false) == 1)
        #expect(try Self.paintedRows(asUnit: true) == 3)
    }

    @Test func nominalModeDividesEveryStrokeKindByTheGroupScale() {
        let nib = CalligraphicNib(width: 6, height: 3, angle: 30)
        let custom = CustomStroke(pattern: CustomStrokePattern.allCases[0], length: 12, spacing: 3)
        let strokes: [StrokePaint] = [
            StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 3, dash: [6, 3], dashPhase: 3)),
            StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 3), kind: .calligraphic(nib)),
            StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 3), kind: .custom(custom)),
        ]
        let path = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)),
                                             appearance: Appearance([.fill(FillPaint(paint: .solid(.black)))] + strokes.map(AppearanceItem.stroke))))
        let stroke = DisplayItem.stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), style: StrokeStyle(width: 3), paint: .solid(.black)))
        let fill = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), paint: .solid(.black)))
        let nested = DisplayItem.group(GroupItem(children: [stroke, fill]))
        let scaled = GroupStrokes.children([path, nested], groupTransform: .scale(3).concatenating(.rotation(radians: 0.4)), mode: .nominal)
        guard case .path(let item) = scaled[0], case .group(let group) = scaled[1], case .stroke(let flat) = group.children[0] else {
            Issue.record("unexpected items")
            return
        }
        #expect(group.children[1] == fill)
        #expect(flat.style.width == 1)
        let paints = item.appearance.items.compactMap { element -> StrokePaint? in
            if case .stroke(let stroke) = element { return stroke } else { return nil }
        }
        #expect(item.appearance.items.first == .fill(FillPaint(paint: .solid(.black))))
        #expect(paints.map(\.style.width).allSatisfy { abs($0 - 1) < 1e-12 })
        #expect(paints[0].style.dash.map { ($0 * 1e9).rounded() / 1e9 } == [2, 1])
        #expect(abs(paints[0].style.dashPhase - 1) < 1e-12)
        if case .calligraphic(let scaledNib) = paints[1].kind {
            #expect(abs(scaledNib.width - 2) < 1e-12 && abs(scaledNib.height - 1) < 1e-12 && scaledNib.angle == 30)
        } else {
            Issue.record("calligraphic kind lost")
        }
        if case .custom(let scaledCustom) = paints[2].kind {
            #expect(abs(scaledCustom.length - 4) < 1e-12 && abs(scaledCustom.spacing - 1) < 1e-12)
        } else {
            Issue.record("custom kind lost")
        }
    }

    @Test func asUnitAndNonScalingOrSingularMatricesLeaveChildrenAlone() {
        let stroke = DisplayItem.stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), style: StrokeStyle(width: 2), paint: .solid(.black)))
        #expect(GroupStrokes.children([stroke], groupTransform: .scale(3), mode: .asUnit) == [stroke])
        #expect(GroupStrokes.children([stroke], groupTransform: .rotation(radians: 1).concatenating(.translation(x: 5, y: 5)), mode: .nominal) == [stroke])
        #expect(GroupStrokes.children([stroke], groupTransform: .scale(x: 0, y: 2), mode: .nominal) == [stroke])
        #expect(GroupStrokeMode(transformAsUnit: true) == .asUnit && GroupStrokeMode(transformAsUnit: false) == .nominal)
        // Images and text are untouched.
        let text = DisplayItem.text(TextRunItem(text: "A", origin: .zero, bounds: Rect(x: 0, y: 0, width: 4, height: 4), color: .black))
        #expect(text.scalingStrokeWidths(by: 0.5) == text)
    }

    @Test func hairlinesKeepDevicePixelDashes() {
        let hairline = StrokeStyle(width: 0, dash: [2, 2], dashInDevicePixels: true)
        #expect(hairline.scaled(by: 0.5) == hairline)
        let dashed = StrokeStyle(width: 2, dash: [2, 2], dashInDevicePixels: true)
        #expect(dashed.scaled(by: 0.5).dash == [1, 1])
    }
}
