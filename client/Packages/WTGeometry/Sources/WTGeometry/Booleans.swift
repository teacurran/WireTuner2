/// The four set operations of two regions.
public enum BooleanOperation: Hashable, Sendable, CaseIterable {
    /// Covered by either (Union).
    case union
    /// Covered by both (Intersect, Crop, the Transparency overlap).
    case intersection
    /// Covered by the first and not the second (Punch).
    case subtraction
    /// Covered by exactly one (the Combine live effect's exclusion).
    case exclusiveOr

    /// Whether a point covered as given belongs to the result.
    @inlinable
    public func includes(_ a: Bool, _ b: Bool) -> Bool {
        switch self {
        case .union: return a || b
        case .intersection: return a && b
        case .subtraction: return a && !b
        case .exclusiveOr: return a != b
        }
    }
}

/// One region of a Divide: the area covered by exactly the operands in `operands`.
public struct DividedPiece: Hashable, Sendable {
    /// A connected region (one outer contour and its holes).
    public var path: FilledPath
    /// Indices, ascending, of the input paths covering this region.  The spec gives the piece
    /// the attributes of the frontmost of them.
    public var operands: [Int]

    public init(path: FilledPath, operands: [Int]) {
        self.path = path
        self.operands = operands
    }
}

/// Boolean operations on filled paths: the Combine commands of `combining-paths` (GEO-002).
///
/// Curves stay curves: nothing is flattened.  Each operation builds the planar arrangement of
/// its operands (see `Arrangement`), classifies every edge by which operands cover each side,
/// and stitches the edges on the boundary of the requested region into contours.  Operands may
/// have any number of contours, open contours (closed by a chord for filling), self-crossing
/// contours, and either fill rule; coincident edges, tangencies, containment and identical
/// operands need no special case, because an edge shared by both operands is one edge whose
/// sides are classified like any other.
///
/// Results are normalized (see ``FilledPath``): non-crossing contours, outer ones positive and
/// holes negative, non-zero rule.  An empty result has no contours.  No input crashes or hangs:
/// every loop is capped, and a region the arithmetic cannot resolve is left out rather than
/// looped on.
///
/// Tolerance: ``Options/tolerance`` (default 1e-6 pasteboard units, raised to 1e-11 of the
/// operands' extent for very large artwork) is the distance within which curves meet, share a
/// stretch or end at the same vertex.  Features smaller than ten times it are merged away.
public enum Boolean {
    public struct Options: Hashable, Sendable {
        public var tolerance: Double
        /// Cap on split parameters per segment.
        public var maxSplitsPerSegment: Int

        public init(tolerance: Double = 1e-6, maxSplitsPerSegment: Int = 256) {
            self.tolerance = tolerance
            self.maxSplitsPerSegment = maxSplitsPerSegment
        }

        public static let standard = Options()
    }

    /// `a` combined with `b` by `operation`.
    public static func perform(_ operation: BooleanOperation, _ a: FilledPath, _ b: FilledPath, options: Options = .standard) -> FilledPath {
        let arrangement = Arrangement(operands: [a, b], options: options)
        return arrangement.extract { operation.includes($0[0], $0[1]) }
    }

    public static func union(_ a: FilledPath, _ b: FilledPath, options: Options = .standard) -> FilledPath {
        perform(.union, a, b, options: options)
    }

    public static func intersection(_ a: FilledPath, _ b: FilledPath, options: Options = .standard) -> FilledPath {
        perform(.intersection, a, b, options: options)
    }

    /// `a` with `b` cut out of it.
    public static func subtracting(_ a: FilledPath, _ b: FilledPath, options: Options = .standard) -> FilledPath {
        perform(.subtraction, a, b, options: options)
    }

    public static func exclusiveOr(_ a: FilledPath, _ b: FilledPath, options: Options = .standard) -> FilledPath {
        perform(.exclusiveOr, a, b, options: options)
    }

    /// Union: everything any path covers, as one path (disjoint parts become sub-paths).
    public static func union(_ paths: [FilledPath], options: Options = .standard) -> FilledPath {
        Arrangement(operands: paths, options: options).extract { $0.contains(true) }
    }

    /// Intersect: the area common to *all* paths; empty when there is none (the command then
    /// deletes the selection).
    public static func intersection(_ paths: [FilledPath], options: Options = .standard) -> FilledPath {
        guard !paths.isEmpty else {
            return .empty
        }
        return Arrangement(operands: paths, options: options).extract { !$0.contains(false) }
    }

    /// Punch: `cutter` removed from every target, each keeping its own identity.  A target the
    /// cutter covers completely comes back empty.
    public static func punch(_ targets: [FilledPath], with cutter: FilledPath, options: Options = .standard) -> [FilledPath] {
        targets.map { subtracting($0, cutter, options: options) }
    }

    /// Crop: every target trimmed to `cutter`'s outline.
    public static func crop(_ targets: [FilledPath], with cutter: FilledPath, options: Options = .standard) -> [FilledPath] {
        targets.map { intersection($0, cutter, options: options) }
    }

    /// Transparency: the overlap of the two paths, which the command fills with the mixed
    /// color on top of the (kept) inputs.  Empty when they do not overlap.
    public static func transparency(_ back: FilledPath, _ front: FilledPath, options: Options = .standard) -> FilledPath {
        intersection(back, front, options: options)
    }

    /// Divide: every connected region covered by at least one path, with the paths covering
    /// it.  Pieces are ordered by covering set (fewest operands first, then lowest indices),
    /// then by position (top-left first), so the output is deterministic.
    public static func divide(_ paths: [FilledPath], options: Options = .standard) -> [DividedPiece] {
        let arrangement = Arrangement(operands: paths, options: options)
        var result: [DividedPiece] = []
        let classes = arrangement.coverageClasses().sorted { lhs, rhs in
            let l = lhs.indices.filter { lhs[$0] }
            let r = rhs.indices.filter { rhs[$0] }
            return l.count != r.count ? l.count < r.count : l.lexicographicallyPrecedes(r)
        }
        for coverage in classes {
            let region = arrangement.extract { $0 == coverage }
            let operands = coverage.indices.filter { coverage[$0] }
            let pieces = region.pieces().sorted { a, b in
                let ba = a.bounds
                let bb = b.bounds
                return (ba.minY, ba.minX) < (bb.minY, bb.minX)
            }
            for piece in pieces {
                result.append(DividedPiece(path: piece, operands: operands))
            }
        }
        return result
    }

    /// The region a path fills, redrawn with non-crossing contours (menu:Modify[Alter Path >
    /// Remove Overlap], and the cleanup after a self-crossing brush stroke).
    public static func normalize(_ path: FilledPath, options: Options = .standard) -> FilledPath {
        Arrangement(operands: [path], options: options).extract { $0[0] }
    }
}
