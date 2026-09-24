import Foundation
import WTCRDT
import WTProto
import WTRender
import WTText

// DATA-016 (model half) and DATA-018's bound-field substitution: one record applied to the
// document for drawing -- the preview on the canvas, and each record of a merge to PDF or print.
// Nothing here writes to the document: the substitution is view state (`DataPreview` is
// local-only and never written; the window keeps it).

/// The window's preview state (data-merge.adoc, "Previewing records"): whether the canvas shows
/// the current record and which one.  Local to this Mac, never a document change.
public struct DataPreviewState: Hashable, Sendable {
    public var showing: Bool
    /// 0-based into the resolved record list; past the last record reads as the last.
    public var recordIndex: Int

    public init(showing: Bool = false, recordIndex: Int = 0) {
        self.showing = showing
        self.recordIndex = recordIndex
    }

    /// The index clamped to `count` records (0 when there are none).
    public func index(in count: Int) -> Int {
        count == 0 ? 0 : min(max(recordIndex, 0), count - 1)
    }

    /// kbd:[Cmd+Option+Right] / btn:[>]: the next record, stopping at the last.
    public func next(in count: Int) -> DataPreviewState {
        DataPreviewState(showing: showing, recordIndex: min(index(in: count) + 1, max(count - 1, 0)))
    }

    /// kbd:[Cmd+Option+Left] / btn:[<]: the previous record, stopping at the first.
    public func previous(in count: Int) -> DataPreviewState {
        DataPreviewState(showing: showing, recordIndex: max(index(in: count) - 1, 0))
    }
}

/// One record applied to the document's placeholders and bindings (data-merge.adoc,
/// "Preview"; `RecordSubstitution`): placeholder spans take the record's values, a TEXT binding
/// replaces a block's contents or a barcode's value, a visibility binding hides the node when
/// its value is no, a link binding sets the node's link.  Missing fields read as unbound: a
/// placeholder shows `{{missing}}`, a missing binding leaves the node as it is (an image keeps
/// its pixels, a visibility binding shows the object).
public struct RecordSubstitution: Sendable {
    public let model: DataModel
    public let record: RecordSet.Record
    /// *Remove blank lines* (merge only; the preview shows the lines).
    public var removeBlankLines: Bool

    public init(model: DataModel, record: RecordSet.Record, removeBlankLines: Bool = false) {
        self.model = model
        self.record = record
        self.removeBlankLines = removeBlankLines
    }

    /// The value placed for stored field id `stored`: the record's text for a live field,
    /// `{{missing}}` otherwise.
    public func text(for stored: Wiretuner_Doc_V1_ElementId) -> String {
        guard let field = model.field(OpID(element: stored)) else { return "{{missing}}" }
        return record.value(field.id).text
    }

    /// The contents of text node `text` with this record applied.
    public func mergeText(_ text: TextNode, state: EngineState) -> MergeText {
        var merged = MergeText(text)
        if let binding = model.binding(of: text.id, in: state), binding.kind == .text, let field = binding.resolved {
            merged = merged.replacingAll(with: record.value(field.id).text)
        } else {
            merged = merged.substituting { self.text(for: $0) }
        }
        return removeBlankLines ? merged.removingBlankLines() : merged
    }

    /// The layout content of text node `text` with this record applied.
    public func content(_ text: TextNode, state: EngineState, colors: ColorResolver? = nil) -> TextContent {
        mergeText(text, state: state).content(colors: colors)
    }

    /// The value a barcode draws: the bound field's value under a TEXT binding, else its own.
    public func barcodeValue(_ node: OpID, props: Wiretuner_Doc_V1_BarcodeProps, state: EngineState) -> String {
        guard let binding = model.binding(of: node, in: state), binding.kind == .text, let field = binding.resolved else { return props.value }
        return record.value(field.id).text
    }

    /// Whether a visibility binding hides `node` in this record.
    public func hides(_ node: OpID, state: EngineState) -> Bool {
        guard let binding = model.binding(of: node, in: state), binding.kind == .visibility, let field = binding.resolved else { return false }
        return !record.value(field.id).isTrue
    }

    /// The link a link binding gives `node` in this record (nil: no link binding, or a missing
    /// one, and the node keeps its own).
    public func link(_ node: OpID, state: EngineState) -> String? {
        guard let binding = model.binding(of: node, in: state), binding.kind == .link, let field = binding.resolved else { return nil }
        return record.value(field.id).text
    }

    /// The image field value (URL or path) an image binding gives `node` (nil: none or missing).
    public func image(_ node: OpID, state: EngineState) -> String? {
        guard let binding = model.binding(of: node, in: state), binding.kind == .image, let field = binding.resolved else { return nil }
        return record.value(field.id).raw
    }

    /// The issues this record has on the document: missing fields named by placeholders or
    /// bindings, and barcodes whose value cannot be encoded.
    public func issues(in state: EngineState) -> [MergeIssue] {
        var result: [MergeIssue] = []
        for node in DataBindings.liveNodes(in: state) {
            if let binding = model.binding(of: node, in: state), binding.isMissing {
                result.append(MergeIssue(record: record.number, kind: .missingField(name: binding.field.map { DataNotices.storedName($0, in: state) } ?? "")))
            }
            if let text = TextNode(node, in: state) {
                for placeholder in model.placeholders(in: text) where placeholder.resolved == nil {
                    result.append(MergeIssue(record: record.number, kind: .missingField(name: "")))
                }
            }
            if state.nodeKind(node) == .barcode {
                let props = state.props(node).barcode
                var spec = Barcodes.spec(props)
                spec.value = barcodeValue(node, props: props, state: state)
                if case .failure = BarcodeRendering.geometry(spec) {
                    result.append(MergeIssue(record: record.number, kind: .unencodableBarcode(node: node)))
                }
            }
        }
        return result
    }
}

/// Reading which fields a document's placeholders and bindings need, for validation before a
/// merge (the Data panel's red placeholders and the merge sheet's warning).
public enum DataValidation {
    /// A problem found before merging.
    public struct Problem: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// A placeholder whose field is deleted or was never defined (`{{missing}}`).
            case missingPlaceholder
            /// A binding whose field is deleted, or of a type the binding does not take.
            case missingBinding
            /// A live field that the connected source provides no column for (every record
            /// lacks it).
            case unmappedField(String)
        }

        public var node: OpID?
        public var kind: Kind
    }

    /// The document's missing placeholders and bindings, and -- given the source's columns --
    /// the used fields no column provides.
    public static func problems(in state: EngineState, columns: [String]? = nil) -> [Problem] {
        let model = DataModel(state)
        var problems: [Problem] = []
        var used: Set<OpID> = []
        for node in DataBindings.liveNodes(in: state) {
            if let binding = model.binding(of: node, in: state) {
                if let field = binding.resolved { used.insert(field.id) } else { problems.append(Problem(node: node, kind: .missingBinding)) }
            }
            if let text = TextNode(node, in: state) {
                for placeholder in model.placeholders(in: text) {
                    if let field = placeholder.resolved { used.insert(field.id) } else { problems.append(Problem(node: node, kind: .missingPlaceholder)) }
                }
            }
        }
        if let columns {
            let available = Set(columns.map { $0.lowercased() })
            for field in model.fields where used.contains(field.id) && !available.contains(model.path(of: field, in: model.activeSource).lowercased()) {
                problems.append(Problem(node: nil, kind: .unmappedField(field.displayName)))
            }
        }
        return problems
    }
}

/// The *field removed* live notice (data-merge.adoc, "Deleting a field that has bindings"): the
/// fields a change deleted that still have placeholders or bindings, with how many, so the
/// window can offer *Restore field*.
public enum DataNotices {
    public struct FieldRemoved: Hashable, Sendable {
        public var field: OpID
        public var name: String
        public var uses: Int
    }

    /// The name field element `field` last held, deleted or not ("" when it never had one).
    public static func storedName(_ field: OpID, in state: EngineState) -> String {
        guard let bytes = state.store.register(WellKnown.settings, DataFieldsPaths.name(field))?.value else { return "" }
        return (try? Wiretuner_Doc_V1_DataField(serializedBytes: bytes))?.name ?? ""
    }

    /// The fields live in `before` and not in `after` that `after` still uses.
    public static func fieldsRemoved(before: EngineState, after: EngineState) -> [FieldRemoved] {
        let old = DataModel(before)
        let current = DataModel(after)
        let gone = old.fields.filter { current.field($0.id) == nil }
        guard !gone.isEmpty else { return [] }
        let uses = current.uses(in: after)
        return gone.compactMap { field in
            guard let count = uses[field.id], count > 0 else { return nil }
            return FieldRemoved(field: field.id, name: field.name, uses: count)
        }
    }
}
