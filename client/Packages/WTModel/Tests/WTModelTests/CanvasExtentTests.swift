import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTRender

/// The canvas's scrollable extent (D-093, workspace.adoc "The pasteboard").
@Suite struct CanvasExtentTests {
    static let letter = Rect(x: 7686, y: 7596, width: 612, height: 792)

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    @Test func aSmallPageGetsAnA4MarginOnEverySide() {
        let a4 = CanvasExtent.a4
        #expect(Self.close(a4.width, 595.275590551) && Self.close(a4.height, 841.88976378))
        let extent = CanvasExtent.extent(pages: Self.letter)
        #expect(Self.close(extent.minX, Self.letter.minX - a4.width) && Self.close(extent.maxX, Self.letter.maxX + a4.width))
        #expect(Self.close(extent.minY, Self.letter.minY - a4.height) && Self.close(extent.maxY, Self.letter.maxY + a4.height))
        // A portrait A4 sheet fits beside, above and below the page.
        let beside = Rect(x: Self.letter.maxX, y: Self.letter.minY, width: a4.width, height: a4.height)
        let above = Rect(x: Self.letter.minX, y: Self.letter.minY - a4.height, width: a4.width, height: a4.height)
        #expect(extent.insetBy(dx: -1e-6, dy: -1e-6).contains(beside) && extent.insetBy(dx: -1e-6, dy: -1e-6).contains(above))
    }

    @Test func aLargePageGetsHalfItsWidthAndHeight() {
        let poster = Rect(x: 1000, y: 2000, width: 4000, height: 3000)
        let margins = CanvasExtent.margins(of: poster)
        #expect(margins.horizontal == 2000 && margins.vertical == 1500)
        #expect(CanvasExtent.extent(pages: poster) == Rect(x: -1000, y: 500, width: 8000, height: 6000))
        // A wide, short page: half its width across, A4's height down.
        let banner = Rect(x: 0, y: 0, width: 3000, height: 200)
        #expect(CanvasExtent.margins(of: banner) == (1500, CanvasExtent.a4.height))
    }

    @Test func pagesSideBySideUseTheirUnion() {
        let union = Self.letter.union(Self.letter.offset(by: Vector(dx: 648, dy: 0)))
        let extent = CanvasExtent.extent(pages: union)
        #expect(Self.close(extent.width, union.width + 2 * max(union.width / 2, CanvasExtent.a4.width)))
        #expect(Self.close(extent.minX, union.minX - union.width / 2))
    }

    @Test func artworkBeyondTheMarginsWidensTheExtent() {
        let inside = Rect(x: 7700, y: 7600, width: 10, height: 10)
        #expect(CanvasExtent.extent(pages: Self.letter, artwork: inside) == CanvasExtent.extent(pages: Self.letter))
        let far = Rect(x: 14_000, y: -300, width: 50, height: 50)
        let extent = CanvasExtent.extent(pages: Self.letter, artwork: far)
        let room = far.insetBy(dx: -CanvasExtent.a4.width, dy: -CanvasExtent.a4.height)
        #expect(extent.contains(room) && extent.contains(CanvasExtent.extent(pages: Self.letter)))
        #expect(extent.maxX == room.maxX && extent.minY == room.minY)
    }

    @Test func unusableRectanglesAreIgnored() {
        let plain = CanvasExtent.extent(pages: Self.letter)
        #expect(CanvasExtent.extent(pages: Self.letter, artwork: .null) == plain)
        #expect(CanvasExtent.extent(pages: Self.letter, artwork: Rect(minX: 0, minY: 0, maxX: .infinity, maxY: 1)) == plain)
        // No pages: artwork alone, or an A4 sheet at the origin.
        let art = Rect(x: 50, y: 60, width: 100, height: 100)
        let around = CanvasExtent.extent(pages: nil, artwork: art)
        #expect(around.contains(art) && Self.close(around.minX, 50 - CanvasExtent.a4.width))
        let nothing = CanvasExtent.extent(pages: .null)
        #expect(Self.close(nothing.width, 3 * CanvasExtent.a4.width) && Self.close(nothing.height, 3 * CanvasExtent.a4.height))
    }

    @Test func artworkBoundsSkipTheFurniture() {
        let furniture = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 15_984, height: 15_984)), paint: .solid(.white)))
        func box(_ rect: Rect) -> DisplayItem { .fill(FillItem(path: DisplayPath(rect: rect), paint: .solid(.white))) }
        let a = Rect(x: 100, y: 100, width: 10, height: 10)
        let b = Rect(x: -500, y: 20_000, width: 5, height: 5)
        let empty = DisplayItem.group(GroupItem(children: []))
        let list = DisplayList(canvas: "c", items: [furniture, box(a), empty, box(b)], nodeIDs: [nil, NodeID(OpID(counter: 1, replica: 1)), NodeID(OpID(counter: 2, replica: 1)), NodeID(OpID(counter: 3, replica: 1))])
        #expect(CanvasExtent.artworkBounds(of: list) == a.union(b))
        #expect(CanvasExtent.artworkBounds(of: DisplayList(canvas: "c", items: [furniture])) == nil)
        #expect(CanvasExtent.artworkBounds(of: DisplayList(canvas: "c", items: [furniture], nodeIDs: [nil])) == nil)
    }

    @Test func zoomOutStopsWhenTheWholeExtentShows() {
        let extent = Rect(x: 0, y: 0, width: 2000, height: 1000)
        let range = 0.06...256.0
        #expect(Self.close(CanvasExtent.minimumZoom(for: extent, in: Size(width: 1000, height: 1000), range: range), 0.5))
        #expect(Self.close(CanvasExtent.minimumZoom(for: extent, in: Size(width: 4000, height: 300), range: range), 0.3))
        // Turned 90°, the extent is 1000 across and 2000 down.
        #expect(Self.close(CanvasExtent.minimumZoom(for: extent, rotationDegrees: 90, in: Size(width: 1000, height: 1000), range: range), 0.5))
        #expect(Self.close(CanvasExtent.minimumZoom(for: extent, rotationDegrees: 90, in: Size(width: 1000, height: 4000), range: range), 1))
        // Held within the range: a huge extent stops at the bottom, a tiny one at the top.
        #expect(CanvasExtent.minimumZoom(for: Rect(x: 0, y: 0, width: 1e7, height: 1e7), in: Size(width: 800, height: 600), range: range) == 0.06)
        #expect(CanvasExtent.minimumZoom(for: Rect(x: 0, y: 0, width: 1, height: 1), in: Size(width: 800, height: 600), range: 0.06...1) == 1)
        #expect(CanvasExtent.minimumZoom(for: .null, in: Size(width: 800, height: 600), range: range) == 0.06)
        #expect(CanvasExtent.minimumZoom(for: extent, in: Size(width: 0, height: 600), range: range) == 0.06)
    }
}
