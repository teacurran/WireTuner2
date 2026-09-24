// A group's *Transform as unit* (OBJ-017; docs/_includes/objects/grouping.adoc, "Client").
// `GroupProps.transform_as_unit` decides whether a group's own matrix scales its members'
// strokes.  On, strokes are generated in member space and transformed with the member: a group
// scaled 300% strokes a 1 pt member at 3 pt.  Off (the default), strokes keep their nominal width
// however the group is scaled: the member's stroke widths are divided by the group matrix's scale
// factor before the flattened transform applies, so a group scaled 300% still strokes at 1 pt.
//
// The display list flattens enclosing transforms into each leaf (`DisplayItem.transformed(by:)`),
// so the renderers always stroke in local space under the item's transform; nominal width is
// therefore expressed as a compensated width rather than as a re-stroked pasteboard-space path,
// which keeps gradients, patterns and effects in their local space untouched.  For a uniform
// scale (with any rotation or reflection) the result is exactly the pasteboard-space stroke; for
// a non-uniform or skewed group matrix the width is the matrix's geometric-mean scale
// (`AffineTransform.scaleFactor`) and the pen still follows the matrix's shape.

import WTGeometry

/// How a group's matrix treats its members' strokes.
public enum GroupStrokeMode: Hashable, Sendable {
    /// *Transform as unit* on: the group matrix scales stroke widths with the geometry.
    case asUnit
    /// Off: strokes stay at their nominal width.
    case nominal

    /// The mode of a group whose `transform_as_unit` register holds `transformAsUnit`.
    public init(transformAsUnit: Bool) {
        self = transformAsUnit ? .asUnit : .nominal
    }
}

public enum GroupStrokes {
    /// `children` (already placed under the group's flattened transform) with the stroke widths
    /// the group's `mode` asks for: unchanged as a unit, or divided by the scale factor of the
    /// group's own matrix `groupTransform` when nominal.  A singular matrix, or one that does not
    /// scale, leaves the children as they are.
    public static func children(_ children: [DisplayItem], groupTransform: AffineTransform, mode: GroupStrokeMode) -> [DisplayItem] {
        guard mode == .nominal else {
            return children
        }
        let scale = groupTransform.scaleFactor
        guard scale.isFinite, scale > 1e-12, abs(scale - 1) > 1e-12 else {
            return children
        }
        return children.map { $0.scalingStrokeWidths(by: 1 / scale) }
    }
}

extension DisplayItem {
    /// The item with every stroke it draws `factor` times as wide: widths, dash patterns,
    /// calligraphic nibs and custom tiles (fills, images and text are unchanged).
    public func scalingStrokeWidths(by factor: Double) -> DisplayItem {
        switch self {
        case .stroke(var item):
            item.style = item.style.scaled(by: factor)
            return .stroke(item)
        case .path(var item):
            item.appearance.items = item.appearance.items.map { element in
                guard case .stroke(let stroke) = element else {
                    return element
                }
                return .stroke(stroke.scaled(by: factor))
            }
            return .path(item)
        case .group(var item):
            item.children = item.children.map { $0.scalingStrokeWidths(by: factor) }
            return .group(item)
        case .fill, .image, .text:
            return self
        }
    }
}

extension StrokeStyle {
    /// The style `factor` times as wide; a hairline (width 0) and device-pixel dashes stay.
    func scaled(by factor: Double) -> StrokeStyle {
        var style = self
        style.width *= factor
        if !(width == 0 && dashInDevicePixels) {
            style.dash = dash.map { $0 * factor }
            style.dashPhase *= factor
        }
        return style
    }
}

extension StrokePaint {
    /// The stroke `factor` times as wide, whatever its kind.
    func scaled(by factor: Double) -> StrokePaint {
        var stroke = self
        stroke.style = style.scaled(by: factor)
        switch kind {
        case .calligraphic(var nib):
            nib.width *= factor
            nib.height *= factor
            stroke.kind = .calligraphic(nib)
        case .custom(var custom):
            custom.length *= factor
            custom.spacing *= factor
            stroke.kind = .custom(custom)
        case .basic, .brush:
            break
        }
        return stroke
    }
}
