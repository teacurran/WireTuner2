import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTText

/// Where the Find & Replace panel looks (find-replace.adoc: *Change in* / *Search in*).
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case selection, page, document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: "Selection"
        case .page: "Page"
        case .document: "Document"
        }
    }
}

/// The *Font* attribute's settings (type-specifications.adoc, "Finding and replacing type
/// attributes"; TYPE-022): a family (nil: *Any font*), a face (nil: *Any style*) and a size
/// range -- both ends empty for any size, only *Min* for one exact size.
struct FontCriteria: Equatable, Sendable {
    var family: String?
    var style: String?
    var minSize: Double?
    var maxSize: Double?

    init(family: String? = nil, style: String? = nil, minSize: Double? = nil, maxSize: Double? = nil) {
        self.family = family
        self.style = style
        self.minSize = minSize
        self.maxSize = maxSize
    }

    /// Whether a run with these winning marks matches.
    @MainActor func matches(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> Bool {
        if let family, ObjectPanelModel.family(values) != family { return false }
        if let style, ObjectPanelModel.style(values) != style { return false }
        let size = ObjectPanelModel.size(values)
        switch (minSize, maxSize) {
        case let (min?, nil): return abs(size - min) < 1e-6
        case let (min?, max?): return size >= min - 1e-6 && size <= max + 1e-6
        case let (nil, max?): return size <= max + 1e-6
        case (nil, nil): return true
        }
    }

    /// "Helvetica Bold 12–14 pt", "any font".
    var summary: String {
        var parts = [family ?? "any font"]
        if let style { parts.append(style) }
        switch (minSize, maxSize) {
        case let (min?, nil): parts.append("\(Self.points(min)) pt")
        case let (min?, max?): parts.append("\(Self.points(min))–\(Self.points(max)) pt")
        case let (nil, max?): parts.append("up to \(Self.points(max)) pt")
        case (nil, nil): break
        }
        return parts.joined(separator: " ")
    }

    static func points(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// The *To* side of a font replacement: each nil is *No change*.
struct FontReplacement: Equatable, Sendable {
    var family: String?
    var style: String?
    var size: Double?

    init(family: String? = nil, style: String? = nil, size: Double? = nil) {
        self.family = family
        self.style = style
        self.size = size
    }

    var isEmpty: Bool { family == nil && style == nil && (size == nil || !Self.validSize(size!)) }

    /// The mark values the replacement writes.
    var values: [Wiretuner_Doc_V1_TextMarkValue] {
        var result: [Wiretuner_Doc_V1_TextMarkValue] = []
        if let family, !family.isEmpty { result.append(.with { $0.fontFamily = family }) }
        if let style, !style.isEmpty { result.append(.with { $0.fontStyle = style }) }
        if let size, Self.validSize(size) { result.append(.with { $0.size = size }) }
        return result
    }

    static func validSize(_ size: Double) -> Bool { size.isFinite && size >= 0.1 && size <= 10_000 }

    var summary: String {
        var parts: [String] = []
        if let family { parts.append(family) }
        if let style { parts.append(style) }
        if let size { parts.append("\(FontCriteria.points(size)) pt") }
        return parts.joined(separator: " ")
    }
}

/// The *Text effect* attribute of the Select tab (text-effects.adoc; TYPE-037): any effect, or one.
enum EffectCriteria: Equatable, Sendable {
    case any
    case kind(TextEffectKind)

    func matches(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> Bool {
        let kind = TextEffectKind(TextEffectKind.effect(of: values))
        switch self {
        case .any: return kind != .none
        case .kind(let wanted): return kind == wanted
        }
    }
}

/// The type attribute queries of the Find & Replace panel: the text blocks in a scope whose runs
/// match, and the one change a font replacement writes.  Objects on hidden layers are not in the
/// scene and locked ones (or ones on locked layers) are skipped, so neither is ever found.
@MainActor
struct TypeAttributeSearch {
    let document: DocumentHandle
    /// The window's selection (the *Selection* scope).
    let selection: Selection

    /// The live text blocks `scope` covers, in draw order.
    func blocks(in scope: SearchScope) -> [OpID] {
        let scene = document.scene
        let selected = Set(selection.ids.map(\.opID))
        let page = document.currentPage
        return scene.objects.values
            .filter { $0.kind == .text && !$0.isEffectivelyLocked }
            .sorted { $0.itemPath.lexicographicallyPrecedes($1.itemPath) }
            .filter { object in
                switch scope {
                case .selection: return selected.contains(object.id)
                case .page: return page.map { page in bounds(of: object.id).map { $0.intersects(page) } ?? false } ?? true
                case .document: return true
                }
            }
            .map(\.id)
    }

    /// A text block's box in pasteboard space: its laid-out size through its transform chain.
    func bounds(of node: OpID) -> Rect? {
        guard let size = document.textLayout(for: node)?.sizes.first else { return nil }
        return Rect(x: 0, y: 0, width: max(size.width, 0), height: max(size.height, 0)).applying(Objects.pasteboardTransform(of: node, in: document.state))
    }

    /// The runs of block `node` that `matches` accepts (live offsets).
    func runs(of node: OpID, where matches: ([Wiretuner_Doc_V1_TextMarkValue]) -> Bool) -> [Range<Int>] {
        guard let text = document.state.textNode(node) else { return [] }
        if text.length == 0 { return matches([]) ? [0..<0] : [] }
        return text.runs.filter { matches($0.values) }.map(\.range)
    }

    /// The blocks in `scope` with at least one matching run.
    func find(in scope: SearchScope, where matches: ([Wiretuner_Doc_V1_TextMarkValue]) -> Bool) -> [OpID] {
        blocks(in: scope).filter { !runs(of: $0, where: matches).isEmpty }
    }

    /// btn:[Find]: the selection after finding `found` -- replacing it, added to it (*Add to
    /// selection*, page and document scopes) or taken from it (*Remove from selection*, the
    /// selection scope).
    static func selection(after found: [OpID], current: Selection, scope: SearchScope, adjust: Bool) -> Selection {
        let picked = found.map { SelectionID($0) }
        guard adjust else { return Selection(picked) }
        if scope == .selection {
            let removed = Set(picked)
            return Selection(current.ids.filter { !removed.contains($0) })
        }
        var ids = current.ids
        for id in picked where !ids.contains(id) { ids.append(id) }
        return Selection(ids)
    }

    /// btn:[Change] for *Font*: one change of `TextMark`s over every matched run of every block in
    /// `scope`, labelled "Replace font Helvetica → Inter (N blocks)", and the number of blocks it
    /// changes; nil when nothing matches or the *To* side changes nothing.
    func replaceFont(_ from: FontCriteria, with to: FontReplacement, in scope: SearchScope) -> (command: any WTModel.Command, blocks: Int)? {
        let values = to.values
        guard !values.isEmpty else { return nil }
        var commands: [any WTModel.Command] = []
        var changed = 0
        for node in blocks(in: scope) {
            guard let text = document.state.textNode(node), text.length > 0 else { continue }
            let ranges = text.runs.filter { from.matches($0.values) }.map(\.range)
            guard !ranges.isEmpty else { continue }
            changed += 1
            for range in ranges {
                let start = text.anchor(at: range.lowerBound), end = Anchor(char: text.chars[range.upperBound - 1], before: false)
                commands += values.map { ApplyMark(node: node, from: start, to: end, value: $0) }
            }
        }
        guard changed > 0 else { return nil }
        let label = "Replace font \(from.summary) → \(to.summary) (\(changed) \(changed == 1 ? "block" : "blocks"))"
        return (CommandBatch(label, commands), changed)
    }
}
