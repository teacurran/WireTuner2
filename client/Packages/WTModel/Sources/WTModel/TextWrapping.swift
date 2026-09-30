import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTText

// Flow Around Selection (text-effects.adoc, "Wrapping text around objects"; TYPE-039):
// `CommonProps.text_wrap` (13) on any single object -- groups and blends refused -- and the
// collection of the objects in front of a text block that its layout flows around, handed to
// WTText as `TextBlock.exclusions`.

/// Register paths of `CommonProps.text_wrap`.
public enum TextWrapFields {
    public static func wrap(_ kind: UInt32) -> RegisterPath { NavigationFields.common(kind).child(13) }
    public static func enabled(_ kind: UInt32) -> RegisterPath { wrap(kind).child(1) }
    public static func standoff(_ kind: UInt32) -> RegisterPath { wrap(kind).child(2) }
}

/// Why the wrap sheet refuses a selection.
public enum TextWrapError: Error, Hashable, Sendable {
    /// Groups and blends cannot push text away; draw a path around them.
    case notWrappable(OpID)
}

/// Turns text wrap on with `standoff` (points; negative overlaps) or off (btn:[Remove text wrap])
/// on each object: `enabled` and, when on, `standoff`, two registers.  "Text Wrap" / "Remove
/// Text Wrap".
public struct SetTextWrap: Command {
    public var nodes: [OpID]
    public var enabled: Bool
    public var standoff: Double

    public init(_ nodes: [OpID], enabled: Bool, standoff: Double = 0) {
        self.nodes = nodes
        self.enabled = enabled
        self.standoff = standoff
    }

    public var label: String { enabled ? "Text Wrap" : "Remove Text Wrap" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard standoff.isFinite else { throw TextEditError.invalidValue("standoff") }
        for node in nodes where !TextWrapping.isWrappable(node, in: state) { throw TextWrapError.notWrappable(node) }
        for (node, kind) in try Navigation.linkable(nodes, in: state) {
            let paths = enabled ? [TextWrapFields.enabled(kind), TextWrapFields.standoff(kind)] : [TextWrapFields.enabled(kind)]
            builder.append(Ops.set(node, paths, values: NavigationFields.values(kind: kind) {
                $0.textWrap.enabled = enabled
                $0.textWrap.standoff = standoff
            }))
        }
    }
}

/// Reading text wrap.
public enum TextWrapping {
    /// Whether `node` may carry text wrap: a live object other than a group or a blend.
    public static func isWrappable(_ node: OpID, in state: EngineState) -> Bool {
        guard NavigationFields.isLinkable(node, in: state) else { return false }
        let kind = state.nodeKind(node)
        return kind != .group && kind != .blend
    }

    /// The object's text wrap as read (nil: off, or a group or blend, which ignore it).
    public static func wrap(of node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_TextWrap? {
        // A register lookup first: most objects never had text wrap written.
        guard state.store.register(node, TextWrapFields.enabled(state.store.kind(node)))?.value != nil,
              state.isLive(node), let common = NodeValues.common(state.props(node)), common.textWrap.enabled,
              state.nodeKind(node) != .group, state.nodeKind(node) != .blend else { return nil }
        return common.textWrap
    }

    /// The objects in front of text node `text` whose text wrap is on, back to front, with their
    /// wraps: every searchable object after it in stacking order, on any layer.
    public static func wrappingObjects(for text: OpID, in state: EngineState) -> [OpID] {
        wraps(for: text, in: state).map(\.node)
    }

    static func wraps(for text: OpID, in state: EngineState) -> [(node: OpID, wrap: Wiretuner_Doc_V1_TextWrap)] {
        if let pass { return pass.wraps(for: text, in: state) }
        let order = AttributeQuery.candidates(.document, in: state)
        guard let index = order.firstIndex(of: text) else { return [] }
        return order[(index + 1)...].compactMap { node in wrap(of: node, in: state).map { (node, $0) } }
    }

    /// One pass of the display list builder over one state (IO-040: an opened PDF of thousands of
    /// text runs laid every block out against a fresh walk of the whole document, minutes of
    /// sorting): the stacking order and the wrapping objects are read once, on the first block
    /// that asks, and every block of the pass answers from them.  Only valid while the state does
    /// not change, which a build guarantees.
    @TaskLocal static var pass: Pass?

    /// The pass's cached order (`Pass`), shared by the blocks of one build.
    final class Pass: @unchecked Sendable {
        private let lock = NSLock()
        private var index: [OpID: Int]?
        private var wrapping: [(position: Int, node: OpID, wrap: Wiretuner_Doc_V1_TextWrap)] = []

        func wraps(for text: OpID, in state: EngineState) -> [(node: OpID, wrap: Wiretuner_Doc_V1_TextWrap)] {
            lock.lock()
            defer { lock.unlock() }
            if index == nil {
                let order = AttributeQuery.candidates(.document, in: state)
                var positions: [OpID: Int] = [:]
                for (position, node) in order.enumerated() where positions[node] == nil { positions[node] = position }
                index = positions
                wrapping = order.enumerated().compactMap { position, node in TextWrapping.wrap(of: node, in: state).map { (position, node, $0) } }
            }
            guard let position = index?[text] else { return [] }
            return wrapping.filter { $0.position > position }.map { ($0.node, $0.wrap) }
        }
    }

    /// `body` with one wrap pass over its state.
    static func withPass<T>(_ body: () throws -> T) rethrows -> T {
        try $pass.withValue(Pass(), operation: body)
    }

    /// The exclusions of text node `text`: each wrapping object's outline in its own space (a
    /// shape's contours, a text block's frame, else its bounds), its transform into the block's
    /// space and its standoff.
    public static func exclusions(for text: OpID, in state: EngineState) -> [TextExclusion] {
        let objects = wraps(for: text, in: state)
        guard !objects.isEmpty, let toBlock = Objects.pasteboardTransform(of: text, in: state).inverted() else { return [] }
        return objects.compactMap { node, wrap -> TextExclusion? in
            let ownToBlock = Objects.pasteboardTransform(of: node, in: state).concatenating(toBlock)
            if let path = Objects.localPath(node, in: state) {
                let contours = path.contours.filter(\.isRenderable).map { Contour(segments: $0.segments.map(\.cubic), closed: true) }
                return TextExclusion(contours: contours, transform: ownToBlock, standoff: wrap.standoff)
            }
            if state.nodeKind(node) == .text {
                // A text block pushes text away with its frame (auto-sized blocks have none stored).
                let block = state.props(node).text.block
                guard block.width > 0, block.height > 0 else { return nil }
                return TextExclusion(contours: [Contour(polygon: rectangle(Rect(x: 0, y: 0, width: block.width, height: block.height)))],
                                     transform: ownToBlock, standoff: wrap.standoff)
            }
            guard let bounds = Objects.bounds(of: node, in: state) else { return nil }
            return TextExclusion(contours: [Contour(polygon: rectangle(bounds))], transform: toBlock, standoff: wrap.standoff)
        }
    }

    static func rectangle(_ rect: Rect) -> [Point] {
        [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
    }

    /// `container` with the exclusions of text node `text` (a block container; others unchanged).
    public static func wrapped(_ container: TextContainer, text: OpID, in state: EngineState) -> TextContainer {
        guard case .block(var block) = container else { return container }
        block.exclusions = exclusions(for: text, in: state)
        return .block(block)
    }
}
