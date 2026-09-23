// The DXF exporter (IO-020): one file per page of outlines.  Before flattening, the page's paints
// become plain black and every effect but the vector effects is dropped -- DXF ignores fills,
// colours and raster effects, and what matters is that every outline survives as geometry rather
// than being rendered to an image the format cannot hold.  The flattener then expands vector
// effects, blends, brushes and (with *Outline strokes*) strokes to paths, and outlines all text.

import Foundation
import WTGeometry
import WTRender

public struct DXFExporter: Exporter {
    public init() {}

    public var format: ExportFormat { .dxf }
    public var optionsType: any ExportOptions.Type { DXFOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.dxf.capabilities }

    /// The flattener DXF output goes through: no compositing (translucency is irrelevant to an
    /// outline), strokes kept as centerlines unless outlined, text always outlined.
    public static func flattener(options: DXFOptions) -> Flattener {
        var target: FlattenTarget = [.transparency, .softMasks, .gradients, .filters]
        if !options.outlineStrokes {
            target.insert(.strokes)
        }
        return Flattener(target: target, rasterResolution: 72, outlineText: true)
    }

    /// Page `index` of `scene` as DXF data and notes.
    public func data(scene: ExportScene, page index: Int, options: DXFOptions) throws -> (data: Data, notes: [String]) {
        try options.validate()
        guard scene.pages.indices.contains(index) else {
            throw ExportError.nothingToExport
        }
        var page = scene.pages[index]
        let dropped = DXFExporter.rasterEffectObjects(page, scene: scene)
        page.displayList = DXFExporter.outlinesOnly(page.displayList)
        let flat = DXFExporter.flattener(options: options).flatten(page, scene: scene)
        let written = DXFWriter(options: options).write(flat.page, scene: scene)
        var notes = flat.report.notes.filter { !$0.contains("converted to outlines") } + written.notes
        if !dropped.isEmpty {
            notes.append("raster effects left out (DXF holds no images) on " + dropped.joined(separator: ", "))
        }
        return (written.data, notes)
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: DXFOptions.self)
        try options.validate()
        guard !scene.pages.isEmpty else {
            throw ExportError.nothingToExport
        }
        let urls = try destination.urls(count: scene.pages.count, format: .dxf) { index in
            FileNamePattern.Values(name: scene.name, page: index + 1, pageName: scene.pages[index].name)
        }
        var summary = ExportSummary()
        for (index, url) in urls.enumerated() {
            let written = try data(scene: scene, page: index, options: options)
            do {
                try written.data.write(to: url)
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
            summary.files.append(url)
            summary.notes += written.notes
        }
        return summary
    }

    // MARK: Preparation

    /// The objects of `page` whose visible raster effects DXF leaves out (FX-012), by name;
    /// unnamed ones are counted.
    static func rasterEffectObjects(_ page: ExportPage, scene: ExportScene) -> [String] {
        var named: [String] = []
        var unnamed = 0
        func visit(_ item: DisplayItem, at path: [Int]) {
            let appearance: Appearance?
            switch item {
            case .path(let path): appearance = path.appearance
            case .group(let group): appearance = group.appearance
            default: appearance = nil
            }
            if let appearance, appearance.effects.contains(where: { !$0.hidden && !$0.effect.isVector && $0.effect != .unsupported && !FlattenRun.isNoOp($0.effect) }) {
                if let name = scene.info(for: page.nodeID(at: path))?.name, !name.isEmpty {
                    named.append("\u{201C}\(name)\u{201D}")
                } else {
                    unnamed += 1
                }
            }
            if case .group(let group) = item {
                for (index, child) in group.children.enumerated() {
                    visit(child, at: path + [index])
                }
            }
        }
        for (index, item) in page.displayList.items.enumerated() {
            visit(item, at: [index])
        }
        if unnamed > 0 {
            named.append("\(unnamed) unnamed object\(unnamed == 1 ? "" : "s")")
        }
        return named
    }

    /// `list` with every paint that paints made solid black and only vector effects kept.
    static func outlinesOnly(_ list: DisplayList) -> DisplayList {
        DisplayList(canvas: list.canvas, items: list.items.map(outlinesOnly), nodeIDs: list.nodeIDs)
    }

    static func outlinesOnly(_ item: DisplayItem) -> DisplayItem {
        switch item {
        case .fill(var fill):
            fill.paint = solid(fill.paint)
            return .fill(fill)
        case .stroke(var stroke):
            stroke.paint = solid(stroke.paint)
            return .stroke(stroke)
        case .path(var path):
            path.appearance = outlinesOnly(path.appearance)
            return .path(path)
        case .group(var group):
            group.appearance = outlinesOnly(group.appearance)
            group.opacity = 1
            group.children = group.children.map(outlinesOnly)
            return .group(group)
        case .image, .text:
            return item
        }
    }

    static func outlinesOnly(_ appearance: Appearance) -> Appearance {
        var result = appearance
        result.items = appearance.items.map { element in
            switch element {
            case .fill(var fill):
                fill.paint = solid(fill.paint)
                return .fill(fill)
            case .stroke(var stroke):
                stroke.paint = solid(stroke.paint)
                return .stroke(stroke)
            }
        }
        result.effects = appearance.effects.filter { $0.effect.isVector }
        return result
    }

    static func solid(_ paint: Paint) -> Paint {
        paint.isNone ? .none : .solid(.black)
    }
}
