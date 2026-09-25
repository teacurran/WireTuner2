import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Swatches dropped with a gradient modifier (gradients.adoc, "To apply a gradient by dragging a
/// swatch onto an object"; ATTR-028): kbd:[Control] makes a linear gradient from the swatch's colour
/// to the fill's current colour, running from the drop point through the object's centre;
/// kbd:[Option] a radial gradient centred at the drop point; kbd:[Cmd+Option] a contour gradient
/// centred there.  The gradient goes on the object under the pointer (a group's member, never the
/// whole group), as one `ApplyGradient` change.  Only swatch drags take these rules; any other
/// colour drag keeps the canvas drop's own modifiers.
enum GradientDrop {
    /// The gradient type a drop with `modifiers` makes; nil without a gradient modifier.
    static func type(for modifiers: KeyModifiers) -> Wiretuner_Doc_V1_GradientType? {
        if modifiers.contains(.option) { return modifiers.contains(.command) ? .contour : .radial }
        return modifiers.contains(.control) ? .linear : nil
    }

    /// Whether a drag carrying `ref` with `modifiers` makes a gradient.
    static func applies(_ ref: Wiretuner_Doc_V1_ColorRef, modifiers: KeyModifiers) -> Bool {
        ColorResolver.swatch(of: ref) != nil && type(for: modifiers) != nil
    }

    /// The gradient: the swatch at the drop point (`drop`, object-local), the fill's current colour
    /// (`current`) at the far end, sized to `bounds` (object-local).
    static func gradient(_ type: Wiretuner_Doc_V1_GradientType, swatch: Wiretuner_Doc_V1_ColorRef, current: Wiretuner_Doc_V1_ColorRef, drop: Point,
                         bounds: Rect) -> Wiretuner_Doc_V1_GradientFill {
        let center = bounds.center
        let end: Point
        if type == .linear {
            // Through the centre to the far side; a drop on the centre runs left to right.
            let direction = center - drop
            end = direction.lengthSquared > 1e-12 ? center + direction : Point(x: bounds.maxX, y: center.y)
        } else {
            let corners = [Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.maxY),
                           Point(x: bounds.minX, y: bounds.maxY)]
            let far = corners.max { $0.distance(to: drop) < $1.distance(to: drop) }!
            end = Point(x: drop.x + far.distance(to: drop), y: drop.y)
        }
        return .with { fill in
            fill.type = type
            fill.axis = .with { axis in
                axis.start = .with { $0.x = drop.x; $0.y = drop.y }
                axis.end = .with { $0.x = end.x; $0.y = end.y }
            }
            fill.stops = [
                .with { $0.offset = 0; $0.color = swatch },
                .with { $0.offset = 1; $0.color = current },
            ]
        }
    }

    /// The change a drop of `ref` at `pasteboardPoint` on `node` makes with `modifiers`; nil when
    /// the modifiers make no gradient or the object is not drawn.
    @MainActor
    static func command(_ ref: Wiretuner_Doc_V1_ColorRef, on node: OpID, at pasteboardPoint: Point, modifiers: KeyModifiers,
                        document: DocumentHandle) -> (any WTModel.Command)? {
        guard applies(ref, modifiers: modifiers), let type = type(for: modifiers), let object = document.object(for: SelectionID(node)),
              let bounds = object.bounds, let inverse = object.transform.inverted() else { return nil }
        let local: Rect
        if case .path(let item) = object.item {
            local = EffectCenterHandles.ownBounds(item.path)
        } else {
            let corners = [Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.maxY)].map(inverse.apply)
            local = Rect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y), width: abs(corners[1].x - corners[0].x),
                         height: abs(corners[1].y - corners[0].y))
        }
        var current = ColorResolver.inline(.white)
        if let fill = EyedropperSampling.basicColor(node, target: .fill, in: document.state), !fill.none { current = fill }
        return ApplyGradient([node], gradient: gradient(type, swatch: ref, current: current, drop: inverse.apply(pasteboardPoint), bounds: local))
    }
}
