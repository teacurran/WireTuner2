import WTCRDT
import WTProto
import WTText

/// menu:Text[Type Style > Superscript] and *Subscript* (TYPE-060, type-specifications.adoc
/// "Superscript and subscript"): a preset over the size and baseline shift of each run, the same
/// proportions RTF import uses (`TextAttributeMapping`): the run's size × 0.58, raised by 0.33 of
/// its size (superscript) or lowered by 0.14 (subscript), added to the shift it has.  Each run of
/// the range keeps its own proportions, so mixed sizes stay in step.
public enum TextScript: String, CaseIterable, Hashable, Sendable {
    case superscript, `subscript`

    public var title: String {
        switch self {
        case .superscript: "Superscript"
        case .`subscript`: "Subscript"
        }
    }

    /// The `size` and `baseline_shift` marks for a run of `size` points already shifted by
    /// `shift` points (rounded to hundredths, sizes kept to 0.1 ... 10,000 points).
    public func values(size: Double, shift: Double) -> [Wiretuner_Doc_V1_TextMarkValue] {
        let offset = self == .superscript ? size * TextAttributeMapping.superscriptRise : -size * TextAttributeMapping.subscriptDrop
        var scaled = Wiretuner_Doc_V1_TextMarkValue()
        scaled.size = min(max((size * TextAttributeMapping.scriptScale * 100).rounded() / 100, 0.1), 10_000)
        var raised = Wiretuner_Doc_V1_TextMarkValue()
        raised.baselineShift = ((shift + offset) * 100).rounded() / 100
        return [scaled, raised]
    }

    /// The preset's values for the run whose winning marks are `values`.
    public func values(for values: [Wiretuner_Doc_V1_TextMarkValue]) -> [Wiretuner_Doc_V1_TextMarkValue] {
        let attributes = TextLayoutReading.attributes(values)
        return self.values(size: attributes.size, shift: attributes.baselineShift)
    }

    /// The marks over `range` of `text`, run by run; empty for an empty range.
    public func marks(_ range: Range<Int>, in text: TextNode) -> [(range: Range<Int>, value: Wiretuner_Doc_V1_TextMarkValue)] {
        guard !range.isEmpty else { return [] }
        return text.runs.flatMap { run -> [(range: Range<Int>, value: Wiretuner_Doc_V1_TextMarkValue)] in
            let span = run.range.clamped(to: range)
            return span.isEmpty ? [] : values(for: run.values).map { (span, $0) }
        }
    }

    /// The command writing the preset over `range` of text block `node` -- one change labelled
    /// with the title -- or nil when there is nothing to write.
    public func command(_ node: OpID, range: Range<Int>, in state: EngineState) -> ApplyTextScript? {
        guard let text = state.textNode(node), !marks(range, in: text).isEmpty else { return nil }
        return ApplyTextScript(node: node, range: range, script: self)
    }
}

/// Writes a `TextScript` preset over a range of a text block: one `ApplyMark` per attribute per
/// run, one change labelled "Superscript" or "Subscript".  Marks are ordinary LWW mark writes, so
/// a concurrent size or baseline shift edit of the same characters is the same register.
public struct ApplyTextScript: Command {
    public var node: OpID
    public var range: Range<Int>
    public var script: TextScript

    public init(node: OpID, range: Range<Int>, script: TextScript) {
        self.node = node
        self.range = range
        self.script = script
    }

    public var label: String { script.title }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let text = state.textNode(node) else { return }
        for mark in script.marks(range, in: text) {
            try ApplyMark(node: node, from: text.anchor(at: mark.range.lowerBound), to: text.anchor(at: mark.range.upperBound), value: mark.value, label: label)
                .execute(&builder, state: state)
        }
    }
}
