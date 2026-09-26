// Fonts at print time (PRINT-014; docs/_includes/printing/print-fonts.adoc, "Client").
//
// * *Print text as outlines*: `PrintTextOutlines.outline` turns every glyph run of a sheet's list
//   into a filled path of its glyph outlines (`GlyphRun.outline`) in the run's colour and
//   overprint.  It is the `PrintSheetRenderer.textOutliner` the sheets use unless one is given.
//   WTRender's Core Graphics renderer already fills glyph runs as outlines in every context, the
//   print context included, so a job never embeds a font either way (the deviation is recorded
//   on print-fonts.adoc); the option keeps the list free of text for any renderer that would.
// * The job's font check: `PrintFontCheck` lists the fonts the printed sheets draw text in --
//   only runs inside a sheet's printed region count, so text on the pasteboard or on pages the job
//   does not print is left out, as it is from the job -- and the text nodes those runs belong to.
//   WTApp reads the faces those nodes name through WTText's font manager: the ones that resolved
//   through substitution are the job's missing fonts.  WTInterchange imports nothing above
//   WTRender, so that judgement is the app's.

import CoreGraphics
import CoreText
import Foundation
import WTGeometry
import WTRender

/// *Print text as outlines*.
public enum PrintTextOutlines {
    /// `list` with every glyph run a filled path; everything else as it was.
    public static func outline(_ list: DisplayList) -> DisplayList {
        DisplayList(canvas: list.canvas, items: list.items.map(outline), nodeIDs: list.nodeIDs, layers: list.layers)
    }

    /// `item` with its glyph runs (at any depth) as filled paths.  A run without laid-out glyphs
    /// (a placeholder) stays as it is.
    public static func outline(_ item: DisplayItem) -> DisplayItem {
        switch item {
        case .text(let text):
            guard let run = text.glyphRun else { return item }
            let fill = FillPaint(paint: .solid(text.color), overprint: text.overprint)
            return .path(PathItem(path: run.outline, appearance: Appearance([.fill(fill)]), transform: text.transform))
        case .group(var group):
            group.children = group.children.map(outline)
            return .group(group)
        default:
            return item
        }
    }
}

/// A font the printed sheets draw text in.
public struct PrintFont: Hashable, Comparable, Sendable {
    public var postScriptName: String
    public var family: String
    public var style: String?

    public init(postScriptName: String, family: String, style: String? = nil) {
        self.postScriptName = postScriptName
        self.family = family
        self.style = style
    }

    /// The names of `font`.
    public init(_ font: CTFont) {
        self.init(postScriptName: CTFontCopyPostScriptName(font) as String, family: CTFontCopyFamilyName(font) as String,
                  style: CTFontCopyName(font, kCTFontStyleNameKey) as String?)
    }

    public static func < (lhs: PrintFont, rhs: PrintFont) -> Bool {
        (lhs.family, lhs.postScriptName) < (rhs.family, rhs.postScriptName)
    }
}

/// The fonts and text of a job's printed sheets.
public struct PrintFontCheck: Sendable {
    /// Every font a printed run is drawn in, sorted by family.
    public let fonts: [PrintFont]
    /// The text nodes whose runs are printed: the nearest node of each run.
    public let textNodes: Set<NodeID>

    public init(fonts: [PrintFont], textNodes: Set<NodeID>) {
        self.fonts = fonts
        self.textNodes = textNodes
    }

    /// The check over `plan`: the runs inside each sheet's printed region.
    public init(plan: PrintPlan) {
        var fonts: [String: PrintFont] = [:]
        var nodes: Set<NodeID> = []
        let regions = Dictionary(grouping: plan.sheets, by: \.page).mapValues { $0.map(\.region) }
        for (index, page) in plan.pages.enumerated() {
            let printed = regions[index] ?? []
            for (position, item) in page.displayList.items.enumerated() {
                PrintFontCheck.visit(item, at: [position], node: nil, page: page, printed: printed) { run, node in
                    let font = PrintFont(run.font.ctFont)
                    fonts[font.postScriptName] = fonts[font.postScriptName] ?? font
                    if let node { nodes.insert(node) }
                }
            }
        }
        self.init(fonts: fonts.values.sorted(), textNodes: nodes)
    }

    /// Calls `found` for each glyph run under `item` that meets a printed region, with the nearest
    /// node at or above it.
    static func visit(_ item: DisplayItem, at path: [Int], node: NodeID?, page: ExportPage, printed: [Rect], found: (GlyphRun, NodeID?) -> Void) {
        guard let bounds = item.bounds, printed.contains(where: { $0.intersects(bounds) }) else { return }
        let node = page.nodeID(at: path) ?? node
        switch item {
        case .text(let text):
            if let run = text.glyphRun { found(run, node) }
        case .group(let group):
            for (index, child) in group.children.enumerated() {
                visit(child, at: path + [index], node: node, page: page, printed: printed, found: found)
            }
        default:
            break
        }
    }

    /// The families of `fonts`, sorted, each once.
    public static func families(_ fonts: [PrintFont]) -> [String] {
        Array(Set(fonts.map(\.family))).sorted()
    }
}
