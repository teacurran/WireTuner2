// FONT-025 (rest): a font's layout read back into a typeface (font-export.adoc, "Opening an
// existing font"): what the generator owns goes into the model, the rest into the feature file.
// *Kerning* stays `GPOSReader`'s (pair lookups under `kern`).  *Mark attachment*: the mark-to-base
// lookups under `mark` and the mark-to-mark lookups under `mkmk` become anchors -- `_name` on each
// mark of a class, `name` on each glyph it attaches to -- one name per mark class (classes with the
// same marks at the same anchors share it), `top` for a class attaching above a quarter of the em,
// `bottom` below a tenth, else `anchor<n>` by class order.  *Ligatures*: a `liga` ligature rule whose
// glyph is named by its parts (`f_i` for `f i`) makes that glyph Ligature-kind, and the generator
// writes the rule again; other `liga` rules stay as text.  *GDEF*: the glyph classes give the kinds
// (base, ligature, mark, component); without a GDEF, marks of the attachment classes are Mark-kind.
// The mark attachment classes and mark glyph sets are written as named glyph classes (the feature
// file has no `MarkAttachmentType` or `UseMarkFilteringSet`, so a lookup using them loses the flag,
// and the report says so).  *Everything else* is decompiled into feature text: every lookup a
// remaining feature (or a contextual rule) uses becomes a named `lookup` block -- nested lookups
// first -- and every feature a block of `lookup` references, per script and language where the
// font's lists differ.  The text is checked with `FeatureChecker`; a lookup or feature it rejects is
// left out and reported, so the result always compiles.  What cannot be expressed (reverse chaining,
// cursive and mark-to-ligature attachment, values on a pair's second glyph, deletions, device
// tables) is listed in the report.

import Foundation

/// The typeface data a font's `GSUB`, `GPOS` and `GDEF` give beyond kerning.
struct FeatureDecompiler {
    /// Per glyph: anchors read from `mark`/`mkmk` (font units, y up).
    var anchors: [[FontSource.Anchor]]
    /// Per glyph: the kind GDEF (or the attachment and ligature rules) gives, nil when none.
    var kinds: [FontSource.GlyphKind?]
    /// The feature text of everything else; empty when nothing is left.
    var features = ""
    var report: [String] = []

    /// Largest text a single lookup may decompile to (a class-based context over a big font can
    /// enumerate thousands of glyphs per rule).
    static let lookupTextLimit = 256 * 1_024

    /// A lookup of either table.
    struct Key: Hashable, Comparable {
        var table: FeatureTableKind
        var index: Int

        static func < (a: Self, b: Self) -> Bool {
            (a.table == .gsub ? 0 : 1, a.index) < (b.table == .gsub ? 0 : 1, b.index)
        }
    }

    /// What a piece of the text belongs to (for leaving out what does not check).
    enum Owner: Hashable {
        case header, gdef, lookup(Key), feature(FeatureTableKind, String)
    }

    private let names: [String]
    private let unitsPerEm: Int
    private var tables: [FeatureTableKind: LayoutTable] = [:]
    private var decoded: [Key: [LayoutRules]] = [:]
    private var gdef = LayoutGDEF()
    /// Ligature rules of `liga` lookups that the generator writes again.
    private var absorbedLigatures: [Key: Set<LayoutRules.Ligature>] = [:]
    /// Lookups written whole, and lookups written with only the rules not absorbed.
    private var whole: Set<Key> = []
    private var partial: Set<Key> = []
    private var lookupNames: [Key: String] = [:]

    init(gsub: FontReader?, gpos: FontReader?, gdef gdefTable: FontReader?, names: [String], unitsPerEm: Int) {
        self.names = names
        self.unitsPerEm = unitsPerEm
        anchors = Array(repeating: [], count: names.count)
        kinds = Array(repeating: nil, count: names.count)
        for (kind, reader) in [(FeatureTableKind.gsub, gsub), (.gpos, gpos)] {
            guard let reader else { continue }
            do {
                let table = try LayoutTable(reader, kind: kind, glyphCount: names.count)
                tables[kind] = table
                for (index, lookup) in table.lookups.enumerated() {
                    decoded[Key(table: kind, index: index)] = (try? table.rules(lookup)) ?? [.unsupported("an unreadable lookup")]
                }
            } catch {
                report.append("The \(Self.name(kind)) table could not be read (\(error)); its features were not read.")
            }
        }
        if let gdefTable {
            do {
                gdef = try LayoutGDEF(gdefTable)
            } catch {
                report.append("The GDEF table could not be read (\(error)).")
            }
        }
        for (glyph, value) in gdef.glyphClasses where glyph < names.count {
            kinds[glyph] = [1: .base, 2: .ligature, 3: .mark, 4: .component][value]
        }
        for unread in gdef.unread { report.append("GDEF \(unread) were not read.") }
        absorbLigatures()
        absorbAttachment()
        plan()
        write()
    }

    static func name(_ table: FeatureTableKind) -> String {
        table == .gsub ? "GSUB" : "GPOS"
    }

    // MARK: Absorbed features

    /// The lookup type a feature's lookups of which go into the model.
    static func absorbedType(_ table: FeatureTableKind, _ tag: String) -> Int? {
        switch (table, tag) {
        case (.gpos, "kern"): 2
        case (.gpos, "mark"): 4
        case (.gpos, "mkmk"): 6
        case (.gsub, "liga"): 4
        default: nil
        }
    }

    /// The lookups `tag` uses in any language system, in index order.
    private func lookups(_ table: FeatureTableKind, _ tag: String) -> [Int] {
        guard let feature = tables[table]?.features.first(where: { $0.tag == tag }) else { return [] }
        return Array(Set(feature.systems.values.joined())).sorted()
    }

    /// The decoded subtables of `key` (none for a lookup the table does not have).
    private func decodedRules(_ key: Key) -> [LayoutRules] {
        decoded[key] ?? []
    }

    private func lookup(_ key: Key) -> LayoutTable.Lookup? {
        guard let table = tables[key.table], table.lookups.indices.contains(key.index) else { return nil }
        return table.lookups[key.index]
    }

    /// Whether the generator writes `rule` again: its glyph is named by its parts.
    private func isGenerated(_ rule: LayoutRules.Ligature) -> Bool {
        guard rule.components.count > 1, rule.glyph < names.count, rule.components.allSatisfy({ $0 < names.count }) else { return false }
        let name = names[rule.glyph]
        return !name.contains(".") && name.split(separator: "_", omittingEmptySubsequences: false).map(String.init) == rule.components.map { names[$0] }
    }

    private mutating func absorbLigatures() {
        var flagged = false
        for index in lookups(.gsub, "liga") {
            let key = Key(table: .gsub, index: index)
            guard let lookup = lookup(key), lookup.type == 4 else { continue }
            var absorbed: Set<LayoutRules.Ligature> = []
            for case .ligature(let rules) in decodedRules(key) {
                for rule in rules where isGenerated(rule) {
                    absorbed.insert(rule)
                    if kinds[rule.glyph] == nil || gdef.glyphClasses.isEmpty { kinds[rule.glyph] = .ligature }
                }
            }
            if !absorbed.isEmpty, lookup.flag != 0 { flagged = true }
            absorbedLigatures[key] = absorbed
        }
        if flagged { report.append("GSUB liga: the ligatures named by their parts are generated again, without their lookup flags.") }
    }

    /// A mark class: its marks and their anchors, sorted.
    private struct MarkClass: Hashable {
        var marks: [LayoutAttachment.Mark]
    }

    private mutating func absorbAttachment() {
        var order: [MarkClass] = []
        var heights: [MarkClass: [Int]] = [:]
        var uses: [(markClass: MarkClass, attachment: LayoutAttachment, index: Int)] = []
        let keys = (lookups(.gpos, "mark").filter { lookup(Key(table: .gpos, index: $0))?.type == 4 }
            + lookups(.gpos, "mkmk").filter { lookup(Key(table: .gpos, index: $0))?.type == 6 }).sorted()
        for index in Set(keys).sorted() {
            for case .attachment(let attachment) in decodedRules(Key(table: .gpos, index: index)) {
                for (classIndex, marks) in attachment.classes.enumerated() where !marks.isEmpty {
                    let markClass = MarkClass(marks: marks.sorted { ($0.glyph, $0.anchor.x, $0.anchor.y) < ($1.glyph, $1.anchor.x, $1.anchor.y) })
                    if heights[markClass] == nil { order.append(markClass) }
                    heights[markClass, default: []] += attachment.bases.compactMap { $0.anchors.indices.contains(classIndex) ? $0.anchors[classIndex]?.y : nil }
                    uses.append((markClass, attachment, classIndex))
                }
            }
        }
        // Names: top or bottom from where the class attaches, else anchor<n>.
        var classNames: [MarkClass: String] = [:]
        var taken: Set<String> = []
        for (position, markClass) in order.enumerated() {
            let ys = (heights[markClass]!.isEmpty ? markClass.marks.map(\.anchor.y) : heights[markClass]!).sorted()
            let median = Double(ys[ys.count / 2])
            var name = median > Double(unitsPerEm) * 0.25 ? "top" : median < Double(unitsPerEm) * 0.1 ? "bottom" : ""
            if name.isEmpty || taken.contains(name) { name = "anchor\(position + 1)" }
            taken.insert(name)
            classNames[markClass] = name
        }
        func add(_ glyph: Int, _ name: String, _ anchor: FeatureAnchor) {
            guard glyph < anchors.count, !anchors[glyph].contains(where: { $0.name == name }) else { return }
            anchors[glyph].append(FontSource.Anchor(name: name, x: Double(anchor.x), y: Double(anchor.y)))
        }
        for use in uses {
            let name = classNames[use.markClass]!
            for mark in use.markClass.marks {
                add(mark.glyph, "_" + name, mark.anchor)
                if gdef.glyphClasses.isEmpty, mark.glyph < kinds.count { kinds[mark.glyph] = .mark }
            }
            for base in use.attachment.bases where base.anchors.indices.contains(use.index) {
                if let anchor = base.anchors[use.index] { add(base.glyph, name, anchor) }
            }
        }
    }

    // MARK: What is written

    /// The rules of `key` as written: a partial lookup without its absorbed ligatures.
    private func rules(_ key: Key) -> [LayoutRules] {
        let all = decodedRules(key)
        guard partial.contains(key), !whole.contains(key), let absorbed = absorbedLigatures[key] else { return all }
        return all.map { rules in
            guard case .ligature(let list) = rules else { return rules }
            return .ligature(list.filter { !absorbed.contains($0) })
        }
    }

    /// Whether a `liga` lookup has ligature rules the generator does not write again.
    private func hasLeftover(_ key: Key) -> Bool {
        let absorbed = absorbedLigatures[key] ?? []
        return decodedRules(key).contains { rules in
            guard case .ligature(let list) = rules else { return false }
            return list.contains { !absorbed.contains($0) }
        }
    }

    /// Whether `rules` writes nothing.
    private static func isEmpty(_ rules: LayoutRules) -> Bool {
        switch rules {
        case .single(let list): list.isEmpty
        case .multiple(let list), .alternate(let list): list.isEmpty
        case .ligature(let list): list.isEmpty
        case .context(let list): list.isEmpty
        case .singlePosition(let list): list.isEmpty
        case .pairs(let list): list.isEmpty
        case .classPairs(let list): list.isEmpty
        case .attachment(let attachment): attachment.bases.isEmpty || attachment.classes.allSatisfy(\.isEmpty)
        case .unsupported: true
        }
    }

    /// Which lookups are written: those the remaining features use, and every lookup a written
    /// contextual rule applies.
    private mutating func plan() {
        var pending: [Key] = []
        for (kind, table) in tables {
            for feature in table.features {
                let absorbed = Self.absorbedType(kind, feature.tag)
                for index in Set(feature.systems.values.joined()).sorted() {
                    let key = Key(table: kind, index: index)
                    guard let lookup = lookup(key) else { continue }
                    if lookup.type == absorbed {
                        if kind == .gsub { partial.insert(key) }
                    } else {
                        pending.append(key)
                    }
                }
            }
        }
        while let key = pending.popLast() {
            guard lookup(key) != nil, whole.insert(key).inserted else { continue }
            for case .context(let list) in decodedRules(key) {
                pending += list.flatMap(\.records).map { Key(table: key.table, index: $0.lookup) }
            }
        }
        // Unsupported subtables, once per feature (or lookup) and kind.
        var seen: Set<String> = []
        for key in whole.union(partial).sorted() {
            let deletions = decodedRules(key).contains { rules in
                guard case .multiple(let list) = rules else { return false }
                return list.contains { $0.glyphs.isEmpty }
            }
            let unsupported = decodedRules(key).compactMap { rules -> String? in
                guard case .unsupported(let what) = rules else { return nil }
                return what
            } + (deletions ? ["a deletion (sub … by NULL)"] : [])
            for what in unsupported {
                let line = "\(place(key)): \(what) was not read."
                if seen.insert(line).inserted { report.append(line) }
            }
            if let lookup = lookup(key) {
                if lookup.flag & 0xFF00 != 0 {
                    report.append("\(place(key)): lookupflag MarkAttachmentType was dropped (not in the feature file).")
                }
                if lookup.flag & 0x10 != 0 {
                    report.append("\(place(key)): lookupflag UseMarkFilteringSet was dropped (not in the feature file).")
                }
            }
        }
        for kind in [FeatureTableKind.gsub, .gpos] {
            for tag in tables[kind]?.required ?? [] {
                report.append("\(Self.name(kind)) \(tag) is a required feature in the font; it is written as an ordinary feature.")
            }
        }
    }

    /// How the report names `key`: its table and first feature, or its index.
    private func place(_ key: Key) -> String {
        "\(Self.name(key.table)) \(usedBy(key).first ?? "lookup \(key.index)")"
    }

    /// The feature tags that use `key`, in FeatureList order.
    private func usedBy(_ key: Key) -> [String] {
        tables[key.table]!.features.filter { $0.systems.values.contains { $0.contains(key.index) } }.map(\.tag)
    }

    // MARK: Text

    private func glyph(_ id: Int) -> String {
        FeatureGenerator.glyph(names[id])
    }

    /// One glyph as a name, several (or a class wanted) in brackets.
    private func set(_ ids: [Int], bracketed: Bool = false) -> String {
        var seen: Set<Int> = []
        let unique = ids.filter { seen.insert($0).inserted }
        return unique.count == 1 && !bracketed ? glyph(unique[0]) : "[" + unique.map(glyph).joined(separator: " ") + "]"
    }

    private static func value(_ value: FeatureValue) -> String {
        value.xPlacement == 0 && value.yPlacement == 0 && value.yAdvance == 0
            ? "\(value.xAdvance)" : "<\(value.xPlacement) \(value.yPlacement) \(value.xAdvance) \(value.yAdvance)>"
    }

    private static func anchor(_ anchor: FeatureAnchor) -> String {
        "<anchor \(anchor.x) \(anchor.y)>"
    }

    private static func tag(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        let scalars = Array(trimmed.unicodeScalars)
        return !scalars.isEmpty && scalars.allSatisfy(FeatureLexer.nameBody.contains) ? trimmed : nil
    }

    /// Whether every glyph id of `rules` is in the font.
    private func inRange(_ ids: [Int]) -> Bool {
        ids.allSatisfy { $0 >= 0 && $0 < names.count }
    }

    /// The lines of a contextual rule, nil when it applies no lookup that is written (it had some).
    private func context(_ rule: LayoutContextRule, table: FeatureTableKind, written: Set<Key>) -> String? {
        guard !rule.input.isEmpty, (rule.backtrack + rule.input + rule.lookahead).allSatisfy({ !$0.isEmpty && inRange($0) }) else { return nil }
        let records = rule.records.filter { $0.sequence < rule.input.count && written.contains(Key(table: table, index: $0.lookup)) }
        guard records.count == rule.records.count || !records.isEmpty else { return nil }
        let keyword = table == .gsub ? "sub" : "pos"
        var parts = rule.backtrack.map { set($0) }
        for (position, input) in rule.input.enumerated() {
            let applied = records.filter { $0.sequence == position }.map { " lookup " + lookupNames[Key(table: table, index: $0.lookup)]! }
            parts.append(set(input) + "'" + applied.joined())
        }
        parts += rule.lookahead.map { set($0) }
        return (records.isEmpty ? "ignore \(keyword) " : "\(keyword) ") + parts.joined(separator: " ") + ";"
    }

    /// A lookup block (with the mark classes it needs before it), nil when it writes no rule.
    private func lookupText(_ key: Key, written: Set<Key>) -> String? {
        guard let lookup = lookup(key), let name = lookupNames[key] else { return nil }
        var before = ""
        var lines: [String] = []
        var lastClassPairs = false
        var markClassNames: [MarkClass: String] = [:]
        for rules in rules(key) where !Self.isEmpty(rules) {
            var classPairs = false
            switch rules {
            case .single(let list):
                lines += list.filter { inRange([$0.glyph, $0.replacement]) }.map { "sub \(glyph($0.glyph)) by \(glyph($0.replacement));" }
            case .multiple(let list):
                lines += list.filter { !$0.glyphs.isEmpty && inRange([$0.glyph] + $0.glyphs) }
                    .map { "sub \(glyph($0.glyph)) by \($0.glyphs.map(glyph).joined(separator: " "));" }
            case .alternate(let list):
                lines += list.filter { !$0.glyphs.isEmpty && inRange([$0.glyph] + $0.glyphs) }.map { "sub \(glyph($0.glyph)) from \(set($0.glyphs, bracketed: true));" }
            case .ligature(let list):
                lines += list.filter { inRange($0.components + [$0.glyph]) }
                    .map { "sub \($0.components.map(glyph).joined(separator: " ")) by \(glyph($0.glyph));" }
            case .context(let list):
                lines += list.compactMap { context($0, table: key.table, written: written) }
            case .singlePosition(let list):
                lines += list.filter { inRange([$0.glyph]) }.map { "pos \(glyph($0.glyph)) \(Self.value($0.value));" }
            case .pairs(let list):
                lines += list.filter { inRange([$0.first, $0.second]) }.map { "pos \(glyph($0.first)) \(glyph($0.second)) \(Self.value($0.value));" }
            case .classPairs(let list):
                if lastClassPairs { lines.append("subtable;") }
                lines += list.filter { inRange($0.first + $0.second) }
                    .map { "pos \(set($0.first, bracketed: true)) \(set($0.second, bracketed: true)) \(Self.value($0.value));" }
                classPairs = true
            case .attachment(let attachment):
                let keyword = lookup.type == 4 ? "base" : "mark"
                // A class with the same marks at the same anchors keeps its name across subtables.
                var classNames: [String?] = []
                for marks in attachment.classes {
                    let content = MarkClass(marks: marks.filter { inRange([$0.glyph]) }.sorted { ($0.glyph, $0.anchor.x, $0.anchor.y) < ($1.glyph, $1.anchor.x, $1.anchor.y) })
                    guard !content.marks.isEmpty else {
                        classNames.append(nil)
                        continue
                    }
                    if let existing = markClassNames[content] {
                        classNames.append(existing)
                        continue
                    }
                    let className = "@\(name)_\(markClassNames.count + 1)"
                    markClassNames[content] = className
                    classNames.append(className)
                    // One statement per anchor.
                    var byAnchor: [FeatureAnchor: [Int]] = [:]
                    var anchorOrder: [FeatureAnchor] = []
                    for mark in content.marks {
                        if byAnchor[mark.anchor] == nil { anchorOrder.append(mark.anchor) }
                        byAnchor[mark.anchor, default: []].append(mark.glyph)
                    }
                    for anchor in anchorOrder { before += "markClass \(set(byAnchor[anchor]!, bracketed: true)) \(Self.anchor(anchor)) \(className);\n" }
                }
                for base in attachment.bases where inRange([base.glyph]) {
                    let attached = base.anchors.enumerated().compactMap { index, anchor -> String? in
                        guard let anchor, classNames.indices.contains(index), let className = classNames[index] else { return nil }
                        return "\(Self.anchor(anchor)) mark \(className)"
                    }
                    if !attached.isEmpty { lines.append("pos \(keyword) \(glyph(base.glyph)) \(attached.joined(separator: " "));") }
                }
            case .unsupported:
                break
            }
            lastClassPairs = classPairs
        }
        guard !lines.isEmpty else { return nil }
        var text = before + "lookup \(name) {\n"
        if lookup.flag & 0xFF00 != 0 { text += "    # lookupflag MarkAttachmentType @MarkAttachmentClass\(lookup.flag >> 8); (dropped: not supported)\n" }
        if let set = lookup.markFilteringSet { text += "    # lookupflag UseMarkFilteringSet @MarkGlyphSet\(set); (dropped: not supported)\n" }
        let flags = [(1, "RightToLeft"), (2, "IgnoreBaseGlyphs"), (4, "IgnoreLigatures"), (8, "IgnoreMarks")].filter { lookup.flag & $0.0 != 0 }.map(\.1)
        if !flags.isEmpty { text += "    lookupflag \(flags.joined(separator: " "));\n" }
        text += lines.map { "    " + $0 + "\n" }.joined() + "} \(name);\n"
        return text.utf8.count > Self.lookupTextLimit ? nil : text
    }

    /// The written lookups in an order where a lookup comes after every lookup its rules apply.
    private func ordered(_ keys: Set<Key>) -> [Key] {
        var result: [Key] = []
        var done: Set<Key> = []
        var visiting: Set<Key> = []
        func visit(_ key: Key) {
            guard keys.contains(key), !done.contains(key), visiting.insert(key).inserted else { return }
            for case .context(let list) in rules(key) {
                for record in list.flatMap(\.records) { visit(Key(table: key.table, index: record.lookup)) }
            }
            visiting.remove(key)
            done.insert(key)
            result.append(key)
        }
        for key in keys.sorted() { visit(key) }
        return result
    }

    /// The text, leaving out `excluded`; each piece with its owner and first line.
    private mutating func text(excluding excluded: Set<Owner>) -> (text: String, pieces: [(owner: Owner, lines: Range<Int>)]) {
        // Names, then texts (contextual rules need the names, and a lookup is written only when
        // it has rules): repeated until the written set is stable.
        var written = whole.union(partial).filter { !excluded.contains(.lookup($0)) }
        var texts: [Key: String] = [:]
        while true {
            var counter = 0
            lookupNames = [:]
            for key in ordered(written) {
                counter += 1
                let tag = usedBy(key).compactMap(Self.tag).first.map(FeatureGenerator.identifier) ?? Self.name(key.table).lowercased()
                lookupNames[key] = "\(tag)_\(counter)"
            }
            texts = [:]
            for key in written { if let text = lookupText(key, written: written) { texts[key] = text } }
            let kept = written.filter { texts[$0] != nil }
            if kept == written { break }
            written = kept
        }
        // Features: per tag, the lookups each language system applies.
        let systems = Set(tables.values.flatMap(\.systems)).sorted()
        var featureTexts: [(owner: Owner, text: String)] = []
        for kind in [FeatureTableKind.gsub, .gpos] {
            for feature in tables[kind]?.features ?? [] {
                guard let tag = Self.tag(feature.tag), !excluded.contains(.feature(kind, feature.tag)) else { continue }
                let absorbed = Self.absorbedType(kind, feature.tag)
                var lists: [FeatureLanguageSystem: [String]] = [:]
                for (system, indices) in feature.systems {
                    lists[system] = indices.compactMap { index -> String? in
                        let key = Key(table: kind, index: index)
                        guard texts[key] != nil, let lookup = lookup(key) else { return nil }
                        // An absorbed lookup is referenced only for its rules that stay text.
                        if lookup.type == absorbed, !hasLeftover(key) { return nil }
                        return lookupNames[key]
                    }
                }
                lists = lists.filter { !$0.value.isEmpty }
                guard !lists.isEmpty else { continue }
                var body = ""
                if Set(lists.keys) == Set(systems), Set(lists.values).count == 1 {
                    body = lists.values.first!.map { "    lookup \($0);\n" }.joined()
                } else {
                    var script: String?
                    for system in lists.keys.sorted() {
                        guard let scriptTag = Self.tag(system.script), let languageTag = Self.tag(system.language) else { continue }
                        if script != scriptTag {
                            body += "    script \(scriptTag);\n"
                            script = scriptTag
                        }
                        if languageTag != "dflt" { body += "    language \(languageTag) exclude_dflt;\n" }
                        body += lists[system]!.map { "    lookup \($0);\n" }.joined()
                    }
                }
                featureTexts.append((.feature(kind, feature.tag), "feature \(tag) {\n" + body + "} \(tag);\n"))
            }
        }
        var pieces: [(owner: Owner, text: String)] = []
        let gdefText = classesText()
        if !gdefText.isEmpty, !excluded.contains(.gdef) { pieces.append((.gdef, gdefText)) }
        guard !featureTexts.isEmpty || !pieces.isEmpty else { return ("", []) }
        let header = "# Read from the font's layout tables.  Kerning, mark attachment (as anchors) and the ligatures\n"
            + "# named by their parts are generated from the glyphs; the rest is below.\n"
            + systems.compactMap { system in Self.tag(system.script).flatMap { s in Self.tag(system.language).map { "languagesystem \(s) \($0);\n" } } }.joined()
        pieces.insert((.header, header), at: 0)
        // Lookups in dependency order, then the features.
        for key in ordered(written) { pieces.append((.lookup(key), texts[key]!)) }
        pieces += featureTexts
        var result = ""
        var line = 1
        var spans: [(owner: Owner, lines: Range<Int>)] = []
        for piece in pieces {
            let count = piece.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            spans.append((piece.owner, line..<(line + count)))
            result += piece.text
            line += count
        }
        return (result, spans)
    }

    /// GDEF's mark attachment classes and mark glyph sets as named classes.
    private func classesText() -> String {
        var text = ""
        let classes = Set(gdef.markAttachmentClasses.values).sorted()
        if !classes.isEmpty {
            text += "# GDEF mark attachment classes (lookupflag MarkAttachmentType is not supported).\n"
            for value in classes {
                let members = gdef.markAttachmentClasses.filter { $0.value == value && $0.key < names.count }.map(\.key).sorted()
                if !members.isEmpty { text += "@MarkAttachmentClass\(value) = \(set(members, bracketed: true));\n" }
            }
        }
        if !gdef.markGlyphSets.isEmpty {
            text += "# GDEF mark glyph sets (lookupflag UseMarkFilteringSet is not supported).\n"
            for (index, members) in gdef.markGlyphSets.enumerated() {
                let kept = members.filter { $0 < names.count }
                if !kept.isEmpty { text += "@MarkGlyphSet\(index) = \(set(kept, bracketed: true));\n" }
            }
        }
        return text
    }

    /// Writes the text, leaving out whatever does not check.
    private mutating func write() {
        var excluded: Set<Owner> = []
        for _ in 0..<8 {
            let (text, pieces) = text(excluding: excluded)
            let errors = text.isEmpty ? [] : FeatureChecker.check(text, glyphs: names).errors
            guard !errors.isEmpty else {
                features = text
                return
            }
            // Each error's owner; a feature's errors wait while a lookup it uses has its own.
            let owned = errors.map { error in (error, pieces.first { $0.lines.contains(error.location.line) }?.owner) }
            guard owned.allSatisfy({ $0.1 != nil && $0.1 != .header && !excluded.contains($0.1!) }) else { break }
            let lookupsFail = owned.contains { if case .lookup = $0.1! { true } else { false } }
            var owners: [Owner] = []
            for (error, owner) in owned {
                guard let owner, !owners.contains(owner) else { continue }
                if lookupsFail, case .feature = owner { continue }
                owners.append(owner)
                let what = switch owner {
                case .lookup(let key): "\(place(key)): a lookup"
                case .feature(let table, let tag): "\(Self.name(table)) \(tag)"
                default: "GDEF's mark classes"
                }
                let message = error.message.hasSuffix(".") ? String(error.message.dropLast()) : error.message
                report.append("\(what) could not be written as feature text and was left out (\(message)).")
            }
            excluded.formUnion(owners)
        }
        features = ""
        report.append("The font's other layout features could not be written as feature text and were not read.")
    }
}
