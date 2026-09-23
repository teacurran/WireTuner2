// Layer rendering and hit rules (LIB-005; docs/_includes/library/layers.adoc, "Rendering").
// WTModel's `LayerOrder` gives the layers bottom first with their flags; the display list is
// built layer by layer in that order and keeps, beside its items, which run of items each
// layer holds.  The renderers draw a run by its layer's rules -- background layers dimmed to
// 50% as one group, keyline layers (and the Guides layer, in the guide colour) as outlines
// whatever the view mode, keyline hairlines in the layer highlight -- and hit testing skips
// locked layers and guides, and every layer but the active one under *Edit current layer
// only*.  Hidden layers contribute nothing; for print and export background layers and the
// Guides layer are left out, hidden layers only with *Include hidden layers*.

import WTGeometry

/// How one layer draws and hits (`LayerProps`, resolved).
public struct LayerRendering: Hashable, Sendable {
    public var id: NodeID
    /// Objects cannot be selected from the canvas.
    public var locked: Bool
    /// Above the separator line; false is a background layer: dimmed, never printed.
    public var printing: Bool
    /// Drawn as outlines whatever the document view mode (screen only).
    public var keyline: Bool
    /// The layer highlight: Keyline hairlines and selection overlays.
    public var highlight: Color
    /// The Guides layer: its objects are guides.
    public var isGuides: Bool

    public init(id: NodeID, locked: Bool = false, printing: Bool = true, keyline: Bool = false, highlight: Color = .black, isGuides: Bool = false) {
        self.id = id
        self.locked = locked
        self.printing = printing
        self.keyline = keyline
        self.highlight = highlight
        self.isGuides = isGuides
    }

    /// The opacity the layer composites at: 50% for a background layer.
    public var opacity: Double { printing || isGuides ? 1 : 0.5 }

    /// Whether the layer draws as outlines in every mode (keyline layers and guides).
    public var forcesKeyline: Bool { keyline || isGuides }

    /// Whether canvas hit testing may return objects on the layer.
    public var isHittable: Bool { !locked && !isGuides }
}

/// A run of top-level items on one layer.
public struct LayerSpan: Hashable, Sendable {
    public var layer: LayerRendering
    public var range: Range<Int>

    public init(layer: LayerRendering, range: Range<Int>) {
        self.layer = layer
        self.range = range
    }

    /// `spans` in item order, clamped to `count` items, empty and overlapping runs dropped.
    static func normalized(_ spans: [LayerSpan], count: Int) -> [LayerSpan] {
        var result: [LayerSpan] = []
        var end = 0
        for span in spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let lower = max(span.range.lowerBound, end)
            let upper = min(span.range.upperBound, count)
            guard lower < upper else {
                continue
            }
            result.append(LayerSpan(layer: span.layer, range: lower..<upper))
            end = upper
        }
        return result
    }
}

/// One layer's content for `LayerScene`.
public struct LayerContent: Sendable {
    public var layer: LayerRendering
    public var visible: Bool
    /// The layer's objects bottom first, each with the node it was built from.
    public var items: [(item: DisplayItem, node: NodeID?)]

    public init(layer: LayerRendering, visible: Bool = true, items: [(item: DisplayItem, node: NodeID?)]) {
        self.layer = layer
        self.visible = visible
        self.items = items
    }
}

/// Builds a canvas's display list from its layers in `LayerOrder`.
public enum LayerScene {
    /// What the list is for.
    public enum Purpose: Hashable, Sendable {
        /// The canvas: every visible layer, background layers dimmed, keyline and guides
        /// flags applied.
        case screen(guideColor: Color)
        /// Print and export: printing, non-Guides layers only; hidden ones only when
        /// `includeHidden`.  No dimming or keyline.
        case output(includeHidden: Bool)
    }

    /// The list of `layers` (bottom first) for `purpose`, with `background` items (page
    /// furniture) beneath every layer.
    public static func build(canvas: CanvasID, layers: [LayerContent], purpose: Purpose, background: [DisplayItem] = []) -> DisplayList {
        var items = background
        var nodes: [NodeID?] = Array(repeating: nil, count: background.count)
        var spans: [LayerSpan] = []
        for content in layers {
            var rendering = content.layer
            switch purpose {
            case .screen(let guideColor):
                guard content.visible else { continue }
                if rendering.isGuides {
                    rendering.highlight = rendering.keyline ? .black : guideColor
                }
            case .output(let includeHidden):
                guard content.visible || includeHidden, rendering.printing, !rendering.isGuides else { continue }
                rendering.keyline = false
            }
            let start = items.count
            for entry in content.items {
                items.append(entry.item)
                nodes.append(entry.node)
            }
            spans.append(LayerSpan(layer: rendering, range: start..<items.count))
        }
        return DisplayList(canvas: canvas, items: items, nodeIDs: nodes.contains { $0 != nil } ? nodes : [], layers: spans)
    }
}

extension DisplayList {
    /// The span holding top-level item `index`, if any.
    public func layerSpan(containing index: Int) -> LayerSpan? {
        var low = 0, high = layers.count
        while low < high {
            let middle = (low + high) / 2
            let span = layers[middle]
            if index < span.range.lowerBound {
                high = middle
            } else if index >= span.range.upperBound {
                low = middle + 1
            } else {
                return span
            }
        }
        return nil
    }

    /// The span of layer `layer`, if the list has one.
    public func layerSpan(of layer: NodeID) -> LayerSpan? {
        layers.first { $0.layer.id == layer }
    }

    /// Everything layer `layer`'s items paint (REND-004: toggling a layer flag repaints only
    /// that layer).
    public func bounds(ofLayer layer: NodeID) -> Rect? {
        guard let span = layerSpan(of: layer) else {
            return nil
        }
        return DisplayList.union(of: itemBounds[span.range].compactMap { $0 })
    }

    /// `indices` (ascending) grouped into consecutive runs sharing one span (nil outside every
    /// span), in order.
    func layerRuns(_ indices: [Int]) -> [(span: LayerSpan?, indices: [Int])] {
        guard !layers.isEmpty else {
            return indices.isEmpty ? [] : [(nil, indices)]
        }
        var runs: [(span: LayerSpan?, indices: [Int])] = []
        for index in indices {
            let span = layerSpan(containing: index)
            if let last = runs.last, last.span == span {
                runs[runs.count - 1].indices.append(index)
            } else {
                runs.append((span, [index]))
            }
        }
        return runs
    }

    /// The list showing only the items on `layers` (and items on no layer): an animation frame
    /// or any other partial view (WEB-016), sharing items and their bounds with this list.
    public func restricted(toLayers layers: Set<NodeID>) -> DisplayList {
        var keep: [Int] = []
        var spans: [LayerSpan] = []
        for index in items.indices {
            let span = layerSpan(containing: index)
            guard span.map({ layers.contains($0.layer.id) }) ?? true else {
                continue
            }
            if let span {
                if let last = spans.last, last.layer == span.layer, last.range.upperBound == keep.count {
                    spans[spans.count - 1].range = last.range.lowerBound..<(keep.count + 1)
                } else {
                    spans.append(LayerSpan(layer: span.layer, range: keep.count..<(keep.count + 1)))
                }
            }
            keep.append(index)
        }
        return DisplayList(
            canvas: canvas,
            items: keep.map { items[$0] },
            itemBounds: keep.map { itemBounds[$0] },
            nodeIDs: nodeIDs.isEmpty ? [] : keep.map { nodeIDs[$0] },
            layers: spans
        )
    }
}
