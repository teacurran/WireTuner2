import WTCRDT
import WTProto

// Convert Case (TYPE-015; type/editing-text.adoc, "Converting case" and "Merge semantics"): the
// five commands, the document's Convert Case settings (`SettingsProps.text_settings`, field 140)
// and the run-minimal rewrite.

/// One of the five menu:Text[Convert Case] commands.
public enum CaseConversion: Hashable, Sendable, CaseIterable {
    /// EVERY LETTER CAPITAL.
    case uppercase
    /// every letter small.
    case lowercase
    /// Lowercase letters drawn as smaller capitals: a `case` mark, not a rewrite.
    case smallCaps
    /// The First Letter Of Each Word Capital, the rest small.
    case title
    /// The first letter of each sentence capital, the rest small.
    case sentence

    /// The menu item's title.
    public var title: String {
        switch self {
        case .uppercase: "Uppercase"
        case .lowercase: "Lowercase"
        case .smallCaps: "Small Caps"
        case .title: "Title"
        case .sentence: "Sentence"
        }
    }
}

/// The register paths of `SettingsProps.text_settings` (`TextSettings`, text.proto).
public enum TextSettingsFields {
    /// `SettingsProps.text_settings`.
    public static let settings = RegisterPath([2, 140])
    /// `TextSettings.small_caps_percent`.
    public static let smallCapsPercent = RegisterPath([2, 140, 1])
    /// `TextSettings.case_exceptions` (a SEQUENCE).
    public static let exceptions = RegisterPath([2, 140, 2])
    /// The size small capitals take when `small_caps_percent` was never set.
    public static let defaultSmallCapsPercent = 75.0

    /// The registers of exception `id` below `CaseException`: 2 word, 3...7 the conversions.
    static func exception(_ id: OpID, _ field: UInt32) -> RegisterPath { exceptions.element(id).child(field) }

    /// A sparse `NodeProps` holding `settings` on the settings node.
    static func values(_ build: (inout Wiretuner_Doc_V1_TextSettings) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        SettingsFields.values { build(&$0.textSettings) }
    }
}

/// One word the conversions it names leave as spelled here (`CaseException`).
public struct CaseExceptionInfo: Hashable, Sendable {
    /// The element; nil for one `SetTextCaseSettings` is to add.
    public var id: OpID?
    public var word: String
    /// The conversions that keep the word's spelling.
    public var conversions: Set<CaseConversion>

    public init(id: OpID? = nil, word: String, conversions: Set<CaseConversion>) {
        self.id = id
        self.word = word
        self.conversions = conversions
    }

    init(_ stored: Wiretuner_Doc_V1_CaseException) {
        id = OpID(element: stored.id)
        word = stored.word
        var conversions: Set<CaseConversion> = []
        if stored.uppercase { conversions.insert(.uppercase) }
        if stored.lowercase { conversions.insert(.lowercase) }
        if stored.smallCaps { conversions.insert(.smallCaps) }
        if stored.title { conversions.insert(.title) }
        if stored.sentence { conversions.insert(.sentence) }
        self.conversions = conversions
    }

    var stored: Wiretuner_Doc_V1_CaseException {
        var value = Wiretuner_Doc_V1_CaseException()
        value.word = word
        value.uppercase = conversions.contains(.uppercase)
        value.lowercase = conversions.contains(.lowercase)
        value.smallCaps = conversions.contains(.smallCaps)
        value.title = conversions.contains(.title)
        value.sentence = conversions.contains(.sentence)
        return value
    }
}

/// The document's Convert Case settings as the Settings sheet shows them.
public struct TextCaseSettings: Hashable, Sendable {
    /// Small capitals' size, percent of the type size.
    public var smallCapsPercent: Double
    /// The exceptions, in the sheet's order.
    public var exceptions: [CaseExceptionInfo]

    public init(smallCapsPercent: Double = TextSettingsFields.defaultSmallCapsPercent, exceptions: [CaseExceptionInfo] = []) {
        self.smallCapsPercent = smallCapsPercent
        self.exceptions = exceptions
    }

    /// The merged settings of `state`: an unset (0) size reads as 75.
    public init(_ state: EngineState) {
        let stored = state.props(WellKnown.settings).settings.textSettings
        smallCapsPercent = stored.smallCapsPercent > 0 ? min(stored.smallCapsPercent, 100) : TextSettingsFields.defaultSmallCapsPercent
        exceptions = stored.caseExceptions.map(CaseExceptionInfo.init)
    }

    /// The exceptions of `conversion`: each excepted word's scalars keyed by its lowercased form.
    func excepted(_ conversion: CaseConversion) -> [String: [Unicode.Scalar]] {
        var result: [String: [Unicode.Scalar]] = [:]
        for exception in exceptions where exception.conversions.contains(conversion) && !exception.word.isEmpty {
            result[exception.word.lowercased()] = Array(exception.word.unicodeScalars)
        }
        return result
    }
}

/// Writes the Convert Case settings (the Settings sheet's btn:[OK]): the size when it changed,
/// and the exceptions list diffed against the merged one -- an `ElementInsert` for each new
/// exception (at the end), register writes for each edited one and an `ElementDelete` for each
/// one left out.  One change, "Convert Case Settings".
public struct SetTextCaseSettings: Command {
    public var settings: TextCaseSettings
    public var label: String { "Convert Case Settings" }

    public init(_ settings: TextCaseSettings) {
        self.settings = settings
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard settings.smallCapsPercent > 0, settings.smallCapsPercent <= 100 else { throw TextEditError.invalidValue("smallCapsPercent") }
        guard settings.exceptions.allSatisfy({ !$0.word.isEmpty && $0.word.unicodeScalars.count <= 256 }) else {
            throw TextEditError.invalidValue("word")
        }
        let current = TextCaseSettings(state)
        if settings.smallCapsPercent != current.smallCapsPercent {
            builder.append(Ops.set(WellKnown.settings, [TextSettingsFields.smallCapsPercent],
                                   values: TextSettingsFields.values { $0.smallCapsPercent = settings.smallCapsPercent }))
        }
        var byID: [OpID: CaseExceptionInfo] = [:]
        for exception in current.exceptions {
            if let id = exception.id { byID[id] = exception }
        }
        let kept = Set(settings.exceptions.compactMap(\.id))
        let removed = current.exceptions.compactMap(\.id).filter { !kept.contains($0) }
        if !removed.isEmpty {
            builder.append(Ops.elementDelete(WellKnown.settings, removed.map { TextSettingsFields.exceptions.element($0) }))
        }
        for exception in settings.exceptions {
            guard let id = exception.id else { continue }
            guard let old = byID[id] else { throw TextEditError.invalidValue("exception") }
            let fields = Self.changedFields(old.stored, exception.stored)
            guard !fields.isEmpty else { continue }
            var element = exception.stored
            element.id = id.elementID
            builder.append(Ops.set(WellKnown.settings, fields.map { TextSettingsFields.exception(id, $0) },
                                   values: TextSettingsFields.values { $0.caseExceptions = [element] }))
        }
        let added = settings.exceptions.filter { $0.id == nil }
        guard !added.isEmpty else { return }
        let path = TextSettingsFields.exceptions
        let last = state.store.elementOrder(WellKnown.settings, path).last.flatMap { state.position(WellKnown.settings, path, $0) }
        let keys = try PathEditing.keys(between: last, and: nil, count: added.count)
        builder.append(Ops.elementInsert(WellKnown.settings, path, positions: keys,
                                         values: TextSettingsFields.values { $0.caseExceptions = added.map(\.stored) }))
    }

    /// The `CaseException` fields whose values differ.
    static func changedFields(_ a: Wiretuner_Doc_V1_CaseException, _ b: Wiretuner_Doc_V1_CaseException) -> [UInt32] {
        var fields: [UInt32] = []
        if a.word != b.word { fields.append(2) }
        if a.uppercase != b.uppercase { fields.append(3) }
        if a.lowercase != b.lowercase { fields.append(4) }
        if a.smallCaps != b.smallCaps { fields.append(5) }
        if a.title != b.title { fields.append(6) }
        if a.sentence != b.sentence { fields.append(7) }
        return fields
    }
}

/// Converts the case of the live characters between two anchors (menu:Text[Convert Case]).
/// Uppercase, Lowercase, Title and Sentence rewrite only what changes: per maximal run of
/// characters whose case changes, one `TextDelete` of the run and one `TextInsert` of its new
/// spelling with `left_origin` the live character before the run and `right_origin` the run's
/// first character, so the new characters sort before the tombstones and a collaborator's
/// concurrent insert inside the run survives after them.  The characters' formatting is carried
/// over: for every attribute on the run, on the character before it or anchored in it, a mark
/// carrying each old character's winning value (or the cleared value) covers its new characters,
/// so marks anchored inside the run are re-applied and a mark ending just before the run does not
/// spread over it.  Small Caps writes a `case` mark instead (removing it when every letter already
/// has it).  Words on the exceptions list for the conversion keep their spelling (a word matching
/// an exception without regard to case takes the exception's spelling, letter for letter), and
/// Small Caps leaves them drawn as typed.  One change, "Convert case".
public struct ConvertCase: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var conversion: CaseConversion
    public var label: String { "Convert case" }

    public init(node: OpID, from start: Anchor, to end: Anchor, conversion: CaseConversion) {
        self.node = node
        self.start = start
        self.end = end
        self.conversion = conversion
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        let range = try text.range(start, end)
        guard !range.isEmpty else { return }
        let scalars = Array(text.string.unicodeScalars)
        let excepted = TextCaseSettings(state).excepted(conversion)
        if conversion == .smallCaps {
            smallCaps(text, scalars: scalars, range: range, excepted: excepted, builder: &builder)
            return
        }
        let targets = CaseConverting.targets(scalars, range: range, conversion: conversion, excepted: excepted)
        for run in CaseConverting.changedRuns(scalars, targets: targets, range: range) {
            rewrite(run, targets: targets, in: text, builder: &builder)
        }
    }

    /// The `case` mark over the letters outside excepted words, or its removal.
    private func smallCaps(_ text: TextNode, scalars: [Unicode.Scalar], range: Range<Int>, excepted: [String: [Unicode.Scalar]],
                           builder: inout ChangeBuilder) {
        let skipped = CaseConverting.exceptedOffsets(scalars, range: range, excepted: excepted)
        let letters = range.filter { !skipped.contains($0) && scalars[$0].properties.isAlphabetic }
        let all = !letters.isEmpty && letters.allSatisfy { offset in
            text.values(at: offset).contains { if case .case(.smallCaps)? = $0.value { true } else { false } }
        }
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.case = all ? .unspecified : .smallCaps
        var spans: [Range<Int>] = []
        for offset in range where all || !skipped.contains(offset) {
            if let last = spans.last, last.upperBound == offset {
                spans[spans.count - 1] = last.lowerBound..<offset + 1
            } else {
                spans.append(offset..<offset + 1)
            }
        }
        for span in spans {
            let next = text.sequence.successor(of: text.chars[span.upperBound - 1])
            builder.append(TextEditing.mark(node, value, first: text.chars[span.lowerBound], last: text.chars[span.upperBound - 1], next: next))
        }
    }

    /// The delete and insert of one changed run, and the marks carrying its formatting.
    private func rewrite(_ run: Range<Int>, targets: [Int: [Unicode.Scalar]], in text: TextNode, builder: inout ChangeBuilder) {
        let old = Array(text.chars[run])
        var spelling = String.UnicodeScalarView()
        var owners: [Int] = []
        for offset in run {
            let scalars = targets[offset]!
            spelling.append(contentsOf: scalars)
            owners.append(contentsOf: repeatElement(offset, count: scalars.count))
        }
        for op in TextEditing.deletes(node, old) {
            builder.append(op)
        }
        let left = run.lowerBound > 0 ? text.chars[run.lowerBound - 1] : .zero
        // A case mapping is never empty, so the run has new characters.
        let first = builder.append(Ops.textInsert(node, TextFields.text, String(spelling), left: left, right: old[0]))
        let ids = owners.indices.map { OpID(counter: first.counter + UInt64($0), replica: first.replica) }
        let formatting = CaseConverting.formatting(text, run: run)
        for (key, sample) in formatting.keys {
            let cleared = TextMarks.cleared(sample)
            // Consecutive new characters whose old characters had the same value share one mark.
            var index = 0
            while index < ids.count {
                let value = formatting.values[owners[index]]?[key] ?? cleared
                var stop = index + 1
                while stop < ids.count, (formatting.values[owners[stop]]?[key] ?? cleared) == value { stop += 1 }
                let next = stop < ids.count ? ids[stop] : old[0]
                builder.append(TextEditing.mark(node, value, first: ids[index], last: ids[stop - 1], next: next))
                index = stop
            }
        }
    }
}

/// The case arithmetic of Convert Case.
enum CaseConverting {
    /// Whether a scalar belongs to a word: letters, digits, combining marks and apostrophes.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isAlphabetic || properties.numericType != nil || properties.generalCategory == .nonspacingMark
            || scalar == "'" || scalar == "\u{2019}"
    }

    /// The word around each offset of `range` that touches one: its full extent in `scalars`.
    static func words(_ scalars: [Unicode.Scalar], range: Range<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard isWordScalar(scalars[offset]) else {
                offset += 1
                continue
            }
            var lower = offset
            while lower > 0, isWordScalar(scalars[lower - 1]) { lower -= 1 }
            var upper = offset
            while upper < scalars.count, isWordScalar(scalars[upper]) { upper += 1 }
            result.append(lower..<upper)
            offset = upper
        }
        return result
    }

    /// The exception spelling of each excepted word touching `range`, by offset.
    static func exceptions(_ scalars: [Unicode.Scalar], range: Range<Int>, excepted: [String: [Unicode.Scalar]]) -> [Int: Unicode.Scalar] {
        guard !excepted.isEmpty else { return [:] }
        var result: [Int: Unicode.Scalar] = [:]
        for word in words(scalars, range: range) {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[word])
            guard let spelling = excepted[String(view).lowercased()], spelling.count == word.count else { continue }
            for (offset, scalar) in zip(word, spelling) { result[offset] = scalar }
        }
        return result
    }

    /// The offsets of `range` inside excepted words.
    static func exceptedOffsets(_ scalars: [Unicode.Scalar], range: Range<Int>, excepted: [String: [Unicode.Scalar]]) -> Set<Int> {
        Set(exceptions(scalars, range: range, excepted: excepted).keys)
    }

    /// The new spelling of every offset of `range` under `conversion` (not Small Caps).
    static func targets(_ scalars: [Unicode.Scalar], range: Range<Int>, conversion: CaseConversion,
                        excepted: [String: [Unicode.Scalar]]) -> [Int: [Unicode.Scalar]] {
        let kept = exceptions(scalars, range: range, excepted: excepted)
        let initials: Set<Int> = switch conversion {
        case .title: wordInitials(scalars, range: range)
        case .sentence: sentenceInitials(scalars, range: range)
        default: []
        }
        var result: [Int: [Unicode.Scalar]] = [:]
        for offset in range {
            if let scalar = kept[offset] {
                result[offset] = [scalar]
                continue
            }
            let scalar = scalars[offset]
            let mapped: String = switch conversion {
            case .uppercase: scalar.properties.uppercaseMapping
            case .title, .sentence: initials.contains(offset) ? scalar.properties.titlecaseMapping : scalar.properties.lowercaseMapping
            default: scalar.properties.lowercaseMapping
            }
            result[offset] = Array(mapped.unicodeScalars)
        }
        return result
    }

    /// The offsets of `range` holding the first letter of a word.
    static func wordInitials(_ scalars: [Unicode.Scalar], range: Range<Int>) -> Set<Int> {
        Set(range.filter { offset in
            scalars[offset].properties.isAlphabetic && (offset == 0 || !isWordScalar(scalars[offset - 1]))
        })
    }

    /// The offsets of `range` holding the first letter of a sentence: after the start of the text,
    /// a paragraph or line end, or a `.`, `!` or `?` followed by white space (closing quotes and
    /// brackets between them are passed over); a digit starts a sentence without a capital.
    static func sentenceInitials(_ scalars: [Unicode.Scalar], range: Range<Int>) -> Set<Int> {
        var result: Set<Int> = []
        var atStart = true
        var ended = false
        for offset in 0..<range.upperBound {
            let scalar = scalars[offset]
            let properties = scalar.properties
            if scalar == "\n" || scalar == "\u{2028}" || scalar == "\u{0C}" {
                atStart = true
                ended = false
            } else if properties.isAlphabetic || properties.numericType != nil {
                if atStart && properties.isAlphabetic && range.contains(offset) { result.insert(offset) }
                atStart = false
                ended = false
            } else if scalar == "." || scalar == "!" || scalar == "?" {
                ended = true
            } else if properties.isWhitespace, ended {
                atStart = true
                ended = false
            }
        }
        return result
    }

    /// The maximal runs of offsets whose spelling changes.
    static func changedRuns(_ scalars: [Unicode.Scalar], targets: [Int: [Unicode.Scalar]], range: Range<Int>) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for offset in range where targets[offset] != [scalars[offset]] {
            if let last = runs.last, last.upperBound == offset {
                runs[runs.count - 1] = last.lowerBound..<offset + 1
            } else {
                runs.append(offset..<offset + 1)
            }
        }
        return runs
    }

    /// What formatting a rewritten run carries: every attribute winning on the run or on the
    /// character before it, or of a mark anchored on one of the run's characters or ending just
    /// before it -- with a value of the attribute to clear it from -- and each run character's
    /// winning value of each.
    static func formatting(_ text: TextNode, run: Range<Int>) -> (keys: [(MarkKey, Wiretuner_Doc_V1_TextMarkValue)],
                                                                 values: [Int: [MarkKey: Wiretuner_Doc_V1_TextMarkValue]]) {
        var samples: [MarkKey: Wiretuner_Doc_V1_TextMarkValue] = [:]
        var values: [Int: [MarkKey: Wiretuner_Doc_V1_TextMarkValue]] = [:]
        let before = run.lowerBound - 1
        for engineRun in text.sequence.runs {
            let span = engineRun.start..<engineRun.start + engineRun.length
            guard span.overlaps(run) || span.contains(before) else { continue }
            for attribute in engineRun.attributes {
                guard let value = try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: attribute.value) else { continue }
                let key = attribute.key
                samples[key] = samples[key] ?? value
                for offset in span.clamped(to: run) { values[offset, default: [:]][key] = value }
            }
        }
        let ids = Set(text.chars[run])
        for mark in text.sequence.sortedMarks {
            let anchored = ids.contains(mark.start.char) || ids.contains(mark.end.char)
                || (mark.end.before && mark.end.char == text.chars[run.lowerBound])
            guard anchored, let key = mark.key, samples[key] == nil,
                  let value = try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: mark.value) else { continue }
            samples[key] = value
        }
        return (samples.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, values)
    }
}
