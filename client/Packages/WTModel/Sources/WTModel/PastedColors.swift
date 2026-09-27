import Foundation
import WTCRDT
import WTProto
import WTRender

/// Paste carrying named colours (exporting-colors.adoc, "Sharing colors between documents";
/// COLOR-019): a copy carries every swatch its objects name -- a tint with its base -- and a paste
/// adds the ones the destination lacks in the same change as the objects, then points the pasted
/// references at the destination's swatches with their colours cached.  The clash rule: a swatch
/// of the same name and value is reused; one of the same name and a different value arrives
/// renamed to its mix values.  Protected swatches (the defaults) map by name.
///
/// On the pasteboard each colour is a `LibraryColor` whose `key` is the source swatch's node id
/// (`counter.replica`) and whose `tint_of` is its base's key, so references can be matched.
public enum PastedColors {
    /// The key of the source swatch `id`.
    static func key(_ id: OpID) -> String { "\(id.counter).\(id.replica)" }

    /// The swatches the objects `trees` of `state` name, as library colours (bases before tints).
    public static func carried(_ trees: [NodeTree], from state: EngineState) -> [Wiretuner_Lib_V1_LibraryColor] {
        var used: [OpID] = []
        var seen: Set<OpID> = []
        for tree in trees {
            for node in tree.flattened.compactMap(\.source) {
                for use in ColorUses.uses(of: node, in: state) {
                    guard let swatch = use.swatch, seen.insert(swatch).inserted else { continue }
                    used.append(swatch)
                }
            }
        }
        let list = SwatchList(state)
        var colors: [Wiretuner_Lib_V1_LibraryColor] = []
        var written: Set<OpID> = []
        func add(_ swatch: Swatch) {
            guard written.insert(swatch.id).inserted else { return }
            var color = Wiretuner_Lib_V1_LibraryColor()
            color.key = key(swatch.id)
            color.name = swatch.plainName
            color.spot = swatch.isSpot
            color.group = swatch.group
            if let base = swatch.base, let baseSwatch = list[base] {
                color.tintOf = key(base)
                color.tintPercent = swatch.tintPercent
                color.value = ColorValues.stored(baseSwatch.color)
            } else {
                color.value = ColorValues.stored(swatch.color)
            }
            colors.append(color)
        }
        for id in used {
            guard let swatch = list[id] else { continue }
            if let base = swatch.base, let baseSwatch = list[base] { add(baseSwatch) }
            add(swatch)
        }
        return colors.filter { $0.tintOf.isEmpty } + colors.filter { !$0.tintOf.isEmpty }
    }

    /// The destination swatch of each carried colour, by source key, creating the missing ones in
    /// `builder`.
    static func resolve(_ colors: [Wiretuner_Lib_V1_LibraryColor], state: EngineState, builder: inout ChangeBuilder) throws -> [String: (id: OpID, color: Color)] {
        let list = SwatchList(state)
        var result: [String: (id: OpID, color: Color)] = [:]
        var taken: Set<String> = []
        var created: [(id: OpID, name: String, value: Wiretuner_Doc_V1_Color, base: OpID?, percent: Double, spot: Bool)] = []
        var previous = state.store.children(SwatchFields.collection).last.flatMap { state.store.placement($0)?.position }
        let ordered = colors.filter { $0.tintOf.isEmpty } + colors.filter { !$0.tintOf.isEmpty }
        for color in ordered where result[color.key] == nil {
            let isTint = !color.tintOf.isEmpty
            let base = isTint ? result[color.tintOf] : nil
            let percent = ColorResolver.percent(color.tintPercent)
            let baseValue = ColorValues.color(color.value)
            let resolved = isTint ? baseValue.tinted(percent / 100) : baseValue
            let name = Swatches.clean(color.name)
            // The same swatch already here: same name and value (a tint: same base and strength).
            func matches(_ swatch: Swatch) -> Bool {
                guard swatch.isSpot == color.spot else { return false }
                if isTint { return swatch.base != nil && swatch.base == base?.id && swatch.tintPercent == percent }
                return !swatch.isTint && swatch.props.value == color.value
            }
            let named = list.named(name)
            if let named, named.isProtected || matches(named) {
                result[color.key] = (named.id, named.color)
                continue
            }
            if let made = created.first(where: { $0.name == name && $0.base == base?.id && $0.spot == color.spot
                && (isTint ? $0.percent == percent : $0.value == color.value) }) {
                result[color.key] = (made.id, resolved)
                continue
            }
            var finalName = name
            if finalName.isEmpty || list.isTaken(finalName) || taken.contains(finalName) {
                let mix = ColorText.defaultName(resolved)
                // A swatch already holding the mix-values name and the value is the same colour.
                if let existing = list.named(mix), matches(existing) {
                    result[color.key] = (existing.id, existing.color)
                    continue
                }
                finalName = Swatches.defaultName(resolved, list, taken: taken)
            }
            taken.insert(finalName)
            let position = try PathEditing.keys(between: previous, and: nil, count: 1)[0]
            previous = position
            let id = builder.append(Swatches.create({ swatch in
                swatch.common.name = finalName
                swatch.spot = color.spot
                swatch.group = String(color.group.prefix(SwatchFields.maxLabel))
                if let base {
                    swatch.parent.id = base.id.proto
                    swatch.parent.cached = ColorValues.cached(base.color)
                    swatch.tintPercent = percent
                } else {
                    swatch.value = ColorValues.stored(resolved)
                }
            }, at: position))
            created.append((id, name, color.value, base?.id, percent, color.spot))
            result[color.key] = (id, resolved)
        }
        return result
    }

    /// `trees` with every swatch reference in `mapping` pointing at the destination swatch.
    static func rewrite(_ trees: [NodeTree], mapping: [String: (id: OpID, color: Color)], schema: Schema) -> [NodeTree] {
        guard !mapping.isEmpty else { return trees }
        func map(_ ref: inout Wiretuner_Doc_V1_ColorRef) -> Bool {
            switch ref.ref {
            case .swatch(var node)?:
                guard let target = mapping[key(OpID(node.id))] else { return false }
                node.id = target.id.proto
                node.cached = ColorValues.cached(target.color)
                ref.swatch = node
                return true
            case .tint(var tint)?:
                guard let target = mapping[key(OpID(tint.base.id))] else { return false }
                tint.base.id = target.id.proto
                tint.base.cached = ColorValues.cached(target.color)
                ref.tint = tint
                return true
            default:
                return false
            }
        }
        func rewritten(_ tree: NodeTree) -> NodeTree {
            var copy = tree
            if let bytes = try? tree.props.serializedBytes() as [UInt8],
               let changed = ColorRefRewriter.rewrite(bytes, message: Schema.root, schema: schema, map),
               let props = try? Wiretuner_Doc_V1_NodeProps(serializedBytes: changed) {
                copy.props = props
            }
            for (path, text) in tree.texts {
                var text = text
                for index in text.runs.indices {
                    for value in text.runs[index].values.indices {
                        guard case .fill(var ref)? = text.runs[index].values[value].value, map(&ref) else { continue }
                        text.runs[index].values[value].fill = ref
                    }
                }
                for index in text.paragraphs.indices {
                    if let bytes = try? text.paragraphs[index].serializedBytes() as [UInt8],
                       let changed = ColorRefRewriter.rewrite(bytes, message: ColorRefRewriter.paragraph, schema: schema, map),
                       let props = try? Wiretuner_Doc_V1_ParagraphProps(serializedBytes: changed) {
                        text.paragraphs[index] = props
                    }
                }
                copy.texts[path] = text
            }
            copy.children = tree.children.map(rewritten)
            return copy
        }
        return trees.map(rewritten)
    }
}

/// Rewrites the `ColorRef`s inside an encoded message, found through the merge table's fields as
/// `ColorUses.nested` finds them; every other byte is kept as it was.
enum ColorRefRewriter {
    static let paragraph = "wiretuner.doc.v1.ParagraphProps"

    /// The re-encoded message; nil when `map` changed nothing (or the bytes do not parse).
    static func rewrite(_ bytes: [UInt8], message: String, schema: Schema, depth: Int = 0,
                        _ map: (inout Wiretuner_Doc_V1_ColorRef) -> Bool) -> [UInt8]? {
        guard depth < 16 else { return nil }
        var out: [UInt8] = []
        var changed = false
        var index = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            let start = index
            guard let key = varint() else { return nil }
            let field = Int(truncatingIfNeeded: key >> 3)
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                index += 8
            case 5:
                index += 4
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                let payload = Array(bytes[index..<(index + Int(length))])
                index += Int(length)
                if let row = schema.field(message, field), row.type == "message", let typeName = row.typeName {
                    var replacement: [UInt8]?
                    if typeName == ColorUses.colorRef {
                        if var ref = try? Wiretuner_Doc_V1_ColorRef(serializedBytes: payload), map(&ref) {
                            replacement = try? ref.serializedBytes()
                        }
                    } else {
                        replacement = rewrite(payload, message: typeName, schema: schema, depth: depth + 1, map)
                    }
                    if let replacement {
                        out += Wire.field(UInt32(field), replacement)
                        changed = true
                        continue
                    }
                }
            default:
                return nil
            }
            guard index <= bytes.count else { return nil }
            out += bytes[start..<index]
        }
        return changed ? out : nil
    }
}
