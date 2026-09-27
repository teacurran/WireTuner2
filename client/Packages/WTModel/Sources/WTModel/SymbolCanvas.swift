import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// The symbol editing window's model half (library.adoc, "Symbol editing window"; LIB-012): a
// canvas whose builder draws a symbol's artwork (`DocumentDisplayListBuilder.canvasNode` = the
// symbol) and whose commands put what they create into the symbol.

/// A command performed on a symbol's canvas: the command, with every top-level object it creates
/// on a layer created in the symbol instead, above its artwork (bottom first, in the order the
/// command made them).  Everything else the command writes is left as it is -- an object created
/// inside another (a group's member) keeps its parent, and a layer the command makes for itself
/// (the first object of a document without layers) is still made -- and the op ids are the
/// command's own, so undo and the change's `createdObjects` see what the command made.  A symbol
/// that is gone places nothing: the command runs as it is.
public struct SymbolPlacedCommand: Command {
    public let base: any Command
    public let symbol: OpID

    public init(base: any Command, symbol: OpID) {
        self.base = base
        self.symbol = symbol
    }

    public var label: String { base.label }
    public var coalescing: UndoCoalescing { base.coalescing }
    public var recordsUndo: Bool { base.recordsUndo }

    /// `command` as performed on `symbol`'s canvas (never wrapped twice).
    public static func placing(_ command: any Command, in symbol: OpID) -> any Command {
        command is SymbolPlacedCommand ? command : SymbolPlacedCommand(base: command, symbol: symbol)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var scratch = ChangeBuilder(replica: builder.replica, startCounter: builder.nextCounter)
        try base.execute(&scratch, state: state)
        let redirects = state.isLive(symbol) && state.nodeKind(symbol) == .symbol
        var last = state.store.children(symbol).last.flatMap { state.store.placement($0)?.position }
        var layers: Set<OpID> = []
        var counter = scratch.startCounter
        for var op in scratch.ops {
            let id = OpID(counter: counter, replica: builder.replica)
            counter &+= EngineState.counters(op)
            if redirects, case .create(var create)? = op.op {
                let parent = OpID(create.parent)
                if case .layer? = create.props.kind {
                    layers.insert(id)
                } else if layers.contains(parent) || state.nodeKind(parent) == .layer {
                    let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
                    last = key
                    create.parent = symbol.proto
                    create.position = Data(key)
                    op.create = create
                }
            }
            builder.append(op)
        }
    }
}

extension Symbols {
    /// Where a symbol's canvas scrolls to fit: its live artwork's bounds, or a 72 pt square about
    /// its origin when it has none (symbol space = pasteboard space).
    public static func canvasBounds(of symbol: OpID, in state: EngineState) -> Rect {
        var bounds = Rect.null
        for child in state.liveChildren(symbol) {
            if let rect = Objects.bounds(of: child, in: state) { bounds = bounds.union(rect) }
        }
        guard bounds.isNull else { return bounds }
        let origin = state.props(symbol).symbol.origin
        return Rect(x: origin.x - 36, y: origin.y - 36, width: 72, height: 72)
    }

    /// A symbol canvas's background: the pasteboard in white (artwork is drawn for placing on a
    /// page) and a hairline cross at the symbol's origin, the point instances place at their
    /// transform's translation; nothing once the symbol is gone.
    public static func canvasBackground(of symbol: OpID, in state: EngineState) -> [DisplayItem] {
        guard state.isLive(symbol), state.nodeKind(symbol) == .symbol else { return [] }
        let origin = state.props(symbol).symbol.origin
        let arm = 8.0
        var cross = DisplayPath()
        cross.move(to: Point(x: origin.x - arm, y: origin.y))
        cross.addLine(to: Point(x: origin.x + arm, y: origin.y))
        cross.move(to: Point(x: origin.x, y: origin.y - arm))
        cross.addLine(to: Point(x: origin.x, y: origin.y + arm))
        let ground = PageRendering.item([], style: PageStyle(pasteboardColor: Color(white: 1)))
        let marker = DisplayItem.stroke(StrokeItem(path: cross, style: StrokeStyle(width: 0), paint: .solid(originColor)))
        return [.group(GroupItem(children: [ground, marker]))]
    }

    /// The origin cross's colour.
    public static let originColor = Color(red: 0.9, green: 0.2, blue: 0.2)
}
