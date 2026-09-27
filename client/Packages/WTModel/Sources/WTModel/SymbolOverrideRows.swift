import Foundation
import WTCRDT
import WTInterchange
import WTProto

// The Object panel's Overrides section, model half (library.adoc, "Overriding parts of an
// instance", "Overrides section"; LIB-027): which parts of a symbol can be overridden, what each
// shows in an instance, and the commands its editors write.

/// One overridable property of one part of a symbol's artwork: a row of the Overrides section.
public struct OverrideRow: Hashable, Sendable {
    public var master: OpID
    public var property: Wiretuner_Doc_V1_OverrideProperty
    /// The part's name: its own (`CommonProps.name`), else its kind with a few words of its text
    /// ("Text: Buy now").
    public var name: String
    /// How deep in the artwork's groups the part is (0: a child of the symbol).
    public var depth: Int

    public var key: OverrideKey { OverrideKey(master: master, property: property) }
}

/// What a row shows for one instance.
public enum OverrideRowValue: Hashable, Sendable {
    case text(String)
    /// The part's first basic fill or stroke colour (nil: none).
    case color(Wiretuner_Doc_V1_ColorRef?)
    case visible(Bool)
    /// The image's asset (nil: the master's own picture).
    case image(OpID?)
}

extension Symbols {
    /// The rows of `symbol`'s artwork, depth-first in stacking order (bottom first), stopping at
    /// nested instances: a text block's Text, a part with basic fills its Fill, with basic strokes
    /// its Stroke, every part its Visible, an image its Image.
    public static func overrideRows(of symbol: OpID, in state: EngineState) -> [OverrideRow] {
        var rows: [OverrideRow] = []
        func visit(_ node: OpID, depth: Int) {
            let props = state.props(node)
            let name = partTitle(node, in: state)
            func add(_ property: Wiretuner_Doc_V1_OverrideProperty) { rows.append(OverrideRow(master: node, property: property, name: name, depth: depth)) }
            if case .text? = props.kind { add(.text) }
            if basicColor(node, strokes: false, in: state) != nil { add(.fill) }
            if basicColor(node, strokes: true, in: state) != nil { add(.stroke) }
            add(.hidden)
            if case .image? = props.kind { add(.image) }
            // An override reaches one level: not inside a nested instance.
            guard state.nodeKind(node) != .instance else { return }
            for child in state.liveChildren(node) { visit(child, depth: depth + 1) }
        }
        for child in state.liveChildren(symbol) { visit(child, depth: 0) }
        return rows
    }

    /// A part's name for the Overrides section: its own name, else its kind, with the first words
    /// of a text block's text ("Text: Buy now").
    public static func partTitle(_ node: OpID, in state: EngineState) -> String {
        if let name = NodeValues.common(state.props(node))?.name, !name.isEmpty { return name }
        let kind = state.nodeKind(node).map { "\($0)" } ?? "part"
        let title = kind.prefix(1).uppercased() + kind.dropFirst()
        guard let text = TextNode(node, in: state), !text.string.isEmpty else { return title }
        let words = text.string.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
        return "Text: \(words.count > 24 ? String(words.prefix(24)) + "…" : words)"
    }

    /// The colour of `node`'s first basic fill (or stroke), nil when it has none.
    static func basicColor(_ node: OpID, strokes: Bool, in state: EngineState) -> Wiretuner_Doc_V1_ColorRef? {
        guard let appearance = NodeValues.appearance(state.props(node)) else { return nil }
        if strokes { return appearance.strokes.first { $0.settings.kind == .basic }?.settings.basic.color }
        return appearance.fills.first { $0.settings.kind == .basic }?.settings.basic.color
    }

    /// What `row` shows in `instance`, and whether a live override supplies it.
    public static func overrideValue(_ row: OverrideRow, of instance: OpID, in state: EngineState) -> (value: OverrideRowValue, overridden: Bool) {
        let override = liveOverrides(of: instance, in: state)[row.key]
        switch row.property {
        case .text:
            let shown = textNode(row.master, in: instance, state: state)?.string ?? ""
            return (.text(shown), override != nil)
        case .fill: return (.color(override.map(\.fill) ?? basicColor(row.master, strokes: false, in: state)), override != nil)
        case .stroke: return (.color(override.map(\.stroke) ?? basicColor(row.master, strokes: true, in: state)), override != nil)
        case .image: return (.image(override.map { OpID($0.image.id) }), override != nil)
        default: return (.visible(!(override?.hidden ?? false)), override != nil)
        }
    }
}

/// The Overrides section's text editor: the text block `master` shows `text` in every one of
/// `instances` -- typed over the whole of each (the first edit copying the master's text as
/// always) -- or, with empty text, follows the symbol again (the override reset, as emptying it on
/// the canvas does).  One change, "Override text" or "Reset override".
public struct OverrideTextValue: Command {
    public var instances: [OpID]
    public var master: OpID
    public var text: String
    public var label: String { text.isEmpty ? "Reset override" : "Override text" }

    public init(_ instances: [OpID], master: OpID, text: String) {
        self.instances = instances
        self.master = master
        self.text = text
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !text.isEmpty else {
            try ResetOverrides(instances, key: OverrideKey(master: master, property: .text)).execute(&builder, state: state)
            return
        }
        for instance in instances {
            guard let shown = Symbols.textNode(master, in: instance, state: state) else { throw SymbolError.notOverridable(master) }
            guard shown.string != text else { continue }
            try OverrideText(instance, master: master, edit: .replace(0..<shown.length, with: text)).execute(&builder, state: state)
        }
    }
}

/// The Overrides section's btn:[Choose…] beside an image: the picture `blob` becomes the image
/// override of `master` in every one of `instances` -- an asset made for it (or the one already
/// holding those bytes) in the same change.  "Override image".
public struct OverrideImage: Command {
    public var instances: [OpID]
    public var master: OpID
    public var blob: ImportedBlob
    public var name: String
    public var label: String { "Override image" }

    public init(_ instances: [OpID], master: OpID, blob: ImportedBlob, name: String) {
        self.instances = instances
        self.master = master
        self.blob = blob
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.nodeKind(master) == .image else { throw SymbolError.notOverridable(master) }
        let existing = state.liveChildren(WellKnown.assets).first { state.props($0).asset.sha256 == blob.sha256 }
        var writer = ImportWriter(state: state, link: nil, poster: nil)
        let asset = try existing ?? writer.asset(blob, name: name, link: nil, builder: &builder)
        try SetOverride(instances, master: master, value: .image(asset), in: state).execute(&builder, state: state)
    }
}
