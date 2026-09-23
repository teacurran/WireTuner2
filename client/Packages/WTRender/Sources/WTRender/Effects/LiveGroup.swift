// The wrapper node kinds whose drawing is derived on read (FX-025/026/029 blends, FX-018/019/022
// extrusions, FX-038 envelopes, FX-042 perspective), as display-list values: a `GroupItem` whose
// children are the wrapper's live children and whose `live` carries the wrapper's props, with
// every reference resolved by WTModel (node refs as child indices, element ids as anchor
// positions, grid and envelope geometry in pasteboard space).  They mirror `blend.proto`,
// `extrude.proto`, `envelope.proto` and `perspective.proto`; WTRender does not import WTProto.

import WTGeometry

public enum LiveGroup: Hashable, Sendable {
    case blend(BlendSpec)
    case extrude(ExtrudeSpec)
    case envelope(EnvelopeSpec)
    case perspective(PerspectiveSpec)
}

// MARK: - Blends

/// `BlendProps`, resolved.  The key objects are the group's children in blend order (bottom
/// first), except the child `path` names.
public struct BlendSpec: Hashable, Sendable {
    public enum BlendType: Hashable, Sendable {
        case normal
        case horizontal
        case vertical
    }

    public enum Order: Hashable, Sendable {
        case positional
        case stacking
    }

    /// Steps between adjacent key objects, 1 ... 1000; 0 reads the default from the colour
    /// difference.
    public var steps: Int
    /// Percent, 0 ... 100.
    public var rangeFirst: Double
    /// Percent, 0 ... 100; 0 reads 100.
    public var rangeLast: Double
    public var type: BlendType
    public var order: Order
    /// The child index of the path the blend follows; nil, out of range or not a path: straight.
    public var path: Int?
    public var showPath: Bool
    public var rotateOnPath: Bool
    /// Which anchor each key object's steps start from.
    public var blendPoints: [BlendPoint]

    public init(steps: Int = 0, rangeFirst: Double = 0, rangeLast: Double = 0, type: BlendType = .normal, order: Order = .positional, path: Int? = nil, showPath: Bool = false, rotateOnPath: Bool = true, blendPoints: [BlendPoint] = []) {
        self.steps = steps
        self.rangeFirst = rangeFirst
        self.rangeLast = rangeLast
        self.type = type
        self.order = order
        self.path = path
        self.showPath = showPath
        self.rotateOnPath = rotateOnPath
        self.blendPoints = blendPoints
    }
}

/// A key object's blend point: child index, contour and anchor (as `CornerPoint` counts them).
public struct BlendPoint: Hashable, Sendable {
    public var child: Int
    public var contour: Int
    public var anchor: Int

    public init(child: Int, contour: Int = 0, anchor: Int) {
        self.child = child
        self.contour = contour
        self.anchor = anchor
    }
}

// MARK: - Extrusions

/// `ExtrudeProps`, resolved.  The extruded shape is the group's first child; further children
/// (a merged state with several) draw flat above it.
public struct ExtrudeSpec: Hashable, Sendable {
    public enum SurfaceKind: Hashable, Sendable, CaseIterable {
        case flat
        case shaded
        case wireframe
        case mesh
        case hiddenMesh
    }

    public enum LightDirection: Hashable, Sendable, CaseIterable {
        case none
        case topLeft
        case top
        case topRight
        case left
        case front
        case right
        case bottomLeft
        case bottom
        case bottomRight
    }

    public struct Light: Hashable, Sendable {
        public var direction: LightDirection
        /// 0 ... 100.
        public var intensity: Double

        public init(direction: LightDirection = .none, intensity: Double = 0) {
            self.direction = direction
            self.intensity = intensity
        }
    }

    public enum ProfileKind: Hashable, Sendable {
        case none
        case bevel
        case staticAngle
    }

    public struct Profile: Hashable, Sendable {
        public var kind: ProfileKind
        /// The pasted open path, one contour, in its own space: x runs front to back, y is the
        /// offset from the outline (positive outward).
        public var path: DisplayPath?
        /// Static only, degrees.
        public var angle: Double
        /// Front-to-back slices, 1 ... 100; 0 reads 1.
        public var steps: Int
        /// Degrees clockwise at the rear face.
        public var twist: Double

        public init(kind: ProfileKind = .none, path: DisplayPath? = nil, angle: Double = 0, steps: Int = 0, twist: Double = 0) {
            self.kind = kind
            self.path = path
            self.angle = angle
            self.steps = steps
            self.twist = twist
        }
    }

    /// Depth in points, 0 ... 32000.
    public var length: Double
    /// Pasteboard; non-finite coordinates read as a vanishing point at infinity straight behind.
    public var vanishingPoint: Point
    public var z: Double
    /// Degrees about x, then y, then z.
    public var rotationX: Double
    public var rotationY: Double
    public var rotationZ: Double
    public var surface: SurfaceKind
    /// Curve subdivisions, 1 ... 100; 0 reads 10.
    public var surfaceSteps: Int
    /// 0 ... 100.
    public var ambient: Double
    public var light1: Light
    public var light2: Light
    public var profile: Profile

    public init(length: Double = 0, vanishingPoint: Point = .zero, z: Double = 0, rotationX: Double = 0, rotationY: Double = 0, rotationZ: Double = 0, surface: SurfaceKind = .shaded, surfaceSteps: Int = 0, ambient: Double = 0, light1: Light = Light(), light2: Light = Light(), profile: Profile = Profile()) {
        self.length = length
        self.vanishingPoint = vanishingPoint
        self.z = z
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
        self.surface = surface
        self.surfaceSteps = surfaceSteps
        self.ambient = ambient
        self.light1 = light1
        self.light2 = light2
        self.profile = profile
    }

    public var effectiveLength: Double { length.isFinite ? min(max(length, 0), 32000) : 0 }
    public var effectiveSurfaceSteps: Int { surfaceSteps == 0 ? 10 : min(max(surfaceSteps, 1), 100) }
    public var effectiveProfileSteps: Int { profile.steps == 0 ? 1 : min(max(profile.steps, 1), 100) }
}

// MARK: - Envelopes

/// `EnvelopeProps`, resolved to pasteboard space.
public struct EnvelopeSpec: Hashable, Sendable {
    /// The envelope outline: the first live closed contour is the envelope.
    public var contour: DisplayPath
    /// The rectangle the contents are mapped from.
    public var sourceBounds: Rect
    /// Anchor indices of contour 0 for the TL, TR, BR and BL corners; missing or invalid ones
    /// fall back to the anchor nearest that corner of the envelope's bounds.
    public var corners: [Int?]
    /// Draw the warp map (view state).
    public var showMap: Bool

    public init(contour: DisplayPath, sourceBounds: Rect, corners: [Int?] = [nil, nil, nil, nil], showMap: Bool = false) {
        self.contour = contour
        self.sourceBounds = sourceBounds
        self.corners = corners
        self.showMap = showMap
    }
}

// MARK: - Perspective

/// A `PerspectiveGrid`, resolved to pasteboard space (y down).
public struct PerspectiveGridSpec: Hashable, Sendable {
    /// 1 ... 3; 0 reads 2.
    public var vanishingPoints: Int
    /// Points; 0 reads 36.
    public var cellSize: Double
    public var horizonY: Double
    /// One-point grids: the vanishing point; two and three: the left one.
    public var leftVP: Point
    public var rightVP: Point
    public var verticalVP: Point
    public var leftWallX: Double
    public var rightWallX: Double
    public var floorFrontY: Double

    public init(vanishingPoints: Int = 2, cellSize: Double = 36, horizonY: Double = 0, leftVP: Point = .zero, rightVP: Point = .zero, verticalVP: Point = .zero, leftWallX: Double = 0, rightWallX: Double = 0, floorFrontY: Double = 0) {
        self.vanishingPoints = vanishingPoints
        self.cellSize = cellSize
        self.horizonY = horizonY
        self.leftVP = leftVP
        self.rightVP = rightVP
        self.verticalVP = verticalVP
        self.leftWallX = leftWallX
        self.rightWallX = rightWallX
        self.floorFrontY = floorFrontY
    }

    public var effectiveVanishingPoints: Int { vanishingPoints == 0 ? 2 : min(max(vanishingPoints, 1), 3) }
    public var effectiveCellSize: Double { cellSize > 0 && cellSize.isFinite ? cellSize : 36 }

    /// The built-in two-point grid for a page: the horizon across the middle, vanishing points at
    /// the page's sides, walls meeting at the centre and the floor's near edge at three quarters.
    public static func defaultGrid(page: Rect) -> PerspectiveGridSpec {
        PerspectiveGridSpec(
            vanishingPoints: 2,
            cellSize: 36,
            horizonY: page.midY,
            leftVP: Point(x: page.minX, y: page.midY),
            rightVP: Point(x: page.maxX, y: page.midY),
            verticalVP: Point(x: page.midX, y: page.minY - page.height),
            leftWallX: page.midX,
            rightWallX: page.midX,
            floorFrontY: page.minY + page.height * 0.75
        )
    }
}

/// `PerspectiveProps`, resolved.  The projected object is the group's first child.
public struct PerspectiveSpec: Hashable, Sendable {
    public enum Plane: Hashable, Sendable, CaseIterable {
        case leftWall
        case rightWall
        case floorLeft
        case floorRight
        case wall
        case floor
    }

    public var grid: PerspectiveGridSpec
    public var plane: Plane
    /// Where the child's bounds sit, in cells: u along the plane's horizontal lines, v along its
    /// receding (or vertical) lines.
    public var cellPosition: Point
    /// Cells; ≤ 0 reads the child's flat size in cells.
    public var cellWidth: Double
    public var cellHeight: Double
    public var flipped: Bool

    public init(grid: PerspectiveGridSpec, plane: Plane = .leftWall, cellPosition: Point = .zero, cellWidth: Double = 0, cellHeight: Double = 0, flipped: Bool = false) {
        self.grid = grid
        self.plane = plane
        self.cellPosition = cellPosition
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.flipped = flipped
    }

    /// The plane as the grid reads it: walls and floors map across one- and multi-point grids.
    public var effectivePlane: Plane {
        let onePoint = grid.effectiveVanishingPoints == 1
        switch plane {
        case .leftWall, .rightWall: return onePoint ? .wall : plane
        case .floorLeft, .floorRight: return onePoint ? .floor : plane
        case .wall: return onePoint ? .wall : .leftWall
        case .floor: return onePoint ? .floor : .floorLeft
        }
    }
}
