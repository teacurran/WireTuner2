import Foundation
import WTCRDT
import WTProto

// DATA-003: text placeholders (data-merge.adoc, "Text placeholders"; "Client", "Fields and
// bindings").  A placeholder is the characters `{{name}}` under a non-expanding `field` mark; it
// is inserted, selected and deleted as one unit.

/// Reading placeholders for the Text tool.
public enum DataPlaceholders {
    /// The id a placeholder for a name that matches no field carries: counter 0 is never a real
    /// element, so it always reads as missing (drawn in red with the "create field" offer).  The
    /// all-zero id cannot be used: a `field` mark of it is the attribute's cleared value, which
    /// reads as no mark.
    public static let unknownField = OpID(counter: 0, replica: UInt64.max)

    /// The `field` mark value naming `field` (`unknownField` when nil).
    public static func mark(_ field: OpID?) -> Wiretuner_Doc_V1_TextMarkValue {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.field = (field ?? unknownField).elementID
        return value
    }

    /// The name of a completed `{{name}}` typed immediately before live offset `caret` (spaces
    /// allowed inside the braces) and the live range of its characters; nil when the text
    /// before the caret does not end with one, or when those characters are already a
    /// placeholder.
    public static func completed(in text: TextNode, before caret: Int) -> (name: String, range: Range<Int>)? {
        guard caret >= 4, caret <= text.length else { return nil }
        let scalars = Array(text.string.unicodeScalars)
        guard scalars[caret - 1] == "}", scalars[caret - 2] == "}" else { return nil }
        // Walk back to the opening braces (a name is at most 64 characters plus spaces).
        var index = caret - 3
        let floor = max(0, caret - 3 - 200)
        while index > floor, !(scalars[index] == "{" && scalars[index - 1] == "{") {
            if scalars[index] == "}" || scalars[index] == "\n" { return nil }
            index -= 1
        }
        guard index >= 1, scalars[index] == "{", scalars[index - 1] == "{" else { return nil }
        let start = index - 1
        var inner = String.UnicodeScalarView()
        inner.append(contentsOf: scalars[(index + 1)..<(caret - 2)])
        let name = String(inner).trimmingCharacters(in: .whitespaces)
        guard DataFieldsPaths.isValidName(name) else { return nil }
        let range = start..<caret
        let model = DataModel.placeholderRuns(text)
        guard !model.contains(where: { $0.overlaps(range) }) else { return nil }
        return (name, range)
    }

    /// The live range to select or delete when `range` touches placeholders: `range` grown to
    /// cover every placeholder it overlaps (a caret inside one selects the whole of it), so a
    /// placeholder is always one unit.
    public static func unitRange(_ range: Range<Int>, in text: TextNode) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        for span in DataModel.placeholderRuns(text) {
            let touches = range.isEmpty ? (span.lowerBound < range.lowerBound && range.lowerBound < span.upperBound) : span.overlaps(range)
            if touches {
                lower = min(lower, span.lowerBound)
                upper = max(upper, span.upperBound)
            }
        }
        return lower..<upper
    }
}

extension DataModel {
    /// The live ranges of every `field` mark run of `text`, adjacent runs of one field joined
    /// (no field lookup, so it can be used without a model).
    static func placeholderRuns(_ text: TextNode) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var last: Wiretuner_Doc_V1_ElementId?
        for run in text.runs {
            let id = run.values.lazy.compactMap { value -> Wiretuner_Doc_V1_ElementId? in
                if case .field(let id)? = value.value { return id }
                return nil
            }.first
            guard let id, !run.range.isEmpty else {
                last = nil
                continue
            }
            if let previous = result.last, last == id, previous.upperBound == run.range.lowerBound {
                result[result.count - 1] = previous.lowerBound..<run.range.upperBound
            } else {
                result.append(run.range)
            }
            last = id
        }
        return result
    }
}

/// *Insert Field* and dragging a field from the Data panel: types `{{name}}` at a caret under a
/// `field` mark (plus `marks`, the pending format), one change "Insert field".
public struct InsertPlaceholder: Command {
    public var node: OpID
    public var at: Anchor
    public var field: OpID
    public var marks: [Wiretuner_Doc_V1_TextMarkValue]
    public var label: String { "Insert field" }

    public init(node: OpID, at: Anchor, field: OpID, marks: [Wiretuner_Doc_V1_TextMarkValue] = []) {
        self.node = node
        self.at = at
        self.field = field
        self.marks = marks
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let info = try DataEditing.field(field, in: state)
        let text = try TextEditing.text(node, in: state)
        let offset = try text.offset(of: at)
        let formats = marks.filter { if case .field? = $0.value { return false } else { return true } }
        TextEditing.insert("{{\(info.name)}}", at: offset, in: text, marks: formats + [DataPlaceholders.mark(field)], state: state, builder: &builder)
    }
}

/// The Text tool's recognition of a typed `{{name}}`: as soon as the closing braces are typed,
/// the characters are deleted and typed again under the `field` mark (keeping the formatting of
/// their first character), so the placeholder is one unit; a name that matches no field gets the
/// zero id.  One change "Insert field".
public struct ConvertTypedPlaceholder: Command {
    public var node: OpID
    /// The caret just after the closing braces.
    public var caret: Anchor
    public var label: String { "Insert field" }

    public init(node: OpID, caret: Anchor) {
        self.node = node
        self.caret = caret
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        guard let found = DataPlaceholders.completed(in: text, before: try text.offset(of: caret)) else { throw DataEditError.noPlaceholder }
        let model = DataModel(state)
        let field = model.field(named: found.name)
        let formats = text.values(at: found.range.lowerBound).filter { if case .field? = $0.value { return false } else { return true } }
        let ids = Array(text.chars[found.range])
        for op in TextEditing.deletes(node, ids) {
            builder.append(op)
        }
        let origins = state.insertionOrigins(node, TextFields.text, at: found.range.lowerBound, stableSeq: 0)
        _ = TextEditing.insert("{{\(field?.name ?? found.name)}}", node: node, origins: origins,
                               split: text.paragraphs[text.paragraphIndex(at: found.range.lowerBound)],
                               marks: formats + [DataPlaceholders.mark(field?.id)], state: state, builder: &builder)
    }
}
