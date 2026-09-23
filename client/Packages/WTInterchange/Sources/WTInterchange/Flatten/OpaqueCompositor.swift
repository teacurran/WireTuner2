// Transparency for targets that have none (export-vector.adoc, "How effects and transparency
// export": EPS, PDF/X-1a).  Walking the flattened scene back to front, every translucent element
// is replaced by opaque output:
//
// * A translucent solid fill over nothing but opaque solid fills is *planarized*: the planar map
//   of the fill and the fills beneath it (GEO-002's Divide) is cut into pieces, and every piece
//   the fill covers is written opaque in the colour the fill composites to over the topmost
//   colour beneath it (or the page).  Text and everything else it does not overlap stays as it is.
// * Anything else translucent -- a stroke, text, a gradient with alpha, an image with alpha, a
//   group with opacity or a soft mask, a fill over an image or text -- is rendered together with
//   everything beneath it over its bounds, and the opaque image is placed clipped to its outline.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

struct OpaqueCompositor {
    let page: ExportPage
    let rasterResolution: Double
    /// Areas cut into opaque pieces.
    private(set) var planarized = 0
    /// Regions rendered, one line each.
    private(set) var rasterized: [String] = []
    /// Opaque solid fills already written outside any clip, pasteboard geometry.
    private var backdrop: [(shape: FilledPath, color: Color, bounds: Rect)] = []
    /// The bounds of everything else already written.
    private var complex: [Rect] = []

    /// The most fills beneath one translucent fill that are planarized; more are rendered.
    static let planarLimit = 48

    init(page: ExportPage, rasterResolution: Double) {
        self.page = page
        self.rasterResolution = rasterResolution
    }

    /// What translucency composites over where nothing is drawn: the page colour, else paper.
    var paper: Color {
        page.background.map { OpaqueCompositor.over($0, .white) } ?? .white
    }

    mutating func composite(_ nodes: [FlatNode]) -> [FlatNode] {
        process(nodes, clipped: false) { $0 }
    }

    /// `nodes` made opaque.  `wrap` rebuilds the original scene around a prefix of `nodes`
    /// (their ancestors with every earlier sibling), which is what lies beneath each node.
    private mutating func process(_ nodes: [FlatNode], clipped: Bool, wrap: @escaping ([FlatNode]) -> [FlatNode]) -> [FlatNode] {
        var output: [FlatNode] = []
        for (index, node) in nodes.enumerated() {
            guard let bounds = node.bounds else {
                continue
            }
            if OpaqueCompositor.isOpaque(node) {
                output.append(node)
                record(node, bounds: bounds, clipped: clipped)
                continue
            }
            if case .group(var group) = node, group.opacity >= 1, group.softMask == nil, group.filter == nil {
                // A plain or clipping group: its children are made opaque in place.
                let earlier = Array(nodes[..<index])
                let template = group
                group.children = process(group.children, clipped: clipped || group.clip != nil) { children in
                    var rebuilt = template
                    rebuilt.children = children
                    return wrap(earlier + [.group(rebuilt)])
                }
                output.append(.group(group))
                continue
            }
            if !clipped, let fill = OpaqueCompositor.translucentFill(node), let pieces = planarize(fill) {
                output += pieces
                planarized += 1
                continue
            }
            output.append(render(node, bounds: bounds, beneath: wrap(Array(nodes[...index]))))
        }
        return output
    }

    /// Remembers what an opaque node leaves beneath later nodes.
    private mutating func record(_ node: FlatNode, bounds: Rect, clipped: Bool) {
        if !clipped, case .path(let path) = node, case .fill(let rule) = path.style, case .color(let color) = path.paint {
            let shape = FilledPath(contours: path.path.applying(path.transform).contours, fillRule: rule)
            backdrop.append((shape, color, bounds))
        } else {
            complex.append(bounds)
        }
    }

    // MARK: Planarizing

    /// A translucent solid fill: its pasteboard shape and straight colour.
    static func translucentFill(_ node: FlatNode) -> (shape: FilledPath, color: Color, bounds: Rect)? {
        var opacity = 1.0
        var current = node
        // A translucent group holding a single fill is that fill at the group's opacity.
        while case .group(let group) = current, group.clip == nil, group.softMask == nil, group.filter == nil, group.children.count == 1 {
            opacity *= group.opacity
            current = group.children[0]
        }
        guard case .path(let path) = current, !path.overprint, case .fill(let rule) = path.style, case .color(let color) = path.paint,
              let bounds = current.bounds
        else {
            return nil
        }
        let shape = FilledPath(contours: path.path.applying(path.transform).contours, fillRule: rule)
        return (shape, color.withAlpha(multipliedBy: opacity), bounds)
    }

    /// The opaque pieces of `fill`, or nil when what lies beneath is not all solid fills.
    private mutating func planarize(_ fill: (shape: FilledPath, color: Color, bounds: Rect)) -> [FlatNode]? {
        guard !complex.contains(where: { $0.intersects(fill.bounds) }) else {
            return nil
        }
        let beneath = backdrop.filter { $0.bounds.intersects(fill.bounds) }
        guard beneath.count <= OpaqueCompositor.planarLimit else {
            return nil
        }
        var result: [FlatNode] = []
        var added: [(shape: FilledPath, color: Color, bounds: Rect)] = []
        let pieces = beneath.isEmpty ? [DividedPiece(path: fill.shape, operands: [0])] : Boolean.divide(beneath.map(\.shape) + [fill.shape])
        let own = beneath.count
        for piece in pieces where piece.operands.contains(own) {
            let under = piece.operands.filter { $0 < own }.max().map { beneath[$0].color } ?? paper
            let color = OpaqueCompositor.over(fill.color, under)
            let path = DisplayPath(contours: piece.path.contours)
            result.append(.path(FlatPath(path: path, paint: .color(color), style: .fill(piece.path.fillRule))))
            added.append((piece.path, color, piece.path.bounds))
        }
        backdrop += added
        return result
    }

    /// `top` composited source-over onto opaque `bottom`, in sRGB (the document blending space
    /// until the CMS epic supplies another): both as their sRGB fallbacks.
    static func over(_ top: Color, _ bottom: Color) -> Color {
        let a = min(max(top.alpha, 0), 1)
        let top = ColorMath.sRGBFallback(top), bottom = ColorMath.sRGBFallback(bottom)
        return Color(
            red: top.red * a + bottom.red * (1 - a),
            green: top.green * a + bottom.green * (1 - a),
            blue: top.blue * a + bottom.blue * (1 - a)
        )
    }

    // MARK: Rendering

    /// `node` and everything beneath it (`beneath`, the original scene up to and including it)
    /// rendered opaque over its bounds and placed clipped to its outline.
    private mutating func render(_ node: FlatNode, bounds: Rect, beneath: [FlatNode]) -> FlatNode {
        let region = bounds.intersection(page.bounds.expanded(by: 1))
        complex.append(region)
        guard !region.isEmpty else {
            return .group(FlatGroup(children: []))
        }
        let scale = min(max(rasterResolution, 1) / 72, Double(RegionRasterizer.maximumEdge) / max(region.width, region.height))
        let left = (region.minX * scale).rounded(.down) / scale
        let top = (region.minY * scale).rounded(.down) / scale
        let pixels = Rect(x: left, y: top, width: ((region.maxX - left) * scale).rounded(.up) / scale, height: ((region.maxY - top) * scale).rounded(.up) / scale)
        // A region of at least one pixel always renders.
        let image = FlatRenderer().render(beneath, region: pixels, scale: scale, background: paper)!
        rasterized.append("transparency rendered at \(Numbers.format(rasterResolution, places: 0)) ppi")
        var clip = FlatClip(path: DisplayPath(rect: pixels))
        if case .path(let path) = node, case .fill(let rule) = path.style {
            clip = FlatClip(path: path.path, rule: rule, transform: path.transform)
        }
        return .group(FlatGroup(children: [.image(FlatImage(image: image, rect: pixels, rasterized: true))], clip: clip))
    }

    // MARK: Opacity

    /// Whether `node` paints only opaque colour.
    static func isOpaque(_ node: FlatNode) -> Bool {
        switch node {
        case .path(let path):
            switch path.paint {
            case .color(let color): return color.alpha >= 1
            case .gradient(let gradient): return !gradient.hasAlpha
            }
        case .text(let text):
            return text.color.alpha >= 1
        case .image(let image):
            return !ImageEncoding.hasAlpha(image.image) || RGBAPixels(image.image).isOpaque
        case .group(let group):
            return group.opacity >= 1 && group.softMask == nil && group.filter == nil && group.children.allSatisfy(isOpaque)
        }
    }
}
