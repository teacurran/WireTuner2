// Extrusions (FX-018, FX-019, FX-022; extrude.adoc, "Client").
//
// Geometry.  The child's outline (effects applied, text as glyph outlines) is flattened with
// `surfaceSteps` pieces per curved segment (straight segments stay one edge) into rings: the
// front face at `z`, the rear at `z + length`, and with a profile `ProfileSweep`'s intermediate
// rings, each offset from the outline along the vertex bisector (Bevel) or a fixed direction
// (Static) and turned by `twist × depth / length` about the axis.  Space is pasteboard x right,
// y down, z away from the viewer; the rings are rotated about the 3D centre by the Euler angles
// (x, then y, then z) and projected toward the vanishing point: a point at depth z lands at
// VP + (p − VP) · f / (f + z) with f the distance from the outline's centre to the vanishing point,
// so the rear face shrinks toward it and a far vanishing point gives an oblique orthographic box.
//
// Faces.  Side quads join consecutive rings; with the caps they are culled when they face away
// from the eye (at the vanishing point, f in front of the page) and drawn back to front by mean
// depth (Flat, Shaded, Hidden Mesh), or all drawn as edges (Wireframe, Mesh).  Shading is Lambert
// with two directional lights and ambient (`ExtrudeShading`); the front face draws with the
// child's own appearance, mapped through the same projection.

import Foundation
import WTGeometry

/// A point in the extrusion's 3D space.
struct Point3: Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    static func - (a: Point3, b: Point3) -> Point3 { Point3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func + (a: Point3, b: Point3) -> Point3 { Point3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }

    func cross(_ other: Point3) -> Point3 {
        Point3(x: y * other.z - z * other.y, y: z * other.x - x * other.z, z: x * other.y - y * other.x)
    }

    func dot(_ other: Point3) -> Double { x * other.x + y * other.y + z * other.z }

    var length: Double { dot(self).squareRoot() }

    var normalized: Point3 {
        let l = length
        return l > 0 ? Point3(x: x / l, y: y / l, z: z / l) : self
    }
}

/// One face of a solved extrusion.
struct ExtrudeFace: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case front
        case rear
        case side
    }

    var kind: Kind
    /// Projected vertices, pasteboard space.
    var polygon: [Point]
    /// Unit outward normal after rotation.
    var normal: Point3
    /// Mean depth after rotation, for the painter's sort.
    var depth: Double
    /// Whether the face looks toward the eye.
    var facesViewer: Bool
}

struct ExtrudeSolver {
    let spec: ExtrudeSpec
    /// The outline's centre, pasteboard.
    let center: Point
    /// Distance from the centre to the vanishing point; nil at infinity.
    let focal: Double?
    private let rotation: (Point3) -> Point3

    init(spec: ExtrudeSpec, bounds: Rect) {
        self.spec = spec
        center = bounds.isNull ? .zero : bounds.center
        let vp = spec.vanishingPoint
        focal = vp.isFinite ? max(vp.distance(to: center), 1) : nil
        let pivot = Point3(x: center.x, y: center.y, z: spec.z + spec.effectiveLength / 2)
        let rx = (spec.rotationX.isFinite ? spec.rotationX : 0) * .pi / 180
        let ry = (spec.rotationY.isFinite ? spec.rotationY : 0) * .pi / 180
        let rz = (spec.rotationZ.isFinite ? spec.rotationZ : 0) * .pi / 180
        rotation = { point in
            var p = point - pivot
            p = Point3(x: p.x, y: p.y * cos(rx) - p.z * sin(rx), z: p.y * sin(rx) + p.z * cos(rx))
            p = Point3(x: p.x * cos(ry) + p.z * sin(ry), y: p.y, z: -p.x * sin(ry) + p.z * cos(ry))
            p = Point3(x: p.x * cos(rz) - p.y * sin(rz), y: p.x * sin(rz) + p.y * cos(rz), z: p.z)
            return p + pivot
        }
    }

    func rotated(_ point: Point3) -> Point3 { rotation(point) }

    /// A rotated point on the page.
    func project(_ point: Point3) -> Point {
        guard let focal else {
            return Point(x: point.x, y: point.y)
        }
        let vp = spec.vanishingPoint
        let ratio = focal / max(focal + point.z, 1e-3)
        return Point(x: vp.x + (point.x - vp.x) * ratio, y: vp.y + (point.y - vp.y) * ratio)
    }

    /// The eye, for culling: at the vanishing point, `focal` in front of the page.
    var eye: Point3? {
        focal.map { Point3(x: spec.vanishingPoint.x, y: spec.vanishingPoint.y, z: -$0) }
    }

    func facesViewer(normal: Point3, at point: Point3) -> Bool {
        guard let eye else {
            return normal.z < 0
        }
        return normal.dot(point - eye) < 0
    }

    /// A flat point at depth `depth` mapped onto the page (front-face mapping).
    func map(_ point: Point, depth: Double) -> Point {
        project(rotated(Point3(x: point.x, y: point.y, z: spec.z + depth)))
    }

    /// Every face, unsorted.  `polygons` are the flattened outline contours (pasteboard).
    func faces(_ polygons: [[Point]]) -> [ExtrudeFace] {
        let rings = ProfileSweep.rings(spec)
        let length = spec.effectiveLength
        var faces: [ExtrudeFace] = []
        for polygon in polygons where polygon.count >= 3 {
            let orientation = ExtrudeSolver.signedArea(polygon) >= 0 ? 1.0 : -1.0
            let offsets = ProfileSweep.directions(polygon, kind: spec.profile.kind, angle: spec.profile.angle, orientation: orientation)
            let ring3D: [[Point3]] = rings.map { ring in
                polygon.indices.map { index in
                    let base = polygon[index] + offsets[index] * ring.offset
                    let turned = ProfileSweep.twist(base, about: center, degrees: length > 0 ? spec.profile.twist * ring.depth / length : 0)
                    return rotated(Point3(x: turned.x, y: turned.y, z: spec.z + ring.depth))
                }
            }
            // Caps: the front faces the viewer (−z) before rotation, the rear away (+z).
            faces.append(cap(ring3D[0], kind: .front, orientation: orientation))
            if length > 0 {
                faces.append(cap(ring3D[ring3D.count - 1], kind: .rear, orientation: orientation))
                for ringIndex in 0..<(ring3D.count - 1) {
                    let near = ring3D[ringIndex]
                    let far = ring3D[ringIndex + 1]
                    for index in polygon.indices {
                        let next = (index + 1) % polygon.count
                        let quad = [near[index], near[next], far[next], far[index]]
                        faces.append(side(quad, orientation: orientation))
                    }
                }
            }
        }
        return faces
    }

    private func cap(_ ring: [Point3], kind: ExtrudeFace.Kind, orientation: Double) -> ExtrudeFace {
        let base = Point3(x: 0, y: 0, z: kind == .front ? -1 : 1)
        let origin = rotated(Point3(x: 0, y: 0, z: 0))
        let tip = rotated(base)
        let normal = (tip - origin).normalized
        let mean = ExtrudeSolver.mean(ring)
        return ExtrudeFace(kind: kind, polygon: ring.map(project), normal: normal, depth: mean.z, facesViewer: facesViewer(normal: normal, at: mean))
    }

    private func side(_ quad: [Point3], orientation: Double) -> ExtrudeFace {
        let edge = quad[1] - quad[0]
        let back = quad[3] - quad[0]
        var normal = edge.cross(back).normalized
        // For a positively oriented outline (y down), edge × depth points outward.
        if orientation < 0 {
            normal = Point3(x: -normal.x, y: -normal.y, z: -normal.z)
        }
        let mean = ExtrudeSolver.mean(quad)
        return ExtrudeFace(kind: .side, polygon: quad.map(project), normal: normal, depth: mean.z, facesViewer: facesViewer(normal: normal, at: mean))
    }

    static func mean(_ points: [Point3]) -> Point3 {
        let sum = points.reduce(Point3(x: 0, y: 0, z: 0), +)
        let count = Double(max(points.count, 1))
        return Point3(x: sum.x / count, y: sum.y / count, z: sum.z / count)
    }

    static func signedArea(_ polygon: [Point]) -> Double {
        var area = 0.0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    /// Culled faces back to front (Flat, Shaded, Hidden Mesh).
    static func visibleSorted(_ faces: [ExtrudeFace]) -> [ExtrudeFace] {
        faces.filter(\.facesViewer).enumerated().sorted { lhs, rhs in
            lhs.element.depth != rhs.element.depth ? lhs.element.depth > rhs.element.depth : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The outline flattened: straight segments as one edge, curves in `steps` equal arcs.
    static func polygons(_ contours: [Contour], steps: Int) -> [[Point]] {
        contours.compactMap { contour in
            var points: [Point] = []
            for segment in contour.explicitSegments {
                points.append(segment.p0)
                guard !segment.isLinear(tolerance: 1e-6) else { continue }
                let length = segment.length()
                for index in 1..<max(steps, 1) {
                    points.append(segment.evaluate(segment.parameter(atLength: length * Double(index) / Double(steps))))
                }
            }
            if !contour.isClosed, let end = contour.endPoint {
                points.append(end)
            }
            // Drop a repeated closing point.
            if points.count > 1, points[0].distance(to: points[points.count - 1]) < 1e-9 {
                points.removeLast()
            }
            return points.count >= 3 ? points : nil
        }
    }
}

enum ProfileSweep {
    /// One ring of the sweep: its depth behind the front face and its offset from the outline.
    struct Ring: Hashable, Sendable {
        var depth: Double
        var offset: Double
    }

    /// The rings, front first.  Without a profile (or with an empty one) `steps` equal slices
    /// at no offset; with one, the profile's anchors, each profile segment cut into slices in
    /// proportion to its length (at least one): x runs front to back over the length, y upward
    /// is outward from the outline.
    static func rings(_ spec: ExtrudeSpec) -> [Ring] {
        let length = spec.effectiveLength
        let steps = spec.effectiveProfileSteps
        let profilePoints = profile(spec)
        guard spec.profile.kind != .none, profilePoints.count >= 2, length > 0 else {
            return (0...steps).map { Ring(depth: length * Double($0) / Double(steps), offset: 0) }
        }
        let first = profilePoints[0]
        let last = profilePoints[profilePoints.count - 1]
        let span = last.x - first.x
        var lengths: [Double] = [0]
        for index in 1..<profilePoints.count {
            lengths.append(lengths[index - 1] + profilePoints[index].distance(to: profilePoints[index - 1]))
        }
        let total = max(lengths[lengths.count - 1], 1e-9)
        func ring(_ point: Point, arc: Double) -> Ring {
            let fraction = abs(span) > 1e-9 ? (point.x - first.x) / span : arc / total
            return Ring(depth: length * min(max(fraction, 0), 1), offset: first.y - point.y)
        }
        var result = [ring(first, arc: 0)]
        for index in 1..<profilePoints.count {
            let a = profilePoints[index - 1]
            let b = profilePoints[index]
            let slices = max(Int((Double(steps) * (lengths[index] - lengths[index - 1]) / total).rounded()), 1)
            for slice in 1...slices {
                let t = Double(slice) / Double(slices)
                result.append(ring(Point.lerp(a, b, t), arc: lengths[index - 1] + (lengths[index] - lengths[index - 1]) * t))
            }
        }
        return result
    }

    /// The profile path flattened (one contour).
    static func profile(_ spec: ExtrudeSpec) -> [Point] {
        guard let contour = spec.profile.path?.contours.first, let end = contour.endPoint else {
            return []
        }
        var points: [Point] = []
        for segment in contour.segments {
            points.append(segment.p0)
            if !segment.isLinear(tolerance: 1e-6) {
                points += (1..<8).map { segment.evaluate(Double($0) / 8) }
            }
        }
        return points + [end]
    }

    /// Unit offset directions per vertex: the outward bisector (Bevel) or a fixed direction at
    /// `angle` (Static, counterclockwise from the right, y up).
    static func directions(_ polygon: [Point], kind: ExtrudeSpec.ProfileKind, angle: Double, orientation: Double) -> [Vector] {
        switch kind {
        case .staticAngle:
            let radians = (angle.isFinite ? angle : 0) * .pi / 180
            return Array(repeating: Vector(cos(radians), -sin(radians)), count: polygon.count)
        case .none, .bevel:
            return polygon.indices.map { index in
                let previous = polygon[(index - 1 + polygon.count) % polygon.count]
                let next = polygon[(index + 1) % polygon.count]
                let incoming = (polygon[index] - previous).normalized
                let outgoing = (next - polygon[index]).normalized
                // In y-down space a positively oriented outline turns clockwise on screen; its
                // outward normal is the edge direction turned by −90°.
                let normalIn = Vector(incoming.dy, -incoming.dx) * orientation
                let normalOut = Vector(outgoing.dy, -outgoing.dx) * orientation
                let sum = normalIn + normalOut
                return sum.length > 1e-9 ? sum.normalized : normalOut
            }
        }
    }

    /// `point` turned clockwise on screen by `degrees` about `center`.
    static func twist(_ point: Point, about center: Point, degrees: Double) -> Point {
        guard degrees != 0, degrees.isFinite else {
            return point
        }
        return AffineTransform.rotation(radians: degrees * .pi / 180, around: center).apply(point)
    }
}

/// Lambert shading of the sides (FX-019).
enum ExtrudeShading {
    /// The unit vector toward a light, z toward the viewer being negative; nil for None.
    static func vector(_ direction: ExtrudeSpec.LightDirection) -> Point3? {
        let raw: (Double, Double)
        switch direction {
        case .none: return nil
        case .topLeft: raw = (-1, -1)
        case .top: raw = (0, -1)
        case .topRight: raw = (1, -1)
        case .left: raw = (-1, 0)
        case .front: raw = (0, 0)
        case .right: raw = (1, 0)
        case .bottomLeft: raw = (-1, 1)
        case .bottom: raw = (0, 1)
        case .bottomRight: raw = (1, 1)
        }
        return Point3(x: raw.0, y: raw.1, z: -1).normalized
    }

    /// The lit intensity of a face with `normal`: ambient plus each light's diffuse term.
    static func intensity(normal: Point3, spec: ExtrudeSpec) -> Double {
        var total = min(max(spec.ambient, 0), 100) / 100
        for light in [spec.light1, spec.light2] {
            guard let direction = vector(light.direction) else { continue }
            total += min(max(light.intensity, 0), 100) / 100 * max(0, normal.dot(direction))
        }
        return min(max(total, 0), 1)
    }

    /// The colour a paint shades with: a solid colour, a gradient's mean stop colour, grey
    /// otherwise.
    static func baseColor(of paint: Paint?) -> Color {
        switch paint {
        case .solid(let color):
            return color
        case .gradient(let gradient) where !gradient.stops.isEmpty:
            let count = Double(gradient.stops.count)
            let sum = gradient.stops.reduce(SIMD4<Double>(0, 0, 0, 0)) { $0 + SIMD4($1.color.red, $1.color.green, $1.color.blue, $1.color.alpha) }
            return Color(red: sum.x / count, green: sum.y / count, blue: sum.z / count, alpha: sum.w / count)
        default:
            return Color(white: 0.6)
        }
    }

    static func shaded(_ color: Color, intensity: Double) -> Color {
        Color(red: color.red * intensity, green: color.green * intensity, blue: color.blue * intensity, alpha: color.alpha)
    }
}

enum ExtrudeResolver {
    static func entries(_ spec: ExtrudeSpec, children: [DisplayItem]) -> [DerivedGroup.Entry] {
        guard let first = children.first else {
            return []
        }
        let flatChild = nestedChild(first)
        let paths = WarpSource.plainPaths(flatChild)
        let bounds = DisplayList.union(of: paths.compactMap { $0.path.controlBounds }) ?? .null
        let solver = ExtrudeSolver(spec: spec, bounds: bounds)
        let contours = paths.flatMap { $0.path.contours.filter(\.isClosed) }
        let polygons = ExtrudeSolver.polygons(contours, steps: spec.effectiveSurfaceSteps)
        let fill = paths.lazy.compactMap { $0.appearance.fills.first(where: { !$0.paint.isNone })?.paint }.first
        let strokeColor = paths.lazy.compactMap { $0.appearance.strokes.first?.paint.color }.first ?? .black
        let base = ExtrudeShading.baseColor(of: fill)
        let front = WarpSource.mapped(paths) { solver.map($0, depth: 0) }
        var entries: [DerivedGroup.Entry] = []
        let faces = solver.faces(polygons)
        let edgeStyle = StrokeStyle(width: 0.5, join: .round)
        switch spec.surface {
        case .wireframe, .mesh:
            let path = edges(faces, rings: spec.surface == .wireframe)
            let stroke = StrokePaint(paint: .solid(strokeColor), style: edgeStyle)
            entries.append(DerivedGroup.Entry(item: .path(PathItem(path: path, appearance: Appearance([.stroke(stroke)]))), origin: nil))
            if let front {
                entries.append(DerivedGroup.Entry(item: front, origin: 0))
            }
        case .flat, .shaded, .hiddenMesh:
            for face in ExtrudeSolver.visibleSorted(faces) {
                if face.kind == .front {
                    if let front {
                        entries.append(DerivedGroup.Entry(item: front, origin: 0))
                    }
                    continue
                }
                let color = spec.surface == .shaded ? ExtrudeShading.shaded(base, intensity: ExtrudeShading.intensity(normal: face.normal, spec: spec)) : base
                var items: [AppearanceItem] = [.fill(FillPaint(paint: .solid(color)))]
                if spec.surface == .hiddenMesh {
                    items.append(.stroke(StrokePaint(paint: .solid(strokeColor), style: edgeStyle)))
                } else {
                    // A hair of the same colour closes the seams anti-aliasing leaves between faces.
                    items.append(.stroke(StrokePaint(paint: .solid(color), style: StrokeStyle(width: 0.25, join: .round))))
                }
                entries.append(DerivedGroup.Entry(item: .path(PathItem(path: DisplayPath(polygon: face.polygon), appearance: Appearance(items))), origin: nil))
            }
            // Zero length, or nothing closed to extrude: the child draws as its front face.
            if !entries.contains(where: { $0.origin == 0 }), let front, spec.effectiveLength == 0 || polygons.isEmpty {
                entries.append(DerivedGroup.Entry(item: front, origin: 0))
            }
        }
        for (index, child) in children.enumerated().dropFirst() {
            entries.append(DerivedGroup.Entry(item: child, origin: index))
        }
        return entries
    }

    /// Every distinct edge of the side faces as an open line (shared edges once, so the stroke
    /// outline never unions coincident contours): Mesh every quad's edges; Wireframe (`rings`)
    /// the front and rear outlines and the edges running front to back.
    static func edges(_ faces: [ExtrudeFace], rings: Bool) -> DisplayPath {
        struct Key: Hashable {
            let a: SIMD2<Int64>
            let b: SIMD2<Int64>
        }
        func quantized(_ point: Point) -> SIMD2<Int64> {
            SIMD2(Int64((point.x * 1024).rounded()), Int64((point.y * 1024).rounded()))
        }
        var seen: Set<Key> = []
        var path = DisplayPath()
        func add(_ a: Point, _ b: Point) {
            let qa = quantized(a)
            let qb = quantized(b)
            guard qa != qb else { return }
            let key = (qa.x, qa.y) < (qb.x, qb.y) ? Key(a: qa, b: qb) : Key(a: qb, b: qa)
            guard seen.insert(key).inserted else { return }
            path.move(to: a)
            path.addLine(to: b)
        }
        for face in faces {
            switch face.kind {
            case .front, .rear:
                guard rings else { continue }
                for index in face.polygon.indices {
                    add(face.polygon[index], face.polygon[(index + 1) % face.polygon.count])
                }
            case .side:
                let quad = face.polygon
                // Front to back edges always; ring edges for Mesh.
                add(quad[0], quad[3])
                add(quad[1], quad[2])
                if !rings {
                    add(quad[0], quad[1])
                    add(quad[3], quad[2])
                }
            }
        }
        return path
    }

    /// A nested extrusion reads as its child.
    static func nestedChild(_ item: DisplayItem) -> DisplayItem {
        if case .group(let group) = item, case .extrude = group.live, let inner = group.children.first {
            return nestedChild(inner)
        }
        return item
    }
}
