// FONT-019: the feature-file compiler (opentype-features.adoc, "Client": "Full compilation of the
// file is done by the font compiler"; decisions.adoc D-071 as amended).  The syntax tree of
// `FeatureParser` is resolved against the font's glyph names -- classes, ranges, mark classes,
// named lookups -- into lookups grouped by feature and language system, then written as `GSUB`,
// `GPOS` and `GDEF` by `FeatureTables`.  Rules follow the AFDKO compiler's conventions: rules of
// one type in a feature share an implicit lookup until the type, the lookup flag or the script
// changes; glyph pairs of a pair lookup go before its class pairs (so an exception wins);
// contextual rules with inline replacements get an anonymous lookup each; with no GDEF block,
// mark classes and `pos base` glyphs give the glyph classes.

/// The tables compiled from feature text, with every problem found.
public struct CompiledFeatures: Sendable {
    public var gsub: [UInt8]?
    public var gpos: [UInt8]?
    public var gdef: [UInt8]?
    public var issues: [FeatureIssue]
    /// The feature tags the text defines, in order of first definition.
    public var featureTags: [String]

    /// Whether nothing stops the compile.
    public var isClean: Bool { !issues.contains { $0.severity == .error } }
}

/// Which table a lookup belongs to.
enum FeatureTableKind: Hashable, Sendable {
    case gsub, gpos
}

/// A language system: script and language tags.
struct FeatureLanguageSystem: Hashable, Sendable, Comparable {
    var script: String
    var language: String

    static func < (a: Self, b: Self) -> Bool {
        (a.script, a.language == "dflt" ? "" : a.language) < (b.script, b.language == "dflt" ? "" : b.language)
    }
}

/// A compiled lookup.
struct FeatureLookup: Sendable {
    /// A contextual rule: coverage sets per position and the lookups applied.
    struct ChainRule: Sendable {
        var backtrack: [[Int]]
        var input: [[Int]]
        var lookahead: [[Int]]
        var records: [(sequence: Int, lookup: Int)]
    }

    /// A class-pair rule of a pair lookup.
    struct ClassPair: Sendable {
        var first: [Int]
        var second: [Int]
        var value: FeatureValue
    }

    /// Mark attachment: mark glyphs with their class and anchor, attaching glyphs with an anchor
    /// per class.
    struct Attachment: Sendable {
        var classes: [String] = []
        var marks: [Int: (mark: Int, anchor: FeatureAnchor)] = [:]
        var bases: [Int: [Int: FeatureAnchor]] = [:]
    }

    enum Body: Sendable {
        case single([Int: Int])
        case multiple([Int: [Int]])
        case alternate([Int: [Int]])
        case ligature([(components: [Int], glyph: Int)])
        case chain([ChainRule])
        case singlePosition([Int: FeatureValue])
        /// Glyph pairs, then class-pair segments (a `subtable` statement starts a segment).
        case pairPosition([Int: [Int: FeatureValue]], [[ClassPair]])
        case markToBase(Attachment)
        case markToMark(Attachment)
    }

    var table: FeatureTableKind
    /// The OpenType lookup type (GSUB 1-4 and 6; GPOS 1, 2, 4, 6 and 8).
    var type: Int
    var flag: Int
    var body: Body
}

/// Compiles feature text for a font.
public struct FeatureCompiler {
    private let glyphIDs: [String: Int]
    private let glyphNames: [String]
    private(set) var issues: [FeatureIssue] = []
    private var classes: [String: [Int]] = [:]
    private var markClasses: [String: [(glyph: Int, anchor: FeatureAnchor)]] = [:]
    private(set) var lookups: [FeatureTableKind: [FeatureLookup]] = [.gsub: [], .gpos: []]
    private var namedLookups: [String: (table: FeatureTableKind, index: Int)] = [:]
    private(set) var languageSystems: [FeatureLanguageSystem] = []
    /// Per feature tag (in order of definition), the lookups per language system per table.
    private(set) var features: [(tag: String, lookups: [FeatureLanguageSystem: [FeatureTableKind: [Int]]])] = []
    private(set) var glyphClassDefinition: [Int: Int]?
    private var inferredBases: Set<Int> = []
    private var usedMarkClasses: Set<String> = []

    /// Most glyph combinations a class-based ligature rule may expand to.
    static let expansionLimit = 10_000

    init(glyphs: [String]) {
        glyphNames = glyphs
        var ids: [String: Int] = [:]
        for (index, name) in glyphs.enumerated() where ids[name] == nil { ids[name] = index }
        glyphIDs = ids
    }

    /// Compiles `text` against the font's glyph names in glyph-id order.
    public static func compile(_ text: String, glyphs: [String]) -> CompiledFeatures {
        let parsed = FeatureParser.parse(text)
        var compiler = FeatureCompiler(glyphs: glyphs)
        compiler.issues = parsed.issues
        compiler.compile(parsed.statements)
        let tags = compiler.features.map(\.tag)
        guard compiler.issues.allSatisfy({ $0.severity != .error }) else {
            return CompiledFeatures(gsub: nil, gpos: nil, gdef: nil, issues: compiler.sortedIssues, featureTags: tags)
        }
        let systems = compiler.languageSystems.isEmpty ? [FeatureLanguageSystem(script: "DFLT", language: "dflt")] : compiler.languageSystems
        let gsub = FeatureTables.layoutTable(.gsub, lookups: compiler.lookups[.gsub]!, features: compiler.features, systems: systems)
        let gpos = FeatureTables.layoutTable(.gpos, lookups: compiler.lookups[.gpos]!, features: compiler.features, systems: systems)
        let gdef = compiler.gdefClasses.map(FeatureTables.gdef)
        return CompiledFeatures(gsub: gsub, gpos: gpos, gdef: gdef, issues: compiler.sortedIssues, featureTags: tags)
    }

    private var sortedIssues: [FeatureIssue] {
        issues.enumerated().sorted { ($0.element.location, $0.offset) < ($1.element.location, $1.offset) }.map(\.element)
    }

    /// The GDEF glyph classes: the text's block, else inferred from mark classes and bases.
    var gdefClasses: [Int: Int]? {
        if let glyphClassDefinition { return glyphClassDefinition.isEmpty ? nil : glyphClassDefinition }
        guard !usedMarkClasses.isEmpty else { return nil }
        var result: [Int: Int] = [:]
        for glyph in inferredBases { result[glyph] = 1 }
        for name in usedMarkClasses.sorted() {
            for entry in markClasses[name] ?? [] { result[entry.glyph] = 3 }
        }
        return result
    }

    private mutating func issue(_ severity: FeatureIssue.Severity, _ kind: FeatureIssue.Kind, _ message: String, at location: FeatureLocation,
                                name: String? = nil, suggestion: String? = nil) {
        issues.append(FeatureIssue(severity, kind, message, at: location, name: name, suggestion: suggestion))
    }

    /// An error.
    private mutating func issue(_ kind: FeatureIssue.Kind, _ message: String, at location: FeatureLocation,
                                name: String? = nil, suggestion: String? = nil) {
        issue(.error, kind, message, at: location, name: name, suggestion: suggestion)
    }

    // MARK: Glyphs

    /// The glyph ids of `glyphs` in written order (duplicates dropped), nil when a name does not
    /// resolve (reported).
    mutating func resolve(_ glyphs: FeatureGlyphs) -> [Int]? {
        var result: [Int] = []
        var seen: Set<Int> = []
        var failed = false
        func add(_ ids: [Int]) {
            for id in ids where seen.insert(id).inserted { result.append(id) }
        }
        for item in glyphs.items {
            switch item {
            case .glyph(let name, let location):
                if let id = glyphIDs[name] {
                    add([id])
                } else if name.contains("-"), let ids = range(name) {
                    add(ids)
                } else {
                    unknownGlyph(name, at: location)
                    failed = true
                }
            case .className(let name, let location):
                if let ids = classes[name] {
                    add(ids)
                } else if let marks = markClasses[name] {
                    add(marks.map(\.glyph))
                } else {
                    issue(.unknownName, "The class @\(name) is not defined (classes are defined before they are used).", at: location, name: "@\(name)")
                    failed = true
                }
            case .range(let first, let last, let location):
                if let ids = range(first, last, location: location) { add(ids) } else { failed = true }
            }
        }
        return failed ? nil : result
    }

    private mutating func unknownGlyph(_ name: String, at location: FeatureLocation) {
        let suggestion = FeatureChecker.nearestName(to: name, in: glyphNames)
        issue(.unknownGlyph, "The glyph \(name) is not in the font\(suggestion.map { " (did you mean \($0)?)" } ?? "").", at: location, name: name,
              suggestion: suggestion)
    }

    /// `a-z` written as one token: its range when the halves make one.
    private func range(_ token: String) -> [Int]? {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let names = Self.rangeNames(String(parts[0]), String(parts[1])) else { return nil }
        let ids = names.compactMap { glyphIDs[$0] }
        return ids.count == names.count ? ids : nil
    }

    /// `first - last`: every name between them, each required in the font.
    private mutating func range(_ first: String, _ last: String, location: FeatureLocation) -> [Int]? {
        guard let names = Self.rangeNames(first, last) else {
            issue(.syntax, "\(first) - \(last) is not a glyph range (names must differ in one letter or digit, in order).", at: location)
            return nil
        }
        var result: [Int] = []
        for name in names {
            guard let id = glyphIDs[name] else {
                unknownGlyph(name, at: location)
                return nil
            }
            result.append(id)
        }
        return result
    }

    /// The names of the range `first` ... `last`: equal but for one position holding letters of
    /// one case or digits, in ascending order.
    static func rangeNames(_ first: String, _ last: String) -> [String]? {
        let a = Array(first.unicodeScalars), b = Array(last.unicodeScalars)
        guard a.count == b.count, !a.isEmpty else { return nil }
        let differing = a.indices.filter { a[$0] != b[$0] }
        guard differing.count == 1, let position = differing.first else { return nil }
        let from = a[position], to = b[position]
        let sameClass = (from.properties.isUppercase && to.properties.isUppercase) || (from.properties.isLowercase && to.properties.isLowercase)
            || (("0"..."9").contains(from) && ("0"..."9").contains(to))
        guard sameClass, from.isASCII, to.isASCII, from.value < to.value else { return nil }
        return (from.value...to.value).map { value in
            var scalars = a
            scalars[position] = Unicode.Scalar(value)!
            return String(String.UnicodeScalarView(scalars))
        }
    }

    // MARK: Statements

    /// The state of the block being compiled.
    private struct Block {
        var tag: String?
        var flag = 0
        /// The implicit lookup rules go into, by table and index.
        var current: (table: FeatureTableKind, index: Int)?
        var targets: [FeatureLanguageSystem]
        var script: String?
        /// Lookups registered before any script statement (inherited by every language system).
        var defaults: [FeatureTableKind: [Int]] = [:]
        /// A named lookup block: its one lookup.
        var named: String?
    }

    mutating func compile(_ statements: [FeatureStatement]) {
        for statement in statements {
            switch statement {
            case .languageSystem(let script, let language, let location):
                let system = FeatureLanguageSystem(script: script, language: language)
                if languageSystems.contains(system) {
                    issue(.warning, .duplicate, "The language system \(script) \(language) is declared twice.", at: location)
                } else if !features.isEmpty {
                    issue(.syntax, "languagesystem statements come before the first feature.", at: location)
                } else {
                    languageSystems.append(system)
                }
            case .feature(let tag, let body, let location):
                featureBlock(tag, body, at: location)
            case .lookup(let name, let body, let location):
                var block = Block(tag: nil, targets: [])
                lookupBlock(name, body, at: location, in: &block)
            case .glyphClassDefinition(let sets, let location):
                var definition: [Int: Int] = [:]
                for (index, set) in sets.enumerated() {
                    guard let set, let ids = resolve(set) else { continue }
                    for id in ids { definition[id] = index + 1 }
                }
                if glyphClassDefinition != nil { issue(.warning, .duplicate, "GlyphClassDef is given twice; the later one is used.", at: location) }
                glyphClassDefinition = definition
            default:
                common(statement)
            }
        }
    }

    /// Class and mark class definitions, valid anywhere.
    private mutating func common(_ statement: FeatureStatement) {
        switch statement {
        case .classDefinition(let name, let glyphs, let location):
            if name.hasPrefix("kern1.") || name.hasPrefix("kern2.") {
                issue(.warning, .reservedPrefix, "Class names beginning kern1. or kern2. are reserved for generated kerning classes.", at: location,
                      name: "@\(name)")
            }
            if classes[name] != nil || markClasses[name] != nil { issue(.duplicate, "The class @\(name) is defined twice.", at: location, name: "@\(name)") }
            if let ids = resolve(glyphs) { classes[name] = ids }
        case .markClass(let glyphs, let anchor, let name, let location):
            if classes[name] != nil { issue(.duplicate, "@\(name) is already a glyph class.", at: location, name: "@\(name)") }
            if usedMarkClasses.contains(name) { issue(.invalidRule, "The mark class @\(name) is extended after it is used.", at: location, name: "@\(name)") }
            guard let ids = resolve(glyphs) else { return }
            markClasses[name, default: []] += ids.map { ($0, anchor) }
        default:
            // Other statements outside a block are rejected by the parser.
            break
        }
    }

    private mutating func featureBlock(_ tag: String, _ body: [FeatureStatement], at location: FeatureLocation) {
        let systems = languageSystems.isEmpty ? [FeatureLanguageSystem(script: "DFLT", language: "dflt")] : languageSystems
        if !features.contains(where: { $0.tag == tag }) { features.append((tag, [:])) }
        var block = Block(tag: tag, targets: systems)
        for statement in body {
            switch statement {
            case .script(let script, _):
                block.script = script
                block.current = nil
                let system = FeatureLanguageSystem(script: script, language: "dflt")
                inherit(system, from: block.defaults, tag: tag)
                block.targets = [system]
            case .language(let language, let exclude, let at):
                guard let script = block.script ?? (systems.count == 1 ? systems[0].script : nil) else {
                    issue(.syntax, "A language statement needs a script statement before it.", at: at)
                    continue
                }
                block.current = nil
                let system = FeatureLanguageSystem(script: script, language: language)
                if !exclude {
                    let inherited = featureLookups(tag)[FeatureLanguageSystem(script: script, language: "dflt")] ?? block.defaults
                    inherit(system, from: inherited, tag: tag)
                } else {
                    inherit(system, from: [:], tag: tag)
                }
                block.targets = [system]
            case .lookupFlag(let flag, _):
                block.flag = flag
                block.current = nil
            case .subtable(let at):
                subtableBreak(block, at: at)
            case .lookupReference(let name, let at):
                guard let found = namedLookups[name] else {
                    issue(.unknownName, "The lookup \(name) is not defined (lookups are defined before they are referenced).", at: at, name: name)
                    continue
                }
                register(found.table, found.index, in: &block)
                block.current = nil
            case .lookup(let name, let lookupBody, let at):
                var inner = Block(tag: tag, flag: block.flag, targets: block.targets, script: block.script)
                lookupBlock(name, lookupBody, at: at, in: &inner)
                if let found = namedLookups[name], inner.named == name { register(found.table, found.index, in: &block) }
                block.current = nil
            case .substitute(let rule):
                substitute(rule, in: &block)
            case .position(let rule):
                position(rule, in: &block)
            default:
                common(statement)
            }
        }
    }

    private func featureLookups(_ tag: String) -> [FeatureLanguageSystem: [FeatureTableKind: [Int]]] {
        features.first { $0.tag == tag }?.lookups ?? [:]
    }

    /// Gives `system` the lookups `inherited` unless it has its own already.
    private mutating func inherit(_ system: FeatureLanguageSystem, from inherited: [FeatureTableKind: [Int]], tag: String) {
        guard let position = features.firstIndex(where: { $0.tag == tag }), features[position].lookups[system] == nil else { return }
        features[position].lookups[system] = inherited
    }

    /// Adds a lookup to the feature for the block's targets.
    private mutating func register(_ table: FeatureTableKind, _ index: Int, in block: inout Block) {
        guard let tag = block.tag, block.named == nil || block.named == "", let position = features.firstIndex(where: { $0.tag == tag }) else { return }
        for system in block.targets {
            var entry = features[position].lookups[system] ?? [:]
            if !(entry[table]?.contains(index) ?? false) { entry[table, default: []].append(index) }
            features[position].lookups[system] = entry
        }
        if block.script == nil, !(block.defaults[table]?.contains(index) ?? false) { block.defaults[table, default: []].append(index) }
    }

    private mutating func lookupBlock(_ name: String, _ body: [FeatureStatement], at location: FeatureLocation, in block: inout Block) {
        if namedLookups[name] != nil {
            issue(.duplicate, "The lookup \(name) is defined twice.", at: location, name: name)
            return
        }
        block.named = name
        block.current = nil
        for statement in body {
            switch statement {
            case .lookupFlag(let flag, let at):
                if block.current != nil { issue(.invalidRule, "lookupflag must come before the rules of a lookup block.", at: at) }
                block.flag = flag
            case .subtable(let at):
                subtableBreak(block, at: at)
            case .substitute(let rule):
                substitute(rule, in: &block)
            case .position(let rule):
                position(rule, in: &block)
            case .classDefinition, .markClass:
                common(statement)
            default:
                issue(.syntax, "Only rules, lookupflag, subtable and class definitions belong in a lookup block.", at: location)
            }
        }
        if let current = block.current {
            namedLookups[name] = current
        } else {
            block.named = ""
            issue(.warning, .invalidRule, "The lookup \(name) has no rules.", at: location, name: name)
        }
    }

    /// `subtable;`: a new class-pair segment in the current pair lookup.
    private mutating func subtableBreak(_ block: Block, at location: FeatureLocation) {
        guard let current = block.current, case .pairPosition(let glyphs, var segments) = lookups[current.table]![current.index].body else { return }
        if segments.last?.isEmpty == false { segments.append([]) }
        lookups[current.table]![current.index].body = .pairPosition(glyphs, segments)
    }

    /// The lookup for a rule of `type`: the block's current one when it matches, else a new one
    /// registered with the block's feature.
    private mutating func lookup(_ table: FeatureTableKind, _ type: Int, empty: FeatureLookup.Body, in block: inout Block, at location: FeatureLocation) -> Int? {
        if let current = block.current, current.table == table, lookups[table]![current.index].type == type {
            return current.index
        }
        if block.current != nil, block.named != nil {
            issue(.invalidRule, "A lookup block holds rules of one type.", at: location)
            return nil
        }
        let index = lookups[table]!.count
        lookups[table]!.append(FeatureLookup(table: table, type: type, flag: block.flag, body: empty))
        block.current = (table, index)
        register(table, index, in: &block)
        return index
    }

    /// An anonymous lookup (a contextual rule's inline replacement).
    private mutating func anonymous(_ table: FeatureTableKind, _ type: Int, _ body: FeatureLookup.Body, flag: Int) -> Int {
        lookups[table]!.append(FeatureLookup(table: table, type: type, flag: flag, body: body))
        return lookups[table]!.count - 1
    }

    // MARK: Substitution

    private mutating func substitute(_ rule: FeatureSubstitution, in block: inout Block) {
        if rule.isContextual {
            contextualSubstitution(rule, in: &block)
            return
        }
        if let element = rule.elements.first(where: { !$0.lookups.isEmpty }) {
            issue(.syntax, "A lookup reference follows a marked glyph (').", at: element.glyphs.location)
            return
        }
        guard let inputs = resolveAll(rule.elements.map(\.glyphs)) else { return }
        if let alternates = rule.alternates {
            guard inputs.count == 1, let set = resolve(alternates) else {
                if inputs.count != 1 { issue(.invalidRule, "An alternate substitution replaces one glyph.", at: rule.location) }
                return
            }
            guard let index = lookup(.gsub, 3, empty: .alternate([:]), in: &block, at: rule.location),
                  case .alternate(var map) = lookups[.gsub]![index].body else { return }
            for glyph in inputs[0] where map[glyph] == nil { map[glyph] = set }
            lookups[.gsub]![index].body = .alternate(map)
            return
        }
        guard let replacement = resolveAll(rule.replacement) else { return }
        switch (inputs.count, replacement.count) {
        case (1, 1):
            guard let map = singleMap(inputs[0], replacement[0], at: rule.location),
                  let index = lookup(.gsub, 1, empty: .single([:]), in: &block, at: rule.location),
                  case .single(var existing) = lookups[.gsub]![index].body else { return }
            addSingle(map, to: &existing, at: rule.location)
            lookups[.gsub]![index].body = .single(existing)
        case (1, _):
            guard let sequence = singles(replacement, at: rule.location), let index = lookup(.gsub, 2, empty: .multiple([:]), in: &block, at: rule.location),
                  case .multiple(var map) = lookups[.gsub]![index].body else { return }
            for glyph in inputs[0] where map[glyph] == nil { map[glyph] = sequence }
            lookups[.gsub]![index].body = .multiple(map)
        case (_, 1):
            guard let ligatures = ligatures(inputs, replacement[0], at: rule.location),
                  let index = lookup(.gsub, 4, empty: .ligature([]), in: &block, at: rule.location),
                  case .ligature(var existing) = lookups[.gsub]![index].body else { return }
            existing += ligatures
            lookups[.gsub]![index].body = .ligature(existing)
        default:
            issue(.unsupported, "Many-to-many substitutions are not supported.", at: rule.location)
        }
    }

    private mutating func resolveAll(_ sets: [FeatureGlyphs]) -> [[Int]]? {
        var result: [[Int]] = []
        var failed = false
        for set in sets {
            if let ids = resolve(set) { result.append(ids) } else { failed = true }
        }
        return failed ? nil : result
    }

    /// Input → replacement pairs of a single substitution: one-to-one class mapping, or every
    /// input to one glyph.
    private mutating func singleMap(_ input: [Int], _ replacement: [Int], at location: FeatureLocation) -> [(Int, Int)]? {
        if replacement.count == 1 { return input.map { ($0, replacement[0]) } }
        guard input.count == replacement.count else {
            issue(.invalidRule, "The classes of a single substitution differ in size (\(input.count) and \(replacement.count)).", at: location)
            return nil
        }
        return Array(zip(input, replacement))
    }

    private mutating func addSingle(_ pairs: [(Int, Int)], to map: inout [Int: Int], at location: FeatureLocation) {
        for (from, to) in pairs {
            if let existing = map[from] {
                if existing != to {
                    issue(.warning, .duplicate, "\(glyphNames[from]) is already substituted in this lookup; the rule for it here is ignored.", at: location)
                }
            } else {
                map[from] = to
            }
        }
    }

    /// Each replacement a single glyph (multiple substitution).
    private mutating func singles(_ sets: [[Int]], at location: FeatureLocation) -> [Int]? {
        guard sets.allSatisfy({ $0.count == 1 }) else {
            issue(.invalidRule, "The replacement of a multiple substitution is a sequence of single glyphs.", at: location)
            return nil
        }
        return sets.map { $0[0] }
    }

    /// Every component combination of a ligature rule.
    private mutating func ligatures(_ inputs: [[Int]], _ replacement: [Int], at location: FeatureLocation) -> [(components: [Int], glyph: Int)]? {
        guard replacement.count == 1 else {
            issue(.invalidRule, "A ligature substitution replaces a sequence by one glyph.", at: location)
            return nil
        }
        let total = inputs.reduce(1) { $0 * $1.count }
        guard total <= Self.expansionLimit else {
            issue(.invalidRule, "The ligature rule expands to \(total) sequences (at most \(Self.expansionLimit)).", at: location)
            return nil
        }
        var sequences: [[Int]] = [[]]
        for set in inputs {
            sequences = sequences.flatMap { prefix in set.map { prefix + [$0] } }
        }
        return sequences.map { ($0, replacement[0]) }
    }

    /// Splits a contextual rule into backtrack, input and lookahead; nil when the marked glyphs
    /// are not one run.
    private mutating func context(_ elements: [FeatureElement], at location: FeatureLocation)
        -> (backtrack: [FeatureElement], input: [FeatureElement], lookahead: [FeatureElement])? {
        guard let first = elements.firstIndex(where: \.marked), let last = elements.lastIndex(where: \.marked),
              elements[first...last].allSatisfy(\.marked) else {
            issue(.syntax, "The marked glyphs (') of a contextual rule must be consecutive.", at: location)
            return nil
        }
        if elements.contains(where: { !$0.marked && (!$0.lookups.isEmpty || $0.value != nil) }) {
            issue(.syntax, "Lookups and values in a contextual rule follow marked glyphs.", at: location)
            return nil
        }
        return (Array(elements[..<first]), Array(elements[first...last]), Array(elements[(last + 1)...]))
    }

    private mutating func chainRule(_ parts: (backtrack: [FeatureElement], input: [FeatureElement], lookahead: [FeatureElement]),
                                    table: FeatureTableKind, at location: FeatureLocation) -> FeatureLookup.ChainRule? {
        guard let backtrack = resolveAll(parts.backtrack.map(\.glyphs)), let input = resolveAll(parts.input.map(\.glyphs)),
              let lookahead = resolveAll(parts.lookahead.map(\.glyphs)) else { return nil }
        var records: [(Int, Int)] = []
        for (position, element) in parts.input.enumerated() {
            for name in element.lookups {
                guard let found = namedLookups[name] else {
                    issue(.unknownName, "The lookup \(name) is not defined (lookups are defined before they are referenced).", at: location, name: name)
                    return nil
                }
                guard found.table == table else {
                    issue(.invalidRule, "The lookup \(name) is a \(found.table == .gsub ? "substitution" : "positioning") lookup.", at: location, name: name)
                    return nil
                }
                records.append((position, found.index))
            }
        }
        return FeatureLookup.ChainRule(backtrack: backtrack, input: input, lookahead: lookahead, records: records)
    }

    private mutating func addChain(_ rule: FeatureLookup.ChainRule, table: FeatureTableKind, in block: inout Block, at location: FeatureLocation) {
        guard let index = lookup(table, table == .gsub ? 6 : 8, empty: .chain([]), in: &block, at: location),
              case .chain(var rules) = lookups[table]![index].body else { return }
        rules.append(rule)
        lookups[table]![index].body = .chain(rules)
    }

    private mutating func contextualSubstitution(_ rule: FeatureSubstitution, in block: inout Block) {
        guard let parts = context(rule.elements, at: rule.location), var chain = chainRule(parts, table: .gsub, at: rule.location) else { return }
        let hasLookups = parts.input.contains { !$0.lookups.isEmpty }
        if !rule.ignore, !hasLookups {
            // An inline replacement: an anonymous lookup applied at the first marked glyph.
            let flag = block.flag
            if let alternates = rule.alternates {
                guard chain.input.count == 1, let set = resolve(alternates) else {
                    if chain.input.count != 1 { issue(.invalidRule, "An alternate substitution replaces one glyph.", at: rule.location) }
                    return
                }
                chain.records = [(0, anonymous(.gsub, 3, .alternate(Dictionary(chain.input[0].map { ($0, set) }) { a, _ in a }), flag: flag))]
            } else {
                guard let replacement = resolveAll(rule.replacement) else { return }
                switch (chain.input.count, replacement.count) {
                case (1, 1):
                    guard let pairs = singleMap(chain.input[0], replacement[0], at: rule.location) else { return }
                    var map: [Int: Int] = [:]
                    addSingle(pairs, to: &map, at: rule.location)
                    chain.records = [(0, anonymous(.gsub, 1, .single(map), flag: flag))]
                case (1, _):
                    guard let sequence = singles(replacement, at: rule.location) else { return }
                    chain.records = [(0, anonymous(.gsub, 2, .multiple(Dictionary(chain.input[0].map { ($0, sequence) }) { a, _ in a }), flag: flag))]
                case (_, 1):
                    guard let ligatures = ligatures(chain.input, replacement[0], at: rule.location) else { return }
                    chain.records = [(0, anonymous(.gsub, 4, .ligature(ligatures), flag: flag))]
                default:
                    issue(.unsupported, "Many-to-many substitutions are not supported.", at: rule.location)
                    return
                }
            }
        } else if hasLookups && (!rule.replacement.isEmpty || rule.alternates != nil) {
            issue(.syntax, "A contextual rule uses either lookups or an inline replacement, not both.", at: rule.location)
            return
        }
        addChain(chain, table: .gsub, in: &block, at: rule.location)
    }

    // MARK: Positioning

    private mutating func position(_ rule: FeaturePosition, in block: inout Block) {
        switch rule.kind {
        case .markToBase(let glyphs, let attachments):
            attachment(glyphs, attachments, type: 4, in: &block, at: rule.location)
        case .markToMark(let glyphs, let attachments):
            attachment(glyphs, attachments, type: 6, in: &block, at: rule.location)
        case .sequence(let enumerated):
            if rule.isContextual {
                contextualPosition(rule, in: &block)
            } else if rule.elements.count == 1 {
                guard let value = rule.elements[0].value else {
                    issue(.syntax, "Expected a value after the glyph.", at: rule.location)
                    return
                }
                guard let glyphs = resolve(rule.elements[0].glyphs), let index = lookup(.gpos, 1, empty: .singlePosition([:]), in: &block, at: rule.location),
                      case .singlePosition(var map) = lookups[.gpos]![index].body else { return }
                for glyph in glyphs where map[glyph] == nil { map[glyph] = value }
                lookups[.gpos]![index].body = .singlePosition(map)
            } else if rule.elements.count == 2, let value = rule.elements[0].value, rule.elements[1].value == nil {
                pair(rule, value: value, enumerated: enumerated, in: &block)
            } else {
                issue(.unsupported, "Only single and pair positioning rules are supported outside a context.", at: rule.location)
            }
        }
    }

    private mutating func pair(_ rule: FeaturePosition, value: FeatureValue, enumerated: Bool, in block: inout Block) {
        guard let first = resolve(rule.elements[0].glyphs), let second = resolve(rule.elements[1].glyphs),
              let index = lookup(.gpos, 2, empty: .pairPosition([:], [[]]), in: &block, at: rule.location),
              case .pairPosition(var glyphs, var segments) = lookups[.gpos]![index].body else { return }
        if enumerated || (!rule.elements[0].glyphs.isClass && !rule.elements[1].glyphs.isClass) {
            for left in first {
                for right in second where glyphs[left]?[right] == nil { glyphs[left, default: [:]][right] = value }
            }
        } else {
            segments[segments.count - 1].append(FeatureLookup.ClassPair(first: first, second: second, value: value))
        }
        lookups[.gpos]![index].body = .pairPosition(glyphs, segments)
    }

    private mutating func attachment(_ glyphs: FeatureGlyphs, _ attachments: [FeatureAttachment], type: Int, in block: inout Block, at location: FeatureLocation) {
        guard let targets = resolve(glyphs) else { return }
        var resolved: [(FeatureAnchor?, String)] = []
        for attachment in attachments {
            guard markClasses[attachment.markClass] != nil else {
                issue(.unknownName, "The mark class @\(attachment.markClass) is not defined.", at: location, name: "@\(attachment.markClass)")
                return
            }
            resolved.append((attachment.anchor, attachment.markClass))
        }
        let empty = FeatureLookup.Attachment()
        guard let index = lookup(.gpos, type, empty: type == 4 ? .markToBase(empty) : .markToMark(empty), in: &block, at: location) else { return }
        var body: FeatureLookup.Attachment
        switch lookups[.gpos]![index].body {
        case .markToBase(let existing), .markToMark(let existing): body = existing
        default: return
        }
        for (anchor, name) in resolved {
            usedMarkClasses.insert(name)
            let classIndex: Int
            if let found = body.classes.firstIndex(of: name) {
                classIndex = found
            } else {
                classIndex = body.classes.count
                body.classes.append(name)
                for entry in markClasses[name]! {
                    if let existing = body.marks[entry.glyph], existing.mark != classIndex {
                        issue(.invalidRule, "The mark \(glyphNames[entry.glyph]) is in two mark classes used by one lookup.", at: location)
                        return
                    }
                    body.marks[entry.glyph] = (classIndex, entry.anchor)
                }
            }
            for target in targets {
                if type == 4 { inferredBases.insert(target) }
                var anchors = body.bases[target] ?? [:]
                if let anchor { anchors[classIndex] = anchor }
                body.bases[target] = anchors
            }
        }
        lookups[.gpos]![index].body = type == 4 ? .markToBase(body) : .markToMark(body)
    }

    private mutating func contextualPosition(_ rule: FeaturePosition, in block: inout Block) {
        guard let parts = context(rule.elements, at: rule.location), var chain = chainRule(parts, table: .gpos, at: rule.location) else { return }
        if !rule.ignore {
            for (position, element) in parts.input.enumerated() {
                guard let value = element.value else { continue }
                guard element.lookups.isEmpty else {
                    issue(.syntax, "A marked glyph takes a value or lookups, not both.", at: rule.location)
                    return
                }
                chain.records.append((position, anonymous(.gpos, 1, .singlePosition(Dictionary(chain.input[position].map { ($0, value) }) { a, _ in a }),
                                                          flag: block.flag)))
            }
            chain.records.sort { $0.sequence < $1.sequence }
        }
        addChain(chain, table: .gpos, in: &block, at: rule.location)
    }
}
