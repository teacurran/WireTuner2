import WTGeometry
import Testing
@testable import WTRender
// GEO-003 added stroke types of the same names to WTGeometry; the display list's are WTRender's.
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

@Suite struct DisplayPathTests {
    @Test func rectangleAndEllipseHulls() {
        let rect = Rect(x: 10, y: 20, width: 30, height: 40)
        #expect(DisplayPath(rect: rect).controlBounds == rect)
        #expect(DisplayPath(rect: rect).elements.count == 5)
        let ellipse = DisplayPath(ellipseIn: rect)
        #expect(ellipse.elements.count == 6)
        #expect(approx(ellipse.controlBounds!, rect, tolerance: 1e-12))
        #expect(!ellipse.isEmpty)
        #expect(DisplayPath().isEmpty)
        #expect(DisplayPath().controlBounds == nil)
        #expect(DisplayPath(elements: [.close]).controlBounds == nil)
    }

    @Test func polygonsAndMutation() {
        let points = [Point(x: 0, y: 0), Point(x: 4, y: 0), Point(x: 2, y: 3)]
        let closed = DisplayPath(polygon: points)
        #expect(closed.elements.count == 4)
        #expect(closed.elements.last == .close)
        let open = DisplayPath(polygon: points, closed: false)
        #expect(open.elements.count == 3)
        #expect(DisplayPath(polygon: []).isEmpty)

        var path = DisplayPath()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: 10, y: 0))
        path.addQuadCurve(control: Point(x: 15, y: 5), to: Point(x: 10, y: 10))
        path.addCubicCurve(control1: Point(x: 5, y: 15), control2: Point(x: -5, y: 15), to: Point(x: 0, y: 10))
        path.close()
        #expect(path.elements.count == 5)
        #expect(path.controlBounds == Rect(x: -5, y: 0, width: 20, height: 15), "control points count toward the hull")
    }

    @Test func applyingTransformsEveryPoint() {
        var path = DisplayPath()
        path.move(to: Point(x: 1, y: 1))
        path.addLine(to: Point(x: 2, y: 1))
        path.addQuadCurve(control: Point(x: 3, y: 1), to: Point(x: 3, y: 2))
        path.addCubicCurve(control1: Point(x: 3, y: 3), control2: Point(x: 2, y: 3), to: Point(x: 1, y: 3))
        path.close()
        let moved = path.applying(.translation(x: 10, y: 20))
        #expect(moved.elements == [
            .move(to: Point(x: 11, y: 21)),
            .line(to: Point(x: 12, y: 21)),
            .quadCurve(control: Point(x: 13, y: 21), end: Point(x: 13, y: 22)),
            .cubicCurve(control1: Point(x: 13, y: 23), control2: Point(x: 12, y: 23), end: Point(x: 11, y: 23)),
            .close,
        ])
    }
}

@Suite struct DisplayListTests {
    private let rect = Rect(x: 0, y: 0, width: 10, height: 10)

    @Test func canvasIDAndColor() {
        let canvas: CanvasID = "pasteboard"
        #expect(canvas.rawValue == "pasteboard")
        #expect(canvas.description == "pasteboard")
        #expect(CanvasID("a") == "a")
        #expect(Color(white: 0.5) == Color(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        #expect(Color.black.withAlpha(multipliedBy: 0.5).alpha == 0.5)
        #expect(Color.clear.alpha == 0 && Color.white.red == 1)
        #expect(StrokeStyle().width == 1)
    }

    @Test func itemBoundsPerKind() {
        let fill = DisplayItem.fill(FillItem(path: DisplayPath(rect: rect), paint: .solid(.black), transform: .translation(x: 5, y: 5)))
        #expect(fill.bounds == Rect(x: 5, y: 5, width: 10, height: 10))
        #expect(fill.transform == .translation(x: 5, y: 5))

        let stroke = DisplayItem.stroke(StrokeItem(path: DisplayPath(rect: rect), style: StrokeStyle(width: 2, miterLimit: 1), paint: .solid(.black)))
        let outset = 2 * 2.0.squareRoot() / 2
        #expect(approx(stroke.bounds!, rect.expanded(by: outset)))
        let mitered = DisplayItem.stroke(StrokeItem(path: DisplayPath(rect: rect), style: StrokeStyle(width: 2, miterLimit: 10), paint: .solid(.black)))
        #expect(mitered.bounds == rect.expanded(by: 10))
        #expect(stroke.transform == .identity)

        let image = DisplayItem.image(ImageItem(assetID: "x", rect: rect, transform: .scale(2)))
        #expect(image.bounds == Rect(x: 0, y: 0, width: 20, height: 20))
        #expect(image.transform == .scale(2))

        let text = DisplayItem.text(TextRunItem(text: "t", origin: Point(x: 0, y: 8), bounds: rect))
        #expect(text.bounds == rect)
        #expect(text.transform == .identity)

        let emptyFill = DisplayItem.fill(FillItem(path: DisplayPath(), paint: .solid(.black)))
        #expect(emptyFill.bounds == nil)
        let emptyStroke = DisplayItem.stroke(StrokeItem(path: DisplayPath(), paint: .solid(.black)))
        #expect(emptyStroke.bounds == nil)
    }

    @Test func groupBounds() {
        let child = DisplayItem.fill(FillItem(path: DisplayPath(rect: rect), paint: .solid(.black)))
        let far = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 100, y: 100, width: 10, height: 10)), paint: .solid(.black)))

        let plain = DisplayItem.group(GroupItem(children: [child, far]))
        #expect(plain.bounds == Rect(x: 0, y: 0, width: 110, height: 110))
        #expect(plain.transform == .identity)

        let clipped = DisplayItem.group(GroupItem(children: [child, far], clip: DisplayPath(rect: Rect(x: 5, y: 5, width: 50, height: 50)), transform: .translation(x: 1, y: 1)))
        #expect(clipped.bounds == Rect(x: 6, y: 6, width: 50, height: 50), "content union clipped to the transformed clip")

        let disjoint = DisplayItem.group(GroupItem(children: [child], clip: DisplayPath(rect: Rect(x: 50, y: 50, width: 5, height: 5))))
        #expect(disjoint.bounds == nil)

        let emptyClip = DisplayItem.group(GroupItem(children: [child], clip: DisplayPath()))
        #expect(emptyClip.bounds == nil)

        let childless = DisplayItem.group(GroupItem(children: []))
        #expect(childless.bounds == nil)

        #expect(GroupItem(children: [], opacity: 1.7).opacity == 1)
        #expect(GroupItem(children: [], opacity: -1).opacity == 0)
    }

    @Test func listBoundsAndCulling() {
        let near = DisplayItem.fill(FillItem(path: DisplayPath(rect: rect), paint: .solid(.black)))
        let far = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 100, y: 0, width: 10, height: 10)), paint: .solid(.black)))
        let nothing = DisplayItem.fill(FillItem(path: DisplayPath(), paint: .solid(.black)))
        let list = DisplayList(canvas: "c", items: [near, nothing, far])
        #expect(list.count == 3)
        #expect(!list.isEmpty)
        #expect(list.bounds == Rect(x: 0, y: 0, width: 110, height: 10))
        #expect(list.itemBounds == [rect, nil, Rect(x: 100, y: 0, width: 10, height: 10)])
        #expect(list.indices(intersecting: Rect(x: -5, y: -5, width: 20, height: 20)) == [0])
        #expect(list.indices(intersecting: Rect(x: 0, y: 0, width: 200, height: 20)) == [0, 2])
        #expect(list.indices(intersecting: Rect(x: 50, y: 0, width: 10, height: 10)).isEmpty)

        let empty = DisplayList(canvas: "c", items: [])
        #expect(empty.isEmpty)
        #expect(empty.bounds == nil)
    }

    @Test func builderOrdersByZThenInsertion() {
        var builder = DisplayListBuilder(canvas: "c")
        let a = DisplayItem.text(TextRunItem(text: "a", origin: .zero, bounds: rect))
        let b = DisplayItem.text(TextRunItem(text: "b", origin: .zero, bounds: rect))
        let c = DisplayItem.text(TextRunItem(text: "c", origin: .zero, bounds: rect))
        let d = DisplayItem.text(TextRunItem(text: "d", origin: .zero, bounds: rect))
        builder.add(a, z: 5)
        builder.add(b)
        builder.add(c, z: 5)
        builder.add(d, z: -1)
        #expect(builder.count == 4)
        #expect(builder.canvas == "c")
        let list = builder.build()
        #expect(list.items == [d, b, a, c])
        #expect(list.canvas == "c")
    }
}
