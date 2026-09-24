import Foundation
import WTCRDT
import WTGeometry
import WTModel

/// One axis of the Align panel (arranging.adoc, "Aligning and distributing"; OBJ-019): leave
/// it, line up an edge or the centres, space edges or centres evenly between the outermost two,
/// or make the gaps equal.  The horizontal axis reads "left/right", the vertical "top/bottom".
enum AlignOption: String, CaseIterable, Identifiable, Sendable {
    case none
    case minEdge, center, maxEdge
    case distributeMin, distributeCenter, distributeMax, distributeGaps

    var id: String { rawValue }

    var isDistribution: Bool {
        switch self {
        case .distributeMin, .distributeCenter, .distributeMax, .distributeGaps: true
        default: false
        }
    }

    func title(horizontal: Bool) -> String {
        switch self {
        case .none: "No change"
        case .minEdge: horizontal ? "Align left" : "Align top"
        case .center: "Align center"
        case .maxEdge: horizontal ? "Align right" : "Align bottom"
        case .distributeMin: horizontal ? "Distribute left edges" : "Distribute tops"
        case .distributeCenter: "Distribute centers"
        case .distributeMax: horizontal ? "Distribute right edges" : "Distribute bottoms"
        case .distributeGaps: horizontal ? "Distribute widths" : "Distribute heights"
        }
    }
}

/// The Align panel's settings, remembered between uses (the last ones repeat on btn:[Apply]).
struct AlignSettings: Equatable, Sendable {
    var horizontal = AlignOption.none
    var vertical = AlignOption.none
    var toPage = false

    static let horizontalKey = "align.horizontal"
    static let verticalKey = "align.vertical"
    static let toPageKey = "align.toPage"

    init(horizontal: AlignOption = .none, vertical: AlignOption = .none, toPage: Bool = false) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.toPage = toPage
    }

    init(defaults: UserDefaults) {
        horizontal = defaults.string(forKey: Self.horizontalKey).flatMap(AlignOption.init(rawValue:)) ?? .none
        vertical = defaults.string(forKey: Self.verticalKey).flatMap(AlignOption.init(rawValue:)) ?? .none
        toPage = defaults.bool(forKey: Self.toPageKey)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(horizontal.rawValue, forKey: Self.horizontalKey)
        defaults.set(vertical.rawValue, forKey: Self.verticalKey)
        defaults.set(toPage, forKey: Self.toPageKey)
    }
}

/// Alignment and distribution as pure arithmetic over boxes (pasteboard space): the offset each
/// box moves by.  Boxes marked `fixed` (locked objects) never move; when there are any, they are
/// what the others align to.
enum AlignLayout {
    struct Item: Equatable, Sendable {
        var box: Rect
        var fixed: Bool

        init(box: Rect, fixed: Bool = false) {
            self.box = box
            self.fixed = fixed
        }
    }

    /// The offset of every item, in order.
    static func offsets(_ items: [Item], settings: AlignSettings, page: Rect?) -> [Vector] {
        let reference = settings.toPage ? page : nil
        let dx = axis(items.map { ($0.box.minX, $0.box.maxX, $0.fixed) }, option: settings.horizontal, reference: reference.map { ($0.minX, $0.maxX) })
        let dy = axis(items.map { ($0.box.minY, $0.box.maxY, $0.fixed) }, option: settings.vertical, reference: reference.map { ($0.minY, $0.maxY) })
        return zip(dx, dy).map { Vector(dx: $0, dy: $1) }
    }

    /// One axis: the spans `(min, max, fixed)` and the page's span when aligning to the page.
    static func axis(_ spans: [(min: Double, max: Double, fixed: Bool)], option: AlignOption, reference: (min: Double, max: Double)?) -> [Double] {
        var result = Array(repeating: 0.0, count: spans.count)
        guard option != .none, !spans.isEmpty else { return result }
        let anchors = spans.filter(\.fixed)
        let target = anchors.isEmpty ? spans : anchors
        let bounds = reference ?? (target.map(\.min).min()!, target.map(\.max).max()!)
        func value(_ span: (min: Double, max: Double, fixed: Bool), _ kind: AlignOption) -> Double {
            switch kind {
            case .minEdge, .distributeMin: span.min
            case .maxEdge, .distributeMax: span.max
            default: (span.min + span.max) / 2
            }
        }
        switch option {
        case .minEdge, .center, .maxEdge:
            let goal = option == .minEdge ? bounds.min : option == .maxEdge ? bounds.max : (bounds.min + bounds.max) / 2
            for (index, span) in spans.enumerated() where !span.fixed { result[index] = goal - value(span, option) }
        case .distributeMin, .distributeCenter, .distributeMax:
            let order = spans.indices.sorted { value(spans[$0], option) < value(spans[$1], option) }
            guard order.count >= 2 || reference != nil else { return result }
            let first = spans[order.first!], last = spans[order.last!]
            let low: Double, high: Double
            if let reference {
                // Across the page: the outermost edges or centres land on the page's.
                switch option {
                case .distributeMin: (low, high) = (reference.min, reference.max - (last.max - last.min))
                case .distributeMax: (low, high) = (reference.min + (first.max - first.min), reference.max)
                default: (low, high) = (reference.min + (first.max - first.min) / 2, reference.max - (last.max - last.min) / 2)
                }
            } else {
                (low, high) = (value(first, option), value(last, option))
            }
            let step = order.count > 1 ? (high - low) / Double(order.count - 1) : 0
            for (rank, index) in order.enumerated() where !spans[index].fixed {
                result[index] = low + step * Double(rank) - value(spans[index], option)
            }
        case .distributeGaps:
            let order = spans.indices.sorted { spans[$0].min < spans[$1].min }
            guard order.count >= 2 || reference != nil else { return result }
            let total = spans.reduce(0) { $0 + ($1.max - $1.min) }
            let low = reference?.min ?? spans[order.first!].min
            let high = reference?.max ?? order.map { spans[$0].max }.max()!
            let gap = order.count > 1 ? (high - low - total) / Double(order.count - 1) : 0
            var cursor = low
            for index in order {
                let span = spans[index]
                if !span.fixed { result[index] = cursor - span.min }
                cursor += (span.max - span.min) + gap
            }
        case .none:
            break
        }
        return result
    }
}

/// What btn:[Apply] aligns in a window: the selected objects (by their geometry bounds, locked
/// ones as anchors), or -- when points are selected -- the points, by position.
@MainActor
struct AlignTarget {
    let document: DocumentHandle
    let selection: Selection

    struct PointItem: Equatable {
        var node: OpID
        var contour: OpID
        var point: OpID
        /// The anchor in pasteboard space.
        var location: Point
    }

    /// The selected points, when any are selected.
    var points: [PointItem] {
        let state = document.state
        return selection.ids.flatMap { id -> [PointItem] in
            guard case .points(let references)? = selection.subSelection(of: id), let object = document.object(for: id), let path = object.path else { return [] }
            let transform = Objects.pasteboardTransform(of: id.opID, in: state)
            return references.sorted().compactMap { reference in
                guard let contour = path.contour(reference.contour), let point = contour.points.first(where: { $0.id == reference.point }) else { return nil }
                return PointItem(node: id.opID, contour: contour.id, point: point.id, location: transform.apply(point.anchor))
            }
        }
    }

    /// btn:[Apply]: one change, "Align N objects" (or "Align N points"); nil when nothing moves.
    func command(_ settings: AlignSettings) -> (any WTModel.Command)? {
        let state = document.state
        let page = document.currentPage
        let points = points
        if !points.isEmpty {
            let offsets = AlignLayout.offsets(points.map { AlignLayout.Item(box: Rect(x: $0.location.x, y: $0.location.y, width: 0, height: 0)) },
                                              settings: settings, page: page)
            var byNode: [OpID: [MovePoints.Move]] = [:]
            var order: [OpID] = []
            for (item, offset) in zip(points, offsets) where offset != .zero {
                guard let inverse = Objects.pasteboardTransform(of: item.node, in: state).inverted() else { continue }
                if byNode[item.node] == nil { order.append(item.node) }
                byNode[item.node, default: []].append(MovePoints.Move(contour: item.contour, point: item.point, anchor: inverse.apply(item.location + offset)))
            }
            guard !order.isEmpty else { return nil }
            let count = byNode.values.reduce(0) { $0 + $1.count }
            return CompositeCommand("Align \(count) \(count == 1 ? "point" : "points")", order.map { MovePoints(node: $0, moves: byNode[$0]!) })
        }
        let nodes = selection.ids.map(\.opID).filter { Objects.bounds(of: $0, in: state) != nil }
        guard !nodes.isEmpty else { return nil }
        let items = nodes.map { AlignLayout.Item(box: Objects.bounds(of: $0, in: state)!, fixed: Objects.isEffectivelyLocked($0, in: state)) }
        let moves = zip(nodes, AlignLayout.offsets(items, settings: settings, page: page)).filter { $0.1 != .zero }.map { MoveObjects([$0.0], by: $0.1) }
        guard !moves.isEmpty else { return nil }
        return CompositeCommand(Objects.label("Align", count: moves.count), moves)
    }
}
