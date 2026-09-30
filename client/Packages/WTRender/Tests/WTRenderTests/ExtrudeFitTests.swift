import Testing
import WTGeometry
@testable import WTRender

/// `ExtrudeFit` (extrude.adoc, "Extruding"): a vanishing point inside a convex outline hides every
/// side behind the front face, and a new extrusion's vanishing point is moved off the object so the
/// solid reads as one.
@Suite struct ExtrudeFitTests {
    typealias C = ReferenceCorpus

    /// A 200 × 120 ellipse about (300, 200).
    static let rect = Rect(x: 200, y: 140, width: 200, height: 120)
    static let ellipse = C.path(DisplayPath(ellipseIn: rect), [C.fill(C.orange), C.stroke(.black, width: 1)])
    static let center = Point(x: 300, y: 200)

    static func spec(_ vanishing: Point, surface: ExtrudeSpec.SurfaceKind = .shaded, length: Double = 36) -> ExtrudeSpec {
        ExtrudeSpec(length: length, vanishingPoint: vanishing, surface: surface, ambient: 30, light1: .init(direction: .topLeft, intensity: 80))
    }

    @Test func aVanishingPointInsideTheOutlineHidesEverySide() {
        #expect(ExtrudeFit.sides(Self.spec(Self.center), child: Self.ellipse) == .hidden)
        #expect(ExtrudeFit.sides(Self.spec(Point(x: 340, y: 190)), child: Self.ellipse) == .hidden)
        #expect(ExtrudeFit.sides(Self.spec(Point(x: 600, y: 0)), child: Self.ellipse) == .visible)
        // Wireframe and Mesh draw every edge, culled or not; inside they still lie under the front.
        #expect(ExtrudeFit.sides(Self.spec(Self.center, surface: .wireframe), child: Self.ellipse) == .hidden)
        #expect(ExtrudeFit.sides(Self.spec(Point(x: 600, y: 0), surface: .mesh), child: Self.ellipse) == .visible)
        // No depth, or nothing closed: no sides at all.
        #expect(ExtrudeFit.sides(Self.spec(Point(x: 600, y: 0), length: 0), child: Self.ellipse) == .none)
        let line = C.path(DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 50, y: 20), Point(x: 90, y: 0)], closed: false), [C.stroke(.black, width: 1)])
        #expect(ExtrudeFit.sides(Self.spec(Point(x: 600, y: 0)), child: line) == .none)
        #expect(ExtrudeFit.vanishingPoint(Point(x: 40, y: 5), spec: Self.spec(.zero), children: [line]) == Point(x: 40, y: 5))
        #expect(ExtrudeFit.sides(Self.spec(Point(x: 600, y: 0)), child: .group(GroupItem(children: []))) == .none)
    }

    @Test func aHiddenVanishingPointMovesOffTheObject() throws {
        // On the centre: above right, beyond the bounds by half the larger side.
        let moved = ExtrudeFit.vanishingPoint(Self.center, spec: Self.spec(.zero), children: [Self.ellipse])
        #expect(moved.x > Self.rect.maxX && moved.y < Self.rect.minY)
        #expect(abs((moved.x - Self.center.x) + (moved.y - Self.center.y)) < 1e-9, "on the diagonal")
        let exit = 60 * 2.0.squareRoot()
        #expect(abs(moved.distance(to: Self.center) - (exit + 100)) < 1e-9)
        #expect(ExtrudeFit.sides(Self.spec(moved), child: Self.ellipse) == .visible)
        // Off the centre: along the ray from the centre through the requested point.
        let right = ExtrudeFit.vanishingPoint(Point(x: 340, y: 200), spec: Self.spec(.zero), children: [Self.ellipse])
        #expect(abs(right.y - 200) < 1e-9 && abs(right.x - (300 + 100 + 100)) < 1e-9)
        // Already showing: kept.
        #expect(ExtrudeFit.vanishingPoint(Point(x: 600, y: 0), spec: Self.spec(.zero), children: [Self.ellipse]) == Point(x: 600, y: 0))
        // Straight up: the exit is the half height; small objects keep at least 36 pt clear.
        let small = C.path(DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 20, height: 20)), [C.fill(C.orange)])
        let up = ExtrudeFit.vanishingPoint(Point(x: 10, y: 5), spec: Self.spec(.zero), children: [small])
        #expect(abs(up.x - 10) < 1e-9 && abs(up.y - (10 - 10 - 36)) < 1e-9)
        #expect(try #require(ExtrudeFit.bounds(Self.ellipse)) == Self.rect)
        #expect(ExtrudeFit.bounds(.group(GroupItem(children: []))) == nil)
        #expect(ExtrudeFit.vanishingPoint(Self.center, spec: Self.spec(.zero), children: []) == Self.center)
    }

    @Test func aNotchShowsItsInnerSides() {
        // A U: the vanishing point in the notch sits off the shape and looks at the notch's walls.
        let u = C.path(DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 30, y: 0), Point(x: 30, y: 60), Point(x: 70, y: 60), Point(x: 70, y: 0),
                                             Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)]), [C.fill(C.orange)])
        #expect(ExtrudeFit.sides(Self.spec(Point(x: 50, y: 30)), child: u) == .visible)
        #expect(ExtrudeFit.vanishingPoint(Point(x: 50, y: 30), spec: Self.spec(.zero), children: [u]) == Point(x: 50, y: 30))
        // The point on the outline counts as covered; a degenerate edge measures to its end.
        #expect(ExtrudeFit.covered(Point(x: 10, y: 0.2), by: [[Point(x: 0, y: 0), Point(x: 20, y: 0), Point(x: 20, y: -20)]]))
        #expect(ExtrudeFit.distance(Point(x: 3, y: 4), .zero, .zero) == 5)
        // An extrusion nested in the child reads as its child.
        let nested = DisplayItem.group(GroupItem(children: [Self.ellipse], live: .extrude(Self.spec(Point(x: 0, y: 0)))))
        #expect(ExtrudeFit.sides(Self.spec(Self.center), child: nested) == .hidden)
    }
}
