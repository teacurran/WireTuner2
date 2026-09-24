import Foundation
import WTCRDT
import WTProto
import WTText

/// *Replace…* in the Missing Fonts sheet and Type > Replace Font (DOC-025; font-substitution.adoc,
/// "Replacing a font"): every run of drawn text whose own marks name an old face gets the new
/// family -- and the new style when the replacement names one -- as text marks over the run, for
/// everyone.  Kerning, tracking and size are other marks and are kept.  All replacements are one
/// change, "Replace font <old> with <new>" (or "Replace N fonts"), whose inverse restores the old
/// marks on the runs this change wrote; runs whose face comes from a character style are left.
///
/// The marks expand like typing does (start before the run's first character, end after its
/// last), so text typed concurrently inside a replaced run takes the replacement; two replacements
/// of one font resolve per character by the later mark.
public struct ReplaceFont: Command {
    public struct Replacement: Hashable, Sendable {
        public var old: FaceName
        public var new: FaceName

        public init(old: FaceName, new: FaceName) {
            self.old = old
            self.new = new
        }
    }

    public var replacements: [Replacement]

    public init(_ replacements: [Replacement]) {
        self.replacements = replacements
    }

    /// `replaceFont(old:new:)`.
    public init(old: FaceName, new: FaceName) {
        self.init([Replacement(old: old, new: new)])
    }

    public var label: String {
        guard replacements.count == 1, let only = replacements.first else { return "Replace \(replacements.count) fonts" }
        return "Replace font \(only.old) with \(only.new)"
    }

    /// Whether a run's `face` is what `old` names: the family, and the style when `old` has one
    /// (ignoring case).
    public static func matches(_ face: FaceName, _ old: FaceName) -> Bool {
        face.family == old.family && (old.style == nil || old.style?.lowercased() == face.style?.lowercased())
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !replacements.isEmpty else { return }
        for node in DocumentFontIndex.faces(in: state).keys.sorted() {
            for path in state.store.textPaths(node) {
                guard let text = state.store.text(node, path) else { continue }
                let chars = text.liveChars
                for run in text.runs where run.length > 0 {
                    guard let face = Self.face(of: run.attributes),
                          let replacement = replacements.first(where: { Self.matches(face, $0.old) }) else { continue }
                    let from = chars[run.start], to = chars[run.start + run.length - 1]
                    var family = Wiretuner_Doc_V1_TextMarkValue()
                    family.fontFamily = replacement.new.family
                    builder.append(Self.mark(node, path, from: from, to: to, value: family))
                    if let style = replacement.new.style {
                        var value = Wiretuner_Doc_V1_TextMarkValue()
                        value.fontStyle = style
                        builder.append(Self.mark(node, path, from: from, to: to, value: value))
                    }
                }
            }
        }
    }

    /// The face a run's own marks name; nil without a family mark (a cleared mark, an empty name,
    /// is not an attribute of the run).
    public static func face(of attributes: [TextAttribute]) -> FaceName? {
        var family: String?
        var style: String?
        for attribute in attributes {
            switch (try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: attribute.value))?.value {
            case .fontFamily(let name)?: family = name.isEmpty ? nil : name
            case .fontStyle(let name)?: style = name.isEmpty ? nil : name
            default: break
            }
        }
        return family.map { FaceName(family: $0, style: style) }
    }

    /// A `TextMark` of `value` over `from` ... `to` (both included), expanding like typing does.
    static func mark(_ node: OpID, _ field: RegisterPath, from: OpID, to: OpID, value: Wiretuner_Doc_V1_TextMarkValue) -> Wiretuner_Doc_V1_Op {
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = node.proto
        mark.text = field.proto
        mark.start.char = Ops.elementID(from)
        mark.start.before = true
        mark.end.char = Ops.elementID(to)
        mark.end.before = false
        mark.value = value
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        return op
    }
}
