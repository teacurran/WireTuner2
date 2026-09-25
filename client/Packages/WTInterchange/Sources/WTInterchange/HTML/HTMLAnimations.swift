// Placed SVG animations in published HTML (web/svg-animation.adoc, "SVG animations in output" and
// "Client"; WEB-008).  Unless the setting says *Poster only*, each placed animation on a page is
// taken out of the page's picture (its item becomes an empty group, so the poster is not drawn
// and no other item moves) and put back above it: inlined into the page's `<section>` in a
// `<div>` that the node's transform places over its natural size, with its scripts and event
// attributes stripped -- or, when the file has script and *Allow scripts* is on, written to
// `animations/` under its content hash and embedded with `<object>` so the script runs isolated.
// The *On the web* settings become rules in `style.css` on the wrapper's id:
// `animation-play-state` paused without autoplay or until hover, and `animation-iteration-count`
// for *Loop* and *Once* (CSS animations only; SMIL timelines play as the file says).

import Foundation
import WTGeometry
import WTRender

/// What the publisher adds for the animations of one page.
struct HTMLAnimationOverlay {
    /// The page with every placed animation's item emptied.
    var page: ExportPage
    /// The wrappers, in stacking order, for the page's `<section>`.
    var elements: [String] = []
    /// Rules for `style.css`.
    var rules: [String] = []
    /// Files for `animations/`.
    var files: [(String, Data)] = []
    var warnings: [ExportWarning] = []
}

enum HTMLAnimations {
    /// The overlay of `page` (document page `number`) under `settings`; the page unchanged and
    /// nothing added under *Poster only* or when it holds no placed animation.
    static func overlay(_ page: ExportPage, number: Int, scene: ExportScene, settings: HTMLPublishSettings) -> HTMLAnimationOverlay {
        var overlay = HTMLAnimationOverlay(page: page)
        guard !settings.svgAnimationPosterOnly, !scene.svgAnimations.isEmpty else { return overlay }
        var found: [(path: [Int], node: NodeID)] = []
        for (index, node) in page.displayList.nodeIDs.enumerated() {
            if let node, scene.svgAnimations[node] != nil { found.append(([index], node)) }
        }
        for (path, node) in page.nestedNodeIDs where scene.svgAnimations[node] != nil {
            found.append((path, node))
        }
        guard !found.isEmpty else { return overlay }
        found.sort { $0.path.lexicographicallyPrecedes($1.path) }
        var items = page.displayList.items
        for (position, entry) in found.enumerated() {
            items = emptying(items, at: entry.path)
            let animation = scene.svgAnimations[entry.node]!
            let id = "anim-\(number)-\(position + 1)"
            let t = animation.transform
            let style = "width:\(HTMLText.number(animation.width))px;height:\(HTMLText.number(animation.height))px;"
                + "transform:matrix(\([t.a, t.b, t.c, t.d, t.tx - page.bounds.minX, t.ty - page.bounds.minY].map { Numbers.format($0, places: 4) }.joined(separator: ",")))"
            let alt = scene.info(for: entry.node)?.alt ?? ""
            let text = String(decoding: animation.data, as: UTF8.self)
            if animation.script && settings.allowScripts {
                let path = "animations/\(SVGLinkedFiles.name(animation.data)).svg"
                overlay.files.append((path, animation.data))
                overlay.elements.append("<object id=\"\(id)\" class=\"anim\" data=\"\(path)\" type=\"image/svg+xml\" style=\"\(style)\" aria-label=\"\(HTMLText.escape(alt))\"></object>")
            } else {
                if animation.script {
                    overlay.warnings.append(ExportWarning(.scriptAnimation, node: entry.node, page: number,
                                                          "Page \(number): a placed SVG animation depends on script, which was removed."))
                }
                overlay.elements.append("<div id=\"\(id)\" class=\"anim\" style=\"\(style)\" role=\"img\" aria-label=\"\(HTMLText.escape(alt))\">\(inline(text))</div>")
            }
            if !animation.autoplay || animation.playOnHover {
                overlay.rules.append("#\(id) *{animation-play-state:paused}")
            }
            if animation.playOnHover {
                overlay.rules.append("#\(id):hover *{animation-play-state:running}")
            }
            switch animation.loop {
            case .asFile: break
            case .loop: overlay.rules.append("#\(id) *{animation-iteration-count:infinite}")
            case .once: overlay.rules.append("#\(id) *{animation-iteration-count:1}")
            }
        }
        overlay.page.displayList = DisplayList(canvas: page.displayList.canvas, items: items, nodeIDs: page.displayList.nodeIDs, layers: page.displayList.layers)
        return overlay
    }

    /// `items` with the item at `path` replaced by an empty group.
    static func emptying(_ items: [DisplayItem], at path: [Int]) -> [DisplayItem] {
        var items = items
        let index = path[0]
        guard index < items.count else { return items }
        if path.count == 1 {
            items[index] = .group(GroupItem(children: []))
        } else if case .group(var group) = items[index] {
            group.children = emptying(group.children, at: Array(path.dropFirst()))
            items[index] = .group(group)
        }
        return items
    }

    /// The SVG file as markup for an HTML body: the XML declaration, doctype and comments
    /// dropped, `<script>` elements and `on…` event attributes removed.
    static func inline(_ svg: String) -> String {
        var text = svg
        for pattern in [#"<\?xml[^>]*\?>"#, #"<!DOCTYPE[^>]*>"#, #"<!--[\s\S]*?-->"#, #"<script\b[\s\S]*?</script\s*>"#, #"<script\b[^>]*/>"#,
                        #"\s+on[a-zA-Z]+\s*=\s*("[^"]*"|'[^']*')"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
