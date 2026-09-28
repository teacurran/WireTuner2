import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The Pointer tool's corner-radius handles (D-078, rectangles-ellipses-lines.adoc "Rectangles with
/// rounded corners").
@Suite struct RectangleHandlesTests {
    static func rect(_ a: inout Replica, radii: CornerRadii = CornerRadii(), transform: AffineTransform = .translation(x: 100, y: 50)) throws -> OpID {
        try LayerFixture.object(CreateShape(.rectangle(radii), size: Size(width: 80, height: 40), transform: transform), on: &a)
    }

    @Test func handlesSitOnTheDiagonalAtTheRoundingsCentreOrInsetFromASquareCorner() throws {
        var a = Replica(0xA)
        let square = try Self.rect(&a)
        let handles = try #require(RectangleHandles.positions(of: square, inset: 6, in: a.state))
        #expect(handles.map(\.corner) == Corner.allCases)
        #expect(handles.map(\.position) == [Point(x: 106, y: 56), Point(x: 174, y: 56), Point(x: 174, y: 84), Point(x: 106, y: 84)])
        let rounded = try Self.rect(&a, radii: .uniform(10))
        #expect(RectangleHandles.positions(of: rounded, inset: 6, in: a.state)?.first?.position == Point(x: 110, y: 60))
        // A tiny rectangle keeps its handles inside.
        let tiny = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 4, height: 4)), on: &a)
        #expect(RectangleHandles.positions(of: tiny, inset: 6, in: a.state)?.first?.position == Point(x: 2, y: 2))
        // Its four handles meet in the middle: the nearest one is taken.
        #expect(RectangleHandles.hit(Point(x: 1.9, y: 1.9), on: tiny, inset: 6, tolerance: 5, in: a.state) != nil)
        // Scaled up 2×, the inset stays the same on the page.
        let scaled = try Self.rect(&a, transform: .scale(2))
        #expect(RectangleHandles.positions(of: scaled, inset: 6, in: a.state)?.first?.position == Point(x: 6, y: 6))
    }

    @Test func draggingAHandleSetsEveryCornerWithUniformOnAndOneWithItOff() throws {
        var a = Replica(0xA)
        let node = try Self.rect(&a)
        #expect(a.state.props(node).rect.corners.uniform)
        #expect(RectangleHandles.hit(Point(x: 107, y: 55), on: node, inset: 6, tolerance: 4, in: a.state) == .topLeft)
        #expect(RectangleHandles.hit(Point(x: 140, y: 70), on: node, inset: 6, tolerance: 4, in: a.state) == nil)
        let uniform = try #require(RectangleHandles.drag(.topLeft, of: node, to: Point(x: 112, y: 64), in: a.state))
        #expect(uniform.corners == Corner.allCases)
        try a.perform(uniform)
        #expect(CornerRadii(a.state.props(node).rect.corners, size: Size(width: 80, height: 40)) == .uniform(13))
        try a.perform(SetCornerRadius([node], radius: nil, uniform: false))
        let one = try #require(RectangleHandles.drag(.bottomRight, of: node, to: Point(x: 170, y: 86), in: a.state))
        #expect(one.corners == [.bottomRight])
        try a.perform(one)
        #expect(CornerRadii(a.state.props(node).rect.corners, size: Size(width: 80, height: 40)).bottomRight == 7)
        // Clamped to half the shorter side, and not below zero.
        #expect(RectangleHandles.radius(dragging: .topRight, of: node, to: Point(x: 100, y: 100), in: a.state) == 20)
        #expect(RectangleHandles.radius(dragging: .bottomLeft, of: node, to: Point(x: 0, y: 200), in: a.state) == 0)
    }

    @Test func noHandlesWithACornersEffectOrOnAnythingElse() throws {
        var a = Replica(0xA)
        let node = try Self.rect(&a)
        try a.perform(AddEffect([node], kind: .corners))
        #expect(RectangleHandles.positions(of: node, inset: 6, in: a.state) == nil)
        #expect(RectangleHandles.hit(Point(x: 106, y: 56), on: node, inset: 6, tolerance: 4, in: a.state) == nil)
        #expect(RectangleHandles.drag(.topLeft, of: node, to: .zero, in: a.state) == nil)
        #expect(RectangleHandles.radius(dragging: .topLeft, of: node, to: .zero, in: a.state) == nil)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 4, height: 4)), on: &a)
        #expect(RectangleHandles.positions(of: ellipse, inset: 6, in: a.state) == nil)
    }
}
