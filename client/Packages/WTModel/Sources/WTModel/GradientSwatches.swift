import Foundation
import WTCRDT
import WTProto
import WTRender

// ATTR-029: gradient swatches (docs/_includes/appearance/gradients.adoc, "The ramp": "drag the
// ramp to the Swatches panel; applying a gradient swatch later copies its ramp into the fill").
// A gradient swatch is a `gradient_swatch` node (`NodeProps` field 71, `GradientSwatchProps`)
// under the swatches collection 0:5, beside the colour swatches.  Nothing references it: applying
// one copies its type, behavior, count and stops (their swatch references intact) into fills, so
// editing or removing it later changes no object.

/// The `gradient_swatch` node kind's registers.
public enum GradientSwatchFields {
    /// `NodeProps.gradient_swatch`.
    public static let kind: UInt32 = 71
    public static let name = RegisterPath([71, 1, 1])
    public static let group = RegisterPath([71, 3])
    /// The `GradientFill`'s field number in `GradientSwatchProps`.
    public static let gradient: UInt32 = 2
}

/// Why a gradient swatch command was refused.
public enum GradientSwatchError: Error, Equatable, Sendable {
    /// Not a live gradient swatch.
    case notAGradientSwatch(OpID)
    /// The fill is not a gradient with at least two stops to keep.
    case notAGradient
    /// Another gradient swatch holds the name.
    case nameTaken(String)
    /// A gradient swatch needs a name.
    case emptyName
}

/// One gradient swatch as read.
public struct GradientSwatch: Hashable, Sendable {
    public let id: OpID
    public let name: String
    public let group: String
    /// The stored gradient; `GradientSwatches.fill(of:)` is what applying copies.
    public let gradient: Wiretuner_Doc_V1_GradientFill
}

/// Reading gradient swatches.
public enum GradientSwatches {
    /// The live gradient swatches in list (sibling) order.
    public static func list(in state: EngineState) -> [GradientSwatch] {
        state.liveChildren(SwatchFields.collection).compactMap { swatch($0, in: state) }
    }

    /// The live gradient swatch `id`, or nil.
    public static func swatch(_ id: OpID, in state: EngineState) -> GradientSwatch? {
        guard state.store.kind(id) == GradientSwatchFields.kind, state.isLive(id),
              state.store.placement(id)?.parent == SwatchFields.collection else { return nil }
        let props = state.props(id).gradientSwatch
        return GradientSwatch(id: id, name: props.common.name, group: props.group, gradient: props.gradient)
    }

    /// What applying the swatch writes into a fill: its type, behavior, count and ramp (stops in
    /// ramp order with their colours, swatch references kept), no axis -- each object takes Auto
    /// size geometry.
    public static func fill(of swatch: GradientSwatch) -> Wiretuner_Doc_V1_GradientFill {
        kept(swatch.gradient)
    }

    /// The part of `gradient` a swatch keeps: type, behavior, count and the ramp's offsets and
    /// colours (no axis, no stop ids, no ramp tags).
    static func kept(_ gradient: Wiretuner_Doc_V1_GradientFill) -> Wiretuner_Doc_V1_GradientFill {
        var result = Wiretuner_Doc_V1_GradientFill()
        result.type = gradient.type
        result.behavior = gradient.behavior
        result.repeatCount = gradient.repeatCount
        result.overprint = gradient.overprint
        result.stops = GradientReading.ramp(gradient).map { stop in
            var value = Wiretuner_Doc_V1_GradientStop()
            value.offset = stop.offset
            value.color = stop.color
            return value
        }
        return result
    }

    /// The swatch's gradient as the renderer draws it (a Swatches-panel chip, the sheet preview),
    /// stop colours resolved through `resolver` -- live swatch references follow their swatch --
    /// or through a resolver of `state` when none is given; nil for a missing swatch.
    public static func gradient(_ id: OpID, in state: EngineState, resolver: ColorResolver? = nil) -> Gradient? {
        guard let swatch = swatch(id, in: state) else { return nil }
        return ColorResolver.$current.withValue(resolver ?? ColorResolver(state)) {
            Appearances.gradient(fill(of: swatch))
        }
    }

    /// A free name: `base`, else `base 2`, `base 3`, ...
    static func freeName(_ base: String, in state: EngineState) -> String {
        let taken = Set(list(in: state).map(\.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// A name as stored, trimmed; refused when empty or held by another gradient swatch.
    static func checkedName(_ name: String, except: OpID? = nil, in state: EngineState) throws -> String {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SwatchFields.maxName))
        guard !clean.isEmpty else { throw GradientSwatchError.emptyName }
        guard !list(in: state).contains(where: { $0.name == clean && $0.id != except }) else { throw GradientSwatchError.nameTaken(clean) }
        return clean
    }
}

/// Dragging a ramp to the Swatches panel (gradients.adoc, "To keep a finished gradient for reuse"):
/// a new gradient swatch at the end of the list holding the fill's type, behavior, count and ramp
/// -- stop colours as they are, swatch references kept.  An empty name takes "Gradient" (or
/// "Gradient 2", ...).  Labelled "Add gradient swatch".
public struct AddGradientSwatch: Command {
    public var gradient: Wiretuner_Doc_V1_GradientFill
    public var name: String
    public var group: String

    /// A swatch of `gradient` itself.
    public init(_ gradient: Wiretuner_Doc_V1_GradientFill, name: String = "", group: String = "") {
        self.gradient = gradient
        self.name = name
        self.group = group
    }

    /// A swatch of the Gradient fill `row` of `node`; throws when it is not one.
    public init(node: OpID, row: AppearanceRow, name: String = "", group: String = "", in state: EngineState) throws {
        let (_, entry) = try GradientEditing.fill(node, row, in: state)
        guard entry.kind == .fill(.gradient) else { throw GradientSwatchError.notAGradient }
        self.init(entry.fill.settings.gradient, name: name, group: group)
    }

    public var label: String { "Add gradient swatch" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let kept = GradientSwatches.kept(gradient)
        guard kept.stops.count >= 2 else { throw GradientSwatchError.notAGradient }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.gradientSwatch.common.name = trimmed.isEmpty ? GradientSwatches.freeName("Gradient", in: state)
            : try GradientSwatches.checkedName(trimmed, in: state)
        props.gradientSwatch.group = String(group.prefix(SwatchFields.maxLabel))
        props.gradientSwatch.gradient = kept
        try NodeCopier.create(NodeTree(props: props), parent: SwatchFields.collection,
                              position: try PathEditing.topPosition(in: SwatchFields.collection, state: state),
                              schema: state.schema, builder: &builder)
    }
}

/// Renaming a gradient swatch.  Labelled "Rename gradient".
public struct RenameGradientSwatch: Command {
    public var swatch: OpID
    public var name: String

    public init(_ swatch: OpID, name: String) {
        self.swatch = swatch
        self.name = name
    }

    public var label: String { "Rename gradient" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let current = GradientSwatches.swatch(swatch, in: state) else { throw GradientSwatchError.notAGradientSwatch(swatch) }
        let clean = try GradientSwatches.checkedName(name, except: swatch, in: state)
        guard clean != current.name else { return }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.gradientSwatch.common.name = clean
        builder.append(Ops.set(swatch, [GradientSwatchFields.name], values: props))
    }
}

/// Removing gradient swatches (their `deleted` flags; objects keep the gradients they were
/// given).  Labelled "Remove gradient" or "Remove 3 gradients".
public struct RemoveGradientSwatches: Command {
    public var swatches: [OpID]

    public init(_ swatches: [OpID]) {
        self.swatches = swatches
    }

    public var label: String {
        let count = Set(swatches).count
        return count == 1 ? "Remove gradient" : "Remove \(count) gradients"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for id in Array(Set(swatches)).sorted() {
            guard GradientSwatches.swatch(id, in: state) != nil else { throw GradientSwatchError.notAGradientSwatch(id) }
            builder.append(Ops.setDeleted(id))
        }
    }
}

/// Applying a gradient swatch to objects (a click in the Swatches panel with a fill selected, a
/// drop): `ApplyGradient` with the swatch's type, behavior, count and ramp -- every object of the
/// selection, groups expanded, on its topmost fill or a new one, stops replaced in one change and
/// the fill's `ramp` naming this application, so of two concurrent applications the later wins in
/// full.  Labelled "Apply gradient".
public struct ApplyGradientSwatch: Command {
    public var swatch: OpID
    public var nodes: [OpID]

    public init(_ swatch: OpID, to nodes: [OpID]) {
        self.swatch = swatch
        self.nodes = nodes
    }

    public var label: String { "Apply gradient" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let current = GradientSwatches.swatch(swatch, in: state) else { throw GradientSwatchError.notAGradientSwatch(swatch) }
        try ApplyGradient(nodes, gradient: GradientSwatches.fill(of: current)).execute(&builder, state: state)
    }
}
