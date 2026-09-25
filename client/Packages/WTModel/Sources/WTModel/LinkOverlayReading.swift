import WTCRDT
import WTGeometry
import WTInterchange
import WTRender

/// The marks of menu:View[Show Links] (WEB-004, urls.adoc "Client"): every object on the canvas
/// whose `url` is set, tinted over its painted bounds as the scene draws it, and every line of a
/// linked text range, underlined.  Objects the scene does not draw (hidden layers, locally
/// hidden, other canvases) have no mark.  The window draws the result in its own overlay layer
/// (`LinkOverlay.draw`), so the overlay never touches the display list, print or exports.
public enum LinkOverlayReading {
    /// The overlay of `scene` from `index` (the document's `LinkIndex`) and `textLinks` (the
    /// text-range rectangles, `ExportSnapshot.textLinks`, laid out by the caller on the main
    /// actor).  Marks are in draw order: an object's tint, then its text lines.
    public static func overlay(scene: DocumentScene, index: LinkIndex, textLinks: [NodeID: [ExportTextLink]] = [:]) -> LinkOverlay {
        var entries: [(path: [Int], marks: [LinkMark])] = []
        for (node, object) in scene.objects {
            var marks: [LinkMark] = []
            if let url = index.carriers[OpID(node)]?.url, let bounds = object.bounds {
                marks.append(LinkMark(url: url, node: node, shape: .object(bounds)))
            }
            for link in textLinks[node] ?? [] {
                marks += link.rects.map { LinkMark(url: link.url, node: node, shape: .textLine($0)) }
            }
            if !marks.isEmpty { entries.append((object.itemPath, marks)) }
        }
        entries.sort { $0.path.lexicographicallyPrecedes($1.path) }
        return LinkOverlay(marks: entries.flatMap(\.marks))
    }
}
