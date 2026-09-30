// An imported scene as WTRender draws it: the display list the document would build once
// `WTModel` has created the nodes.  The import sheet's preview of a converted file, the
// round-trip tests (export, import, render both, compare) and IMG-009's "renders within tolerance
// of the PDF" all draw through this, so the renderer that proves an import is the one that shows it.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle

extension ImportedContour {
    /// The contour as display-path elements.
    public var displayElements: [DisplayPath.Element] {
        var elements: [DisplayPath.Element] = [.move(to: start)]
        for segment in segments {
            switch segment {
            case .line(let end):
                elements.append(.line(to: end))
            case .cubic(let c1, let c2, let end):
                elements.append(.cubicCurve(control1: c1, control2: c2, end: end))
            }
        }
        if closed {
            elements.append(.close)
        }
        return elements
    }
}

extension ImportedPath {
    /// The contours as one display path in the path's own space.
    public var displayPath: DisplayPath {
        DisplayPath(elements: contours.flatMap(\.displayElements))
    }
}

extension ImportedPaint {
    /// The display-list paint.
    public var paint: Paint {
        switch self {
        case .none: return .none
        case .solid(let color): return .solid(color)
        case .gradient(let gradient): return .gradient(gradient)
        case .swatch(let swatch): return .solid(swatch.color)
        case .pattern(let pattern): return .pattern(pattern)
        case .lens(let lens): return .lens(lens)
        case .tiled(let tile):
            return .tiled(TiledFill(tile: tile.nodes.flatMap { ImportedScene.displayItems($0, .identity) }, angle: tile.angle, scaleX: tile.scaleX,
                                    scaleY: tile.scaleY, offset: tile.offset))
        }
    }
}

extension ImportedNode {
    /// The node's control-point bounds under `transform` (its parent's space to the result's):
    /// path and clip geometry, image and placed-file rectangles, text baselines' origins and a
    /// text path.  Null for nothing.
    public func controlBounds(_ transform: AffineTransform = .identity) -> Rect {
        func points(_ contours: [ImportedContour], _ t: AffineTransform) -> Rect {
            Rect(boundingPoints: contours.flatMap(\.allPoints).map(t.apply))
        }
        switch self {
        case .path(let path):
            return points(path.contours, path.transform.concatenating(transform))
        case .group(let group):
            let total = group.transform.concatenating(transform)
            let children = group.children.reduce(Rect.null) { $0.union($1.controlBounds(total)) }
            return group.clip.map { children.union(points($0.contours, $0.transform.concatenating(total))) } ?? children
        case .text(let text):
            let total = text.transform.concatenating(transform)
            var rect = Rect(boundingPoints: text.runs.map { total.apply($0.origin) })
            if let frame = text.frame { rect = rect.union(Rect(x: 0, y: 0, width: frame.width, height: frame.height).applying(total)) }
            if let path = text.path { rect = rect.union(points(path.contours, path.transform.concatenating(total))) }
            return rect
        case .image(let image):
            return image.naturalRect.applying(image.transform.concatenating(transform))
        case .placed(let placed):
            return placed.bounds.applying(placed.transform.concatenating(transform))
        }
    }
}

/// A path of an imported scene with every enclosing transform applied, for geometry comparisons.
public struct ImportedScenePath: Hashable, Sendable {
    public var contours: [ImportedContour]
    public var fill: ImportedPaint
    public var fillRule: FillRule
    public var stroke: ImportedStroke?
    /// The product of the path's and its groups' opacities.
    public var opacity: Double
    public var name: String?
    public var url: String?
    /// The names of the enclosing groups, outermost first.
    public var groupNames: [String]
}

extension ImportedScene {
    /// Every path in scene space, back to front: transforms applied, opacities multiplied.
    /// Clips and text are not included.
    public var scenePaths: [ImportedScenePath] {
        var result: [ImportedScenePath] = []
        func visit(_ node: ImportedNode, _ transform: AffineTransform, _ opacity: Double, _ names: [String]) {
            switch node {
            case .path(let path):
                let total = path.transform.concatenating(transform)
                result.append(ImportedScenePath(contours: path.contours.map { $0.applying(total) }, fill: path.fill, fillRule: path.fillRule, stroke: path.stroke, opacity: opacity * path.opacity, name: path.name, url: path.url, groupNames: names))
            case .group(let group):
                let total = group.transform.concatenating(transform)
                for child in group.children {
                    visit(child, total, opacity * group.opacity, names + [group.name ?? ""])
                }
            case .text, .image, .placed:
                break
            }
        }
        for node in nodes {
            visit(node, .identity, 1, [])
        }
        return result
    }

    /// Every text node's string in order.
    public var texts: [String] {
        nodes.flatMap(\.descendants).compactMap { node -> String? in
            if case .text(let text) = node { return text.string }
            return nil
        }
    }

    /// Every image node, in order.
    public var images: [ImportedImage] {
        nodes.flatMap(\.descendants).compactMap { node -> ImportedImage? in
            if case .image(let image) = node { return image }
            return nil
        }
    }

    /// The scene as one export page (its bounds, its display list) with the images' decoded
    /// pixels as assets, ready for any exporter or rasterizer.
    public func exportScene() -> ExportScene {
        var items: [DisplayItem] = []
        for node in nodes {
            items += ImportedScene.displayItems(node, .identity)
        }
        var assets: [String: ExportAsset] = [:]
        for blob in blobs {
            if let source = CGImageSourceCreateWithData(blob.data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                assets[blob.hex] = ExportAsset(image: image)
            }
        }
        let page = ExportPage(name: name, bounds: bounds, displayList: DisplayList(canvas: "import", items: items))
        return ExportScene(name: name, pages: [page], assets: assets)
    }

    static func displayItems(_ node: ImportedNode, _ parent: AffineTransform) -> [DisplayItem] {
        switch node {
        case .path(let path):
            var appearance: [AppearanceItem] = []
            if !path.fill.isNone {
                appearance.append(.fill(FillPaint(paint: path.fill.paint, rule: path.fillRule)))
            }
            if let stroke = path.stroke, !stroke.paint.isNone {
                appearance.append(.stroke(StrokePaint(paint: stroke.paint.paint, style: stroke.style)))
            }
            let item = DisplayItem.path(PathItem(path: path.displayPath, appearance: Appearance(appearance), transform: path.transform.concatenating(parent)))
            return path.opacity < 1 ? [.group(GroupItem(children: [item], opacity: path.opacity))] : [item]
        case .group(let group):
            let total = group.transform.concatenating(parent)
            var children = group.children.flatMap { displayItems($0, total) }
            let clip = group.clip.map { clip in DisplayPath(elements: clip.contours.map { $0.applying(clip.transform.concatenating(total)) }.flatMap(\.displayElements)) }
            if clip == nil && group.opacity >= 1 {
                return children
            }
            if group.clipAppearance, var path = group.clip {
                // The clip path's fill below the clipped contents and its stroke above them.
                let stroke = path.stroke
                path.stroke = nil
                let below = displayItems(.path(path), total)
                path.stroke = stroke
                path.fill = .none
                let above = stroke == nil ? [] : displayItems(.path(path), total)
                children = [.group(GroupItem(children: children, clip: clip, clipRule: group.clip?.fillRule ?? .nonZero))]
                return [.group(GroupItem(children: below + children + above, opacity: group.opacity))]
            }
            return [.group(GroupItem(children: children, clip: clip, clipRule: group.clip?.fillRule ?? .nonZero, opacity: group.opacity))]
        case .image(let image):
            return [.image(ImageItem(assetID: image.pixels.blob.hex, rect: image.naturalRect, transform: image.transform.concatenating(parent), mode: image.pixels.mode.imageMode, hasAlpha: image.pixels.hasAlpha, name: image.name ?? ""))]
        case .placed(let placed):
            let total = placed.transform.concatenating(parent)
            if let preview = placed.preview {
                // The preview scaled into the bounding box, as the renderer draws a placed EPS.
                return [.image(ImageItem(assetID: preview.blob.hex, rect: placed.bounds, transform: total, mode: preview.mode.imageMode, hasAlpha: preview.hasAlpha, name: placed.name ?? ""))]
            }
            // Without a preview: a gray box of the bounding box's size with the file's name.
            let box = DisplayItem.path(PathItem(path: DisplayPath(rect: placed.bounds), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(white: 0.85)))), .stroke(StrokePaint(paint: .solid(Color(white: 0.5)), style: StrokeStyle(width: 1)))]), transform: total))
            let label = ImportedTextRun(text: placed.name ?? "", fontName: "Helvetica", fontSize: 10, fill: .solid(Color(white: 0.3)), origin: Point(x: placed.bounds.minX + 4, y: placed.bounds.minY + 14))
            let name = ImportedScene.glyphRun(label).map { DisplayItem.text(TextRunItem(text: label.text, glyphRun: $0, origin: label.origin, color: Color(white: 0.3), transform: total)) }
            return [.group(GroupItem(children: [box] + (name.map { [$0] } ?? [])))]
        case .text(let text):
            let total = text.transform.concatenating(parent)
            return text.runs.compactMap { run -> DisplayItem? in
                guard let glyphs = ImportedScene.glyphRun(run) else {
                    return nil
                }
                return .text(TextRunItem(text: run.text, glyphRun: glyphs, origin: run.origin, color: run.fill.representativeColor ?? .black, transform: total))
            }
        }
    }

    /// `run` laid out left to right with Core Text in its font (or the system's substitute).
    static func glyphRun(_ run: ImportedTextRun) -> GlyphRun? {
        let characters = Array(run.text.utf16)
        guard !characters.isEmpty, run.fontSize > 0 else {
            return nil
        }
        let glyphFont = GlyphFont(postScriptName: run.fontName, size: run.fontSize)
        let font = glyphFont.ctFont
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        var x = run.origin.x
        var positioned: [PositionedGlyph] = []
        for (glyph, advance) in zip(glyphs, advances) {
            positioned.append(PositionedGlyph(glyph: glyph, position: Point(x: x, y: run.origin.y)))
            x += Double(advance.width)
        }
        return GlyphRun(font: glyphFont, glyphs: positioned)
    }
}
