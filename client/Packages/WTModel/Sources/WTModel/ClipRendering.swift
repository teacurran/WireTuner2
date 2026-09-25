import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// How the scene draws a clip group (OBJ-028, clipping-paths.adoc "Client"): the clip path's
/// fills, then the contents clipped to the clip path's outline (`GroupItem.clip`, through the
/// clip path's transform chain), then the clip path's strokes and effects unclipped.  The group's
/// items are always three slots -- `below` (the fills), `contents` (the clipped group) and `above`
/// (the strokes and effects) -- so every item path is known before anything is placed: the
/// contents sit at `[contents, k]` under the group and the clip path at `above` (its fill part at
/// `below` is an alias of it).  A missing part is an empty group, which draws, bounds and hits
/// nothing.
///
/// Read-time rules: a dangling or unusable `clip_path` (`ClipGroups.clipPath(of:)` nil) draws the
/// group as a plain group -- contents unclipped; a clip group with no live contents draws as a
/// plain group too, which is the clip path's own stroke and fill.
public enum ClipRendering {
    /// The group's item slots.
    public static let below = 0
    public static let contents = 1
    public static let above = 2

    /// The clip path `group` draws with, or nil to draw it as a plain group.
    public static func clipPath(of group: OpID, in state: EngineState) -> OpID? {
        guard let clip = ClipGroups.clipPath(of: group, in: state) else { return nil }
        return state.liveChildren(group).contains { $0 != clip } ? clip : nil
    }

    /// The item path a child of clip group `group` (at `itemPath`) is placed at: the clip path at
    /// `above`, the `index`-th content inside `contents`.
    static func itemPath(_ itemPath: [Int], child: OpID, clip: OpID, contentIndex: Int) -> [Int] {
        child == clip ? itemPath + [above] : itemPath + [contents, contentIndex]
    }

    /// The group's three items: the clip path's placed `item` split around the placed contents,
    /// which are clipped to the clip path's outline in pasteboard space.  `clipShape` is the clip
    /// path's geometry (local) and `clipTransform` local → pasteboard.
    static func children(clipItem item: DisplayItem?, contents placed: [DisplayItem], clipShape: VectorPath?,
                         clipTransform: AffineTransform) -> [DisplayItem] {
        let (fills, rest) = item.map(split) ?? (nil, nil)
        var group = GroupItem(children: placed)
        if let clipShape {
            group.clip = DocumentDisplayListBuilder.display(clipShape) { $0.isRenderable && $0.closed }.path
            group.clipRule = clipShape.evenOdd ? .evenOdd : .nonZero
            group.transform = clipTransform
        }
        let empty = DisplayItem.group(GroupItem(children: []))
        return [fills ?? empty, .group(group), rest ?? empty]
    }

    /// The clip path's own item split into what draws below the contents (its fills, with the
    /// effects attached to them) and above them (its strokes, the effects attached to them and
    /// the object-level effects).  An item that is not one path draws wholly above.
    static func split(_ item: DisplayItem) -> (below: DisplayItem?, above: DisplayItem?) {
        guard case .path(let path) = item else { return (nil, item) }
        func part(_ keep: (AppearanceItem) -> Bool, objectEffects: Bool) -> DisplayItem? {
            var remap: [Int: Int] = [:]
            var items: [AppearanceItem] = []
            for (index, element) in path.appearance.items.enumerated() where keep(element) {
                remap[index] = items.count
                items.append(element)
            }
            let effects = path.appearance.effects.compactMap { effect -> EffectElement? in
                switch effect.target {
                case .object:
                    return objectEffects ? effect : nil
                case .element(let index):
                    guard let mapped = remap[index] else { return nil }
                    var moved = effect
                    moved.target = .element(mapped)
                    return moved
                }
            }
            guard !items.isEmpty || !effects.isEmpty else { return nil }
            var copy = path
            copy.appearance = Appearance(items, effects: effects, raster: path.appearance.raster)
            return .path(copy)
        }
        let isFill: (AppearanceItem) -> Bool = { if case .fill = $0 { true } else { false } }
        return (part(isFill, objectEffects: false), part({ !isFill($0) }, objectEffects: true))
    }
}

/// The contents handle (OBJ-028, clipping-paths.adoc "Editing the contents"): a small circle at
/// the centre of a clip group's contents that the Pointer tool draws when the *Contents* row is
/// selected; dragging it moves every content node, leaving the clip path in place.
public enum ContentsHandle {
    /// The handle's position in pasteboard space: the centre of the contents' bounds as the scene
    /// draws them (unclipped); nil when `group` is not a clip group or has no drawn contents.
    public static func position(of group: OpID, in scene: DocumentScene, state: EngineState) -> Point? {
        guard ClipGroups.isClipGroup(group, in: state) else { return nil }
        var bounds = Rect.null
        for content in ClipGroups.contents(of: group, in: state) {
            if let rect = scene.object(content)?.bounds { bounds = bounds.union(rect) }
        }
        return bounds.isNull ? nil : bounds.center
    }

    /// Whether `point` (pasteboard) is on the handle at `position`, within `tolerance` (the pick
    /// distance in pasteboard units).
    public static func hits(_ point: Point, handle position: Point, tolerance: Double) -> Bool {
        point.distance(to: position) <= tolerance
    }
}

/// Dragging the contents handle: every content node of the clip group moves by `delta`
/// (pasteboard) in one change "Move contents"; the clip path stays.  Locked contents stay too.
public struct MoveContents: Command {
    public var group: OpID
    public var delta: Vector
    public var label: String { "Move contents" }

    public init(_ group: OpID, by delta: Vector) {
        self.group = group
        self.delta = delta
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard ClipGroups.isClipGroup(group, in: state), delta != .zero else { return }
        try MoveObjects(ClipGroups.contents(of: group, in: state), by: delta).execute(&builder, state: state)
    }
}
