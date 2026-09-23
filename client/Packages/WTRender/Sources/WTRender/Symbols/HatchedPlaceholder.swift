// The hatched placeholder: what a missing symbol's instance (LIB-010) and an unencodable
// barcode (DATA-018) draw -- a light rectangle crossed by diagonal hatching, outlined, with a
// name centred in it when one is given.  It is one atomic group, hit tested as its rectangle.

import WTGeometry

public enum HatchedPlaceholder {
    /// The hatching's spacing, in local units.
    public static let spacing = 6.0
    static let paper = Color(white: 0.92)
    static let ink = Color(white: 0.45)

    /// The placeholder over `rect` (local space) placed by `transform`, labelled `name` by
    /// `typesetter`.
    public static func item(rect: Rect, name: String = "", transform: AffineTransform = .identity, typesetter: LabelTypesetter? = nil) -> DisplayItem {
        let outline = DisplayPath(rect: rect)
        var hatch = DisplayPath()
        var offset = -rect.height
        while offset < rect.width {
            hatch.move(to: Point(x: rect.minX + offset, y: rect.maxY))
            hatch.addLine(to: Point(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += spacing
        }
        let line = StrokeStyle(width: 0.5)
        var children: [DisplayItem] = [
            .path(PathItem(path: outline, appearance: Appearance([.fill(FillPaint(paint: .solid(paper)))]), transform: transform)),
            .group(GroupItem(
                children: [.path(PathItem(path: hatch, appearance: Appearance([.stroke(StrokePaint(paint: .solid(ink), style: line))]), transform: transform))],
                clip: outline,
                transform: transform
            )),
            .path(PathItem(path: outline, appearance: Appearance([.stroke(StrokePaint(paint: .solid(ink), style: line))]), transform: transform)),
        ]
        if let typesetter, !name.isEmpty {
            let baseline = Point(x: rect.midX, y: rect.midY - typesetter.lineHeight / 2 + typesetter.ascent)
            children += typesetter.label(name, at: baseline, alignment: .center, color: .black).map { $0.transformed(by: transform) }
        }
        var group = GroupItem(children: children)
        group.atomic = true
        return .group(group)
    }
}
