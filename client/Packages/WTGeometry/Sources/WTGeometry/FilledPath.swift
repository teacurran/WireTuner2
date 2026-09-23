/// A filled region: the contours of one path and the fill rule that decides what is inside
/// (`combining-paths`; `vector-basics`, "Even/odd fill").  This is what the boolean
/// operations consume and produce.
///
/// Open contours count as closed by a straight segment from end to start, as their fill
/// paints.  The output of every ``Boolean`` operation is *normalized*: its contours do not
/// cross or overlap, outer contours run in the positive rotation direction and holes in the
/// negative one, so it fills identically under either rule and its ``signedArea()`` is its
/// area.
public struct FilledPath: Hashable, Sendable {
    public var contours: [Contour]
    public var fillRule: FillRule

    public init(contours: [Contour], fillRule: FillRule = .nonZero) {
        self.contours = contours
        self.fillRule = fillRule
    }

    public init(_ contour: Contour, fillRule: FillRule = .nonZero) {
        self.contours = [contour]
        self.fillRule = fillRule
    }

    /// The region covering nothing.
    public static let empty = FilledPath(contours: [])

    /// Whether no contour has a segment.
    public var isEmpty: Bool {
        contours.allSatisfy(\.isEmpty)
    }

    /// Tight bounds of every contour; `Rect.null` when empty.
    public var bounds: Rect {
        var result = Rect.null
        for contour in contours {
            result.formUnion(contour.bounds)
        }
        return result
    }

    /// The sum of the contours' winding numbers at `point`.
    public func windingNumber(at point: Point) -> Int {
        var winding = 0
        for contour in contours {
            winding += contour.windingNumber(at: point)
        }
        return winding
    }

    /// The sum of the contours' ray crossing counts at `point`.
    public func crossingCount(at point: Point) -> Int {
        var count = 0
        for contour in contours {
            count += contour.crossingCount(at: point)
        }
        return count
    }

    /// Whether `point` is filled under the path's rule.
    public func contains(_ point: Point) -> Bool {
        fillRule.isInside(windingNumber: windingNumber(at: point))
    }

    /// The sum of the contours' signed areas: the area of a normalized path, and for any path
    /// the integral of the winding number over the plane.
    public func signedArea() -> Double {
        var total = 0.0
        for contour in contours {
            total += contour.signedArea()
        }
        return total
    }

    /// Every contour traversed the other way.
    public func reversed() -> FilledPath {
        FilledPath(contours: contours.map { $0.reversed() }, fillRule: fillRule)
    }

    public func applying(_ transform: AffineTransform) -> FilledPath {
        FilledPath(contours: contours.map { $0.applying(transform) }, fillRule: fillRule)
    }

    /// The connected pieces of a normalized path: each positively wound contour with the holes
    /// (negatively wound contours) that lie inside it, innermost container winning.  A hole no
    /// outer contour contains becomes a piece of its own so nothing is lost; contours without
    /// area are dropped.
    public func pieces() -> [FilledPath] {
        var outers: [(contour: Contour, area: Double)] = []
        var holes: [Contour] = []
        for contour in contours where !contour.isEmpty {
            let area = contour.signedArea()
            if area > 0 {
                outers.append((contour, area))
            } else if area < 0 {
                holes.append(contour)
            }
        }
        var groups = outers.map { [$0.contour] }
        var orphans: [Contour] = []
        for hole in holes {
            let probe = hole.segments[0].evaluate(0.5)
            var best: Int?
            for (index, outer) in outers.enumerated() where outer.contour.windingNumber(at: probe) != 0 {
                if best == nil || outer.area < outers[best!].area {
                    best = index
                }
            }
            if let index = best {
                groups[index].append(hole)
            } else {
                orphans.append(hole)
            }
        }
        var result = groups.map { FilledPath(contours: $0, fillRule: fillRule) }
        result.append(contentsOf: orphans.map { FilledPath($0, fillRule: fillRule) })
        return result
    }
}

extension FillRule {
    /// Whether a point with this winding number is filled.
    @inlinable
    public func isInside(windingNumber: Int) -> Bool {
        switch self {
        case .nonZero: return windingNumber != 0
        case .evenOdd: return windingNumber & 1 != 0
        }
    }
}

extension CubicBezier {
    /// `½∫₀¹ B(t) × B′(t) dt`: this segment's share of the enclosed area of a contour by
    /// Green's theorem, positive on the ``Vector/perpendicular`` side.  The integrand is a
    /// degree-5 polynomial, which 3-point Gauss–Legendre integrates exactly.
    public func signedAreaContribution() -> Double {
        let node = (3.0 / 5.0).squareRoot()
        func f(_ t: Double) -> Double {
            let p = evaluate(t)
            let d = derivative(t)
            return p.x * d.dy - p.y * d.dx
        }
        let mid = 0.5
        let half = 0.5
        let sum = (8.0 / 9.0) * f(mid) + (5.0 / 9.0) * (f(mid - half * node) + f(mid + half * node))
        return 0.5 * sum * half
    }
}

extension Contour {
    /// The signed area enclosed by the (implicitly closed) contour: positive when it runs in
    /// the positive rotation direction, and exact for cubics up to rounding.
    public func signedArea() -> Double {
        var total = 0.0
        for segment in segments {
            total += segment.signedAreaContribution()
        }
        if let closing = closingSegment {
            total += closing.signedAreaContribution()
        }
        return total
    }
}
