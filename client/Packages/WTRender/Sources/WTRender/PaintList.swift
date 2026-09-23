// The display list lowered to what the Metal renderer draws (REND-006): filled polygons in
// device pixels, each with a fill rule, a premultiplied colour and a blend mode, and nested
// groups composited through offscreen textures with a clip and an opacity.  The lowering
// mirrors `CoreGraphicsRenderer`'s drawing rules item for item -- attribute stacks bottom
// first, arrowheads, hairlines one device pixel from the CTM, view modes, overprint preview --
// so the two renderers differ only in how a polygon becomes pixels, which is what REND-007
// compares.  Strokes arrive as filled outlines: until GEO-003's expanded outlines are in the
// display list, the outline is Core Graphics' `copy(strokingWithWidth:)` of the (dashed)
// centreline, the same stroker the reference renderer uses.

import WTGeometry
import CoreGraphics

/// How a fill composites onto what is beneath it.
enum PaintBlend: Hashable, Sendable {
    /// Source over.
    case normal
    /// The multiply blend mode, for overprint preview.
    case multiply
}

/// One polygon fill.
struct PaintFill: Hashable, Sendable {
    var path: FlatPath
    var rule: FillRule
    /// Premultiplied sRGB, the renderer's working space.
    var color: SIMD4<Float>
    var blend: PaintBlend
}

/// Children drawn into their own surface, then composited through `clip` at `opacity`.
struct PaintGroup: Hashable, Sendable {
    var operations: [PaintOperation]
    var clip: FlatPath?
    var clipRule: FillRule
    var opacity: Double
}

/// One lowered drawing operation.
indirect enum PaintOperation: Hashable, Sendable {
    case fill(PaintFill)
    case group(PaintGroup)
}

/// Lowers a display list for one surface (a tile or a view) to paint operations.
struct PaintListBuilder: Sendable {
    let viewMode: ViewMode
    let overprintPreview: Bool
    let flattener: PathFlattener
    /// Debug switch for REND-007's self-test: every declared fill rule is swapped (non-zero
    /// for even-odd and back), which must fail exactly the tiles the rule matters in.
    let swapsFillRules: Bool
    /// The surface in device pixels; geometry is clipped to it (with a margin) before it is
    /// handed to the GPU.
    private let clipBounds: Rect
    private let surface: Rect

    init(viewMode: ViewMode, overprintPreview: Bool, tolerance: FlatteningTolerance, surface: Rect, swapsFillRules: Bool = false) {
        self.viewMode = viewMode
        self.overprintPreview = overprintPreview
        flattener = PathFlattener(tolerance: tolerance)
        self.swapsFillRules = swapsFillRules
        self.surface = surface
        clipBounds = surface.expanded(by: 64)
    }

    /// Inherited down the group tree, as in the Core Graphics renderer.
    private struct State {
        var alpha: Double = 1
        var highlight: Color = .black
    }

    /// The operations drawing the items of `displayList` that intersect `cull` (pasteboard),
    /// mapped through `pasteboardTransform` (pasteboard → device pixels).
    func operations(for displayList: DisplayList, pasteboardTransform: AffineTransform, cull: Rect) -> [PaintOperation] {
        var result: [PaintOperation] = []
        for index in displayList.indices(intersecting: cull) {
            lower(displayList.items[index], base: pasteboardTransform, state: State(), cull: cull, into: &result)
        }
        return result
    }

    // MARK: Items

    private func lower(_ item: DisplayItem, base: AffineTransform, state: State, cull: Rect, into result: inout [PaintOperation]) {
        if viewMode.isKeyline {
            lowerKeyline(item, base: base, state: state, cull: cull, into: &result)
            return
        }
        switch item {
        case .fill(let fill):
            if let color = fill.paint.color {
                addFill(fill.path, transform: fill.transform.concatenating(base), rule: fill.rule, color: color, state: state, into: &result)
            }
        case .stroke(let stroke):
            if let color = stroke.paint.color {
                addStroke(stroke.path, style: stroke.style, transform: stroke.transform.concatenating(base), color: color, state: state, into: &result)
            }
        case .path(let path):
            lowerPath(path, base: base, state: state, into: &result)
        case .image(let image):
            let transform = image.transform.concatenating(base)
            if viewMode.drawsImagesAsBoxes {
                addImageBox(image, transform: transform, color: Color(white: 0.45), lineWidth: nil, state: state, into: &result)
            } else {
                addFill(DisplayPath(rect: image.rect), transform: transform, rule: .nonZero, color: Color(white: 0.75), state: state, into: &result)
                addImageBox(image, transform: transform, color: Color(white: 0.45), lineWidth: 1, state: state, into: &result)
            }
        case .text(let text):
            let transform = text.transform.concatenating(base)
            if shouldGreek(text) {
                addFill(DisplayPath(rect: text.bounds), transform: transform, rule: .nonZero, color: Color(white: 0.7), state: state, into: &result)
            } else if let run = text.glyphRun {
                addFill(run.outline, transform: transform, rule: .nonZero, color: text.color, declaredRule: false, state: state, into: &result)
            } else {
                addFill(DisplayPath(rect: text.bounds), transform: transform, rule: .nonZero, color: text.color.withAlpha(multipliedBy: 0.15), state: state, into: &result)
                var baseline = DisplayPath()
                baseline.move(to: Point(x: text.bounds.minX, y: text.origin.y))
                baseline.addLine(to: Point(x: text.bounds.maxX, y: text.origin.y))
                addStroke(baseline, style: StrokeStyle(width: 1), transform: transform, color: text.color, state: state, into: &result)
            }
        case .group(let group):
            lowerGroup(group, base: base, state: state, cull: cull, into: &result)
        }
    }

    /// The attribute stack bottom first, arrowheads after their stroke's body.
    private func lowerPath(_ item: PathItem, base: AffineTransform, state: State, into result: inout [PaintOperation]) {
        let transform = item.transform.concatenating(base)
        for element in item.appearance.items {
            switch element {
            case .fill(let fill):
                guard let color = fill.paint.color else { continue }
                addFill(item.path, transform: transform, rule: fill.rule, color: color, blend: blend(fill.overprint), state: state, into: &result)
            case .stroke(let stroke):
                guard let color = stroke.paint.color else { continue }
                let geometry = StrokeGeometry(path: item.path, stroke: stroke)
                let blend = blend(stroke.overprint)
                addStroke(stroke.hasArrowheads ? geometry.body : item.path, style: stroke.style, transform: transform, color: color, blend: blend, state: state, into: &result)
                for head in geometry.heads {
                    let headTransform = head.transform.concatenating(transform)
                    if head.arrowhead.filled {
                        addFill(head.arrowhead.shape, transform: headTransform, rule: .nonZero, color: color, blend: blend, declaredRule: false, state: state, into: &result)
                    } else {
                        let style = StrokeStyle(width: 1, cap: stroke.style.cap, join: stroke.style.join, miterLimit: stroke.style.miterLimit)
                        addStroke(head.arrowhead.shape, style: style, transform: headTransform, color: color, blend: blend, state: state, into: &result)
                    }
                }
            }
        }
    }

    private func lowerGroup(_ group: GroupItem, base: AffineTransform, state: State, cull: Rect, into result: inout [PaintOperation]) {
        var inner = state
        if let highlight = group.highlightColor {
            inner.highlight = highlight
        }
        let translucent = group.opacity < 1
        let layered = translucent && viewMode.drawsTransparencyGroups
        if layered {
            inner.alpha = 1  // a transparency layer starts at full alpha inside
        } else if translucent && !viewMode.isKeyline {
            inner.alpha = state.alpha * group.opacity
        }
        var children: [PaintOperation] = []
        for child in group.children {
            if let bounds = child.bounds, bounds.intersects(cull) {
                lower(child, base: base, state: inner, cull: cull, into: &children)
            }
        }
        let clip = group.clip.map { flattener.flatten($0, transform: group.transform.concatenating(base)).clipped(to: clipBounds) }
        guard clip != nil || layered else {
            result.append(contentsOf: children)
            return
        }
        result.append(.group(PaintGroup(operations: children, clip: clip, clipRule: group.clipRule, opacity: layered ? group.opacity : 1)))
    }

    // MARK: Keyline

    private func lowerKeyline(_ item: DisplayItem, base: AffineTransform, state: State, cull: Rect, into result: inout [PaintOperation]) {
        switch item {
        case .fill(let fill):
            addHairline(fill.path, transform: fill.transform.concatenating(base), color: state.highlight, into: &result)
        case .stroke(let stroke):
            addHairline(stroke.path, transform: stroke.transform.concatenating(base), color: state.highlight, into: &result)
        case .path(let path):
            let transform = path.transform.concatenating(base)
            addHairline(path.path, transform: transform, color: state.highlight, into: &result)
            for stroke in path.appearance.strokes where stroke.hasArrowheads {
                for head in StrokeGeometry(path: path.path, stroke: stroke).heads {
                    addHairline(head.arrowhead.shape, transform: head.transform.concatenating(transform), color: state.highlight, into: &result)
                }
            }
        case .image(let image):
            addImageBox(image, transform: image.transform.concatenating(base), color: state.highlight, lineWidth: nil, state: State(), into: &result)
        case .text(let text):
            let transform = text.transform.concatenating(base)
            if shouldGreek(text) {
                addFill(DisplayPath(rect: text.bounds), transform: transform, rule: .nonZero, color: Color(white: 0.7), state: State(), into: &result)
            } else if let run = text.glyphRun {
                addFill(run.outline, transform: transform, rule: .nonZero, color: state.highlight, declaredRule: false, state: State(), into: &result)
            } else {
                var outline = DisplayPath(rect: text.bounds)
                outline.move(to: Point(x: text.bounds.minX, y: text.origin.y))
                outline.addLine(to: Point(x: text.bounds.maxX, y: text.origin.y))
                addHairline(outline, transform: transform, color: state.highlight, into: &result)
            }
        case .group(let group):
            lowerGroup(group, base: base, state: state, cull: cull, into: &result)
        }
    }

    // MARK: Primitives

    private func shouldGreek(_ item: TextRunItem) -> Bool {
        viewMode.greeksText && item.bounds.applying(item.transform).height <= ViewMode.greekingThreshold
    }

    private func blend(_ overprint: Bool) -> PaintBlend {
        overprint && overprintPreview ? .multiply : .normal
    }

    /// One device pixel in the local units of `transform` (local → device pixels), as the
    /// Core Graphics renderer sizes hairlines from its CTM.
    static func hairlineWidth(for transform: AffineTransform) -> Double {
        let scale = abs(transform.determinant).squareRoot()
        return scale > 0 ? 1 / scale : 1
    }

    private func addFill(
        _ path: DisplayPath,
        transform: AffineTransform,
        rule: FillRule,
        color: Color,
        blend: PaintBlend = .normal,
        declaredRule: Bool = true,
        state: State,
        into result: inout [PaintOperation]
    ) {
        let flat = flattener.flatten(path, transform: transform)
        let effectiveRule = declaredRule && swapsFillRules ? (rule == .nonZero ? FillRule.evenOdd : .nonZero) : rule
        append(flat, rule: effectiveRule, color: color, blend: blend, state: state, into: &result)
    }

    private func addStroke(
        _ path: DisplayPath,
        style: StrokeStyle,
        transform: AffineTransform,
        color: Color,
        blend: PaintBlend = .normal,
        state: State,
        into result: inout [PaintOperation]
    ) {
        let width = style.isHairline ? PaintListBuilder.hairlineWidth(for: transform) : style.width
        // Core Graphics' stroker merges points closer than a fixed epsilon in path units, which
        // breaks outlines whose width is a small fraction of a unit (a hairline on a heavily
        // scaled arrowhead).  Stroking commutes with uniform scaling, so stroke in local units
        // scaled to roughly one per surface pixel and scale the outline back.
        let determinant = abs(transform.determinant).squareRoot()
        let normalization = determinant > 0 ? determinant : 1
        // Dashes are laid out in local units first, where Core Graphics' own dasher measures
        // them (its arc-length flattening depends on the scale, so dashing after scaling moves
        // dash ends along curves).
        var centreline = path.cgPath
        let dash = style.effectiveDash
        if !dash.isEmpty {
            centreline = centreline.copy(dashingWithPhase: CGFloat(style.dashPhase), lengths: dash.map { CGFloat($0) })
        }
        var scale = CGAffineTransform(scaleX: normalization, y: normalization)
        centreline = centreline.copy(using: &scale) ?? centreline
        let outline = centreline.copy(
            strokingWithWidth: CGFloat(width * normalization),
            lineCap: style.cap.cg,
            lineJoin: style.join.cg,
            miterLimit: CGFloat(style.miterLimit)
        )
        let outlineTransform = AffineTransform.scale(1 / normalization).concatenating(transform)
        append(flattener.flatten(outline, transform: outlineTransform), rule: .nonZero, color: color, blend: blend, state: state, into: &result)
    }

    private func addHairline(_ path: DisplayPath, transform: AffineTransform, color: Color, into result: inout [PaintOperation]) {
        addStroke(path, style: StrokeStyle(width: 0), transform: transform, color: color, state: State(), into: &result)
    }

    /// The image's frame and diagonals (`lineWidth` nil: hairlines, frame included) or only its
    /// diagonals at `lineWidth` (the Preview placeholder).
    private func addImageBox(_ item: ImageItem, transform: AffineTransform, color: Color, lineWidth: Double?, state: State, into result: inout [PaintOperation]) {
        var box = lineWidth == nil ? DisplayPath(rect: item.rect) : DisplayPath()
        box.move(to: Point(x: item.rect.minX, y: item.rect.minY))
        box.addLine(to: Point(x: item.rect.maxX, y: item.rect.maxY))
        box.move(to: Point(x: item.rect.maxX, y: item.rect.minY))
        box.addLine(to: Point(x: item.rect.minX, y: item.rect.maxY))
        addStroke(box, style: StrokeStyle(width: lineWidth ?? 0), transform: transform, color: color, state: state, into: &result)
    }

    private func append(_ flat: FlatPath, rule: FillRule, color: Color, blend: PaintBlend, state: State, into result: inout [PaintOperation]) {
        let path = flat.clipped(to: clipBounds)
        guard let bounds = path.bounds, bounds.intersects(surface) else {
            return
        }
        let alpha = color.alpha * state.alpha
        let premultiplied = SIMD4<Float>(Float(color.red * alpha), Float(color.green * alpha), Float(color.blue * alpha), Float(alpha))
        result.append(.fill(PaintFill(path: path, rule: rule, color: premultiplied, blend: blend)))
    }
}
