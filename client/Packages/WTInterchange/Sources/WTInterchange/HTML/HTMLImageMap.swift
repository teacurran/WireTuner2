// Image maps for pages published as PNG (web/publish-html.adoc, "Client"; web/urls.adoc "How links
// survive export"; WEB-008): a `<map>` whose `<area shape="poly">` polygons follow each linked
// object's flattened outline (curves subdivided to within a quarter pixel at the page's scale),
// `shape="rect"` per line of a text-range link, each with `alt` from the link's alt text (or the
// object's own when the link has none), listed in the page's reading order.

import Foundation
import WTGeometry
import WTRender

/// One clickable region of a PNG page.
public struct HTMLImageMapArea: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        /// A polygon in CSS pixels of the published image (its displayed size).
        case polygon([Point])
        case rect(Rect)
    }

    public var shape: Shape
    public var href: String
    public var alt: String
    public var newTab: Bool
    /// The object the region belongs to (for the warnings list).
    public var node: NodeID?

    /// The `<area>` element.
    public var html: String {
        let coordinates: String
        let name: String
        switch shape {
        case .polygon(let points):
            name = "poly"
            coordinates = points.map { "\(HTMLText.number($0.x)),\(HTMLText.number($0.y))" }.joined(separator: ",")
        case .rect(let rect):
            name = "rect"
            coordinates = [rect.minX, rect.minY, rect.maxX, rect.maxY].map(HTMLText.number).joined(separator: ",")
        }
        var attributes = "shape=\"\(name)\" coords=\"\(coordinates)\" href=\"\(HTMLText.escape(href))\" alt=\"\(HTMLText.escape(alt))\""
        if newTab { attributes += " target=\"_blank\"" }
        return "<area \(attributes)>"
    }
}

/// Builds the image map of one flattened page.
public enum HTMLImageMap {
    /// The areas of `page` (flattened from `scene`), in reading order (the order objects are
    /// drawn), in CSS pixels relative to the page's top-left.  `pageHrefs` resolves page links.
    public static func areas(_ page: FlatPage, scene: ExportScene, pageHrefs: [Int: String]) -> [HTMLImageMapArea] {
        var result: [HTMLImageMapArea] = []
        let origin = AffineTransform.translation(x: -page.bounds.minX, y: -page.bounds.minY)
        func href(_ info: ExportNodeInfo) -> String? {
            if let number = info.pageLink, let target = pageHrefs[number] { return target }
            return info.url.flatMap(WebLinks.href)
        }
        func visit(_ node: FlatNode) {
            if let id = node.node, let info = scene.info(for: id), let target = href(info) {
                let alt = info.linkAlt ?? info.alt ?? ""
                let newTab = info.linkTarget == .newTab && info.pageLink.flatMap { pageHrefs[$0] } == nil
                let polygons = self.polygons(node, origin: origin)
                if polygons.isEmpty, let bounds = node.bounds?.applying(origin) {
                    result.append(HTMLImageMapArea(shape: .rect(bounds), href: target, alt: alt, newTab: newTab, node: id))
                }
                for polygon in polygons {
                    result.append(HTMLImageMapArea(shape: .polygon(polygon), href: target, alt: alt, newTab: newTab, node: id))
                }
                return
            }
            if case .group(let group) = node { group.children.forEach(visit) }
        }
        page.nodes.forEach(visit)
        for node in scene.textLinks.keys.sorted() {
            for link in scene.textLinks[node]! {
                guard let target = WebLinks.href(link.url) else { continue }
                for rect in link.rects {
                    guard let clipped = rect.intersection(page.bounds).nonEmpty else { continue }
                    result.append(HTMLImageMapArea(shape: .rect(clipped.applying(origin)), href: target, alt: link.alt ?? "", newTab: false, node: node))
                }
            }
        }
        return result
    }

    /// The nodes under `nodes` whose every path is a stroke (their map regions follow the stroke
    /// only), for the warnings list.
    public static func strokeOnly(_ nodes: [FlatNode]) -> Set<NodeID> {
        var result: Set<NodeID> = []
        func paths(_ node: FlatNode) -> [FlatPath] {
            switch node {
            case .path(let path): return [path]
            case .group(let group): return group.children.flatMap(paths)
            default: return []
            }
        }
        func visit(_ node: FlatNode) {
            if let id = node.node {
                let all = paths(node)
                if !all.isEmpty, all.allSatisfy({ if case .stroke = $0.style { true } else { false } }) { result.insert(id) }
            }
            if case .group(let group) = node { group.children.forEach(visit) }
        }
        nodes.forEach(visit)
        return result
    }

    /// The closed polygons of `node`'s paths through `origin`, curves subdivided to 0.25 units.
    static func polygons(_ node: FlatNode, origin: AffineTransform) -> [[Point]] {
        switch node {
        case .path(let path):
            return polygons(path.path, transform: path.transform.concatenating(origin))
        case .group(let group):
            return group.children.flatMap { polygons($0, origin: origin) }
        default:
            return []
        }
    }

    /// The contours of `path` as polygons (at least three points each).
    public static func polygons(_ path: DisplayPath, transform: AffineTransform, tolerance: Double = 0.25) -> [[Point]] {
        var result: [[Point]] = []
        var current: [Point] = []
        var last = Point(x: 0, y: 0)
        func finish() {
            if current.count >= 3 { result.append(current) }
            current = []
        }
        func add(_ point: Point) {
            let placed = transform.apply(point)
            if current.last != placed { current.append(placed) }
        }
        func steps(_ points: [Point]) -> Int {
            let placed = points.map(transform.apply)
            var length = 0.0
            for index in 1..<placed.count { length += hypot(placed[index].x - placed[index - 1].x, placed[index].y - placed[index - 1].y) }
            return min(max(Int((length / max(tolerance, 0.01)).squareRoot().rounded(.up)), 1), 64)
        }
        for element in path.elements {
            switch element {
            case .move(let point):
                finish()
                add(point)
                last = point
            case .line(let point):
                add(point)
                last = point
            case .quadCurve(let control, let end):
                let n = steps([last, control, end])
                for step in 1...n {
                    let t = Double(step) / Double(n), u = 1 - t
                    add(Point(x: u * u * last.x + 2 * u * t * control.x + t * t * end.x, y: u * u * last.y + 2 * u * t * control.y + t * t * end.y))
                }
                last = end
            case .cubicCurve(let c1, let c2, let end):
                let n = steps([last, c1, c2, end])
                for step in 1...n {
                    let t = Double(step) / Double(n), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    add(Point(x: a * last.x + b * c1.x + c * c2.x + d * end.x, y: a * last.y + b * c1.y + c * c2.y + d * end.y))
                }
                last = end
            case .close:
                finish()
            }
        }
        finish()
        return result
    }
}

/// Escaping and number formatting for the HTML the publisher writes.
enum HTMLText {
    static func escape(_ text: String) -> String {
        XMLStream.escape(text, attribute: true)
    }

    static func number(_ value: Double) -> String {
        Numbers.format(value, places: 2)
    }
}
