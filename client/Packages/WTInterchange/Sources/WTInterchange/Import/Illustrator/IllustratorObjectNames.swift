// Object names from Illustrator files (import-formats.adoc, "Adobe Illustrator"; LIB-030, D-095).
// Illustrator keeps an object's name in its native art, not in the drawing a file is read from:
// the art dictionary written after the object (`%_/ArtDictionary :` … `%_;`) holds it as the
// object's XML ID, `/XMLUID : (Logo_x5F_mark) ; (AI10_ArtUID) ,`.  The native art is the private
// data of a PDF-compatible file (IllustratorPrivateData), the `%AI9_PrivateDataBegin` stream an
// Illustrator EPS carries after its PostScript, or a native-format file itself.  The importers
// read the artwork from the PDF or the PostScript, which draw some objects in several pieces and
// leave others out, so the names are matched object by object: a native path names the imported
// path of the same size at the same place (one offset for the whole page, found by vote), in
// drawing order; text and images between two matched paths pair up when they agree in number and
// kind.  A named group names the imported objects of its matched paths when they are one run of
// one parent (the PDF has none of Illustrator's groups, so the run becomes a group).  What does
// not match keeps its default label, silently.

import Foundation
import WTGeometry

/// Illustrator's native art as far as names need it: each top-level layer's drawn objects in
/// order, with the names their art dictionaries give, and its named groups.
struct IllustratorNativeArt: Equatable {
    enum Kind: Equatable {
        case path
        case text
        case image
    }

    /// One drawn object: a painted path or compound path, a text object or a raster.
    struct Leaf: Equatable {
        var kind: Kind
        /// A path's control-point bounds in the art's coordinates (y up); nil for text and images.
        var bounds: Rect?
        var name: String?
    }

    /// A named group (`u` … `U` or a clipping group `q` … `Q`): the leaves it holds.
    struct Group: Equatable {
        var range: Range<Int>
        var name: String
    }

    struct Layer: Equatable {
        var name: String
        var leaves: [Leaf] = []
        var groups: [Group] = []
    }

    var layers: [Layer] = []

    /// How many objects the art names.
    var nameCount: Int {
        layers.reduce(0) { $0 + $1.leaves.filter { $0.name != nil }.count + $1.groups.count }
    }

    /// The art of native data or a PostScript Illustrator file.
    init(scanning data: Data) {
        var scanner = IllustratorArtScanner()
        scanner.run(IllustratorNativeArt.withoutBinaryData(data))
        self = scanner.art
    }

    init(layers: [Layer]) {
        self.layers = layers
    }

    /// Whether `data` names an object (an XML ID beyond one per layer): the scan is only worth
    /// its time then.
    static func namesObjects(_ data: Data) -> Bool {
        count(of: Data("/XMLUID".utf8), in: data) > count(of: Data("%AI5_BeginLayer".utf8), in: data)
    }

    static func count(of pattern: Data, in data: Data) -> Int {
        var count = 0
        var position = data.startIndex
        while let range = data.range(of: pattern, in: position..<data.endIndex) {
            count += 1
            position = range.upperBound
        }
        return count
    }

    /// `data` without the bytes of its `%%BeginData:` … `%%EndData` sections (rasters, thumbnails),
    /// which are not PostScript tokens -- except a raster's `XI`, the operator that begins them.
    static func withoutBinaryData(_ data: Data) -> Data {
        let begin = Data("%%BeginData:".utf8)
        let end = Data("%%EndData".utf8)
        guard data.range(of: begin) != nil else { return data }
        var result = Data()
        var position = data.startIndex
        while let opening = data.range(of: begin, in: position..<data.endIndex) {
            result.append(data[position..<opening.lowerBound])
            let line = data[opening.upperBound...].firstIndex { $0 == 10 || $0 == 13 } ?? data.endIndex
            if data[line...].drop(while: { $0 == 10 || $0 == 13 }).starts(with: Data("XI".utf8)) {
                result.append(Data("\rXI".utf8))
            }
            guard let closing = data.range(of: end, in: opening.upperBound..<data.endIndex) else {
                return result
            }
            position = closing.upperBound
        }
        result.append(data[position..<data.endIndex])
        return result
    }

    /// An XML ID as the name it stands for: `_xH…_` is the character (or UTF-16 code unit) with
    /// hex code H… (`_x5F_` an underscore, `_xD83D__xDC39_` a surrogate pair), a plain `_` a
    /// space, and a final `_N_` the number that made a repeated name's ID unique.
    static func name(fromXMLID id: String) -> String {
        // Illustrator keeps XML IDs unique by appending `_1_`, `_2_` …
        let unique = id.replacingOccurrences(of: #"(?<=.)_\d+_$"#, with: "", options: .regularExpression)
        let units = Array(unique.utf16)
        var result: [UInt16] = []
        var index = 0
        while index < units.count {
            if units[index] == 0x5F, index + 1 < units.count, units[index + 1] == 0x78,
               let close = units[(index + 2)...].prefix(7).firstIndex(of: 0x5F), close > index + 2,
               let value = UInt32(String(decoding: units[(index + 2)..<close], as: UTF16.self), radix: 16),
               let encoded = value <= 0xFFFF ? [UInt16(value)] : Unicode.Scalar(value).map({ Array(String($0).utf16) }) {
                result += encoded
                index = close + 1
            } else {
                result.append(units[index] == 0x5F ? 0x20 : units[index])
                index += 1
            }
        }
        return String(decoding: result, as: UTF16.self)
    }
}

/// Walks native art or a PostScript Illustrator file's page description.
struct IllustratorArtScanner {
    var art = IllustratorNativeArt(layers: [])

    /// What an art dictionary that follows belongs to.
    enum Target {
        case none
        case leaf(Int)
        case group(Range<Int>)
    }

    static let pathOperators: Set<String> = ["m", "l", "L", "c", "C", "v", "V", "y", "Y"]
    static let paintOperators: Set<String> = ["f", "F", "s", "S", "b", "B"]
    static let unpaintedOperators: Set<String> = ["n", "N", "h", "H"]
    /// The open top-level layer and how deep the layers nest.
    var layer: Int?
    var layerDepth = 0
    /// The first leaf of each open group.
    var groups: [Int] = []
    /// The open compound path: whether it has a contour, and its bounds.
    var compound: (contours: Bool, bounds: Rect)?
    var path = Rect.null
    /// Whether a text object is open, and whether it has shown any text.
    var text: Bool?
    var target = Target.none
    /// The art dictionary being read: its lines and how deeply its containers nest.
    var dictionary: (lines: [String], depth: Int)?

    /// Scans the page description: from `%%EndSetup` on (the prolog and setup -- procedure sets,
    /// document data, text documents -- are not art and need not be well-formed PostScript).
    mutating func run(_ data: Data) {
        let body = data.range(of: Data("%%EndSetup".utf8)).map { data[$0.upperBound...] } ?? data[...]
        var parser = PDFImportParser(Data(body), keepComments: true)
        var operands: [PDFImportOperand] = []
        var skipping: String?
        while let item = parser.next() {
            switch item {
            case .comment(let comment):
                if let end = skipping {
                    if comment.hasPrefix(end) { skipping = nil }
                    continue
                }
                if comment.hasPrefix("%PageTrailer") || comment.hasPrefix("%Trailer") || comment.hasPrefix("%EOF") {
                    return
                }
                skipping = [("AI5_BeginPalette", "AI5_EndPalette"), ("AI5_Begin_NonPrinting", "AI5_End_NonPrinting")].first { comment.hasPrefix($0.0) }?.1
                if skipping == nil { readComment(comment) }
            case .operand(let operand):
                if skipping == nil { operands.append(operand) }
            case .op(let op):
                if skipping == nil { execute(op, operands) }
                operands.removeAll()
            }
        }
    }

    /// `%_` lines: an art dictionary, read whole and given to the object before it.
    mutating func readComment(_ comment: String) {
        guard comment.hasPrefix("_") else { return }
        let line = String(comment.dropFirst())
        if var open = dictionary {
            open.lines.append(line)
            open.depth += IllustratorArtScanner.nesting(line)
            dictionary = open.depth > 0 ? open : nil
            if open.depth <= 0 { close(open.lines) }
        } else if line.hasPrefix("/ArtDictionary :") {
            let depth = IllustratorArtScanner.nesting(line)
            dictionary = depth > 0 ? ([line], depth) : nil
            if depth <= 0 { close([line]) }
        }
    }

    /// How many containers `line` opens (`:`) less how many it closes (`;`).
    static func nesting(_ line: String) -> Int {
        var parser = PDFImportParser(Data(line.utf8))
        var depth = 0
        while let item = parser.next() {
            if item == .op(":") { depth += 1 } else if item == .op(";") { depth -= 1 }
        }
        return depth
    }

    /// The art dictionary in `lines` ends: its XML ID names the target.
    mutating func close(_ lines: [String]) {
        defer { target = .none }
        guard let id = IllustratorArtScanner.xmlID(lines.joined(separator: "\n")), let index = layer else { return }
        let name = IllustratorNativeArt.name(fromXMLID: id)
        guard !name.isEmpty else { return }
        switch target {
        case .leaf(let leaf): art.layers[index].leaves[leaf].name = name
        case .group(let range): art.layers[index].groups.append(.init(range: range, name: name))
        case .none: break
        }
    }

    /// The `/XMLUID : (id) ;` entry of an art dictionary's own level.
    static func xmlID(_ text: String) -> String? {
        var parser = PDFImportParser(Data(text.utf8))
        var depth = 0
        var previous: PDFImportParser.Item?
        var opened = false
        while let item = parser.next() {
            switch item {
            case .op(":"):
                depth += 1
                opened = depth == 2 && previous == .operand(.name("XMLUID"))
            case .op(";"):
                depth -= 1
                opened = false
            case .operand(.string(let data)) where opened:
                return IllustratorDataValue.scalar(data).text
            default:
                break
            }
            previous = item
        }
        return nil
    }

    var leafCount: Int { layer.map { art.layers[$0].leaves.count } ?? 0 }

    /// Records a leaf in the open layer and makes it the dictionary's target.
    mutating func leaf(_ kind: IllustratorNativeArt.Kind, bounds: Rect?) {
        guard let index = layer else { return }
        art.layers[index].leaves.append(.init(kind: kind, bounds: bounds))
        target = .leaf(art.layers[index].leaves.count - 1)
    }

    mutating func execute(_ op: String, _ operands: [PDFImportOperand]) {
        if var open = text {
            if op == "TO" {
                text = nil
                if open { leaf(.text, bounds: nil) }
            } else if ["Tx", "Tj", "TX"].contains(op), let string = operands.first?.string, string.contains(where: { $0 != 10 && $0 != 13 }) {
                open = true
                text = open
            }
            return
        }
        if IllustratorArtScanner.pathOperators.contains(op) {
            if op == "m" { target = .none }
            let numbers = operands.compactMap(\.number)
            for index in stride(from: 0, to: numbers.count - 1, by: 2) {
                path = path.union(Point(x: numbers[index], y: numbers[index + 1]))
            }
            return
        }
        let painted = IllustratorArtScanner.paintOperators.contains(op)
        if painted || IllustratorArtScanner.unpaintedOperators.contains(op) {
            paint(painted)
            return
        }
        switch op {
        case "*u":
            target = .none
            compound = (false, .null)
        case "*U":
            if let open = compound, open.contours {
                leaf(.path, bounds: open.bounds)
            } else {
                target = .none
            }
            compound = nil
        case "u", "q":
            target = .none
            groups.append(leafCount)
        case "U", "Q":
            let start = groups.popLast() ?? leafCount
            target = start < leafCount ? .group(start..<leafCount) : .none
        case "Lb":
            target = .none
            if layerDepth == 0 {
                art.layers.append(.init(name: "Layer"))
                layer = art.layers.count - 1
            }
            layerDepth += 1
        case "Ln" where layerDepth == 1:
            if let index = layer, let name = operands.first?.string {
                art.layers[index].name = PDFImportOperand.text(name)
            }
            target = .none
        case "LB":
            layerDepth = max(layerDepth - 1, 0)
            if layerDepth == 0 { layer = nil }
            target = .none
        case "To":
            target = .none
            text = false
        case "XI":
            leaf(.image, bounds: nil)
        default:
            break
        }
    }

    /// A path ends: painted, it is a leaf (or a contour of the open compound path).
    mutating func paint(_ painted: Bool) {
        let bounds = path
        path = .null
        if var open = compound {
            if !bounds.isNull {
                open.contours = true
                open.bounds = open.bounds.union(bounds)
            }
            compound = open
            target = .none
        } else if painted && !bounds.isNull {
            leaf(.path, bounds: bounds)
        } else {
            target = .none
        }
    }
}

extension IllustratorPrivateData {
    /// The native art an Illustrator EPS carries after its PostScript (`%AI9_PrivateDataBegin`
    /// … `%AI9_DataStream`, ASCII85 in `%` lines, then zlib), or nil.
    static func eps(_ data: Data) -> Data? {
        guard let marker = data.range(of: Data("%AI9_DataStream".utf8)) else { return nil }
        let end = data.range(of: Data("%AI9_PrivateDataEnd".utf8), in: marker.upperBound..<data.endIndex)?.lowerBound ?? data.endIndex
        guard let decoded = ASCII85.decode(data[marker.upperBound..<end], commentLines: true) else { return nil }
        return inflate(decoded) ?? decoded
    }
}

extension ASCII85 {
    /// ASCII85 text (PostScript's ASCII85Decode: `z` for four zeros, white space ignored, `~>`
    /// at the end) decoded; nil when it is not ASCII85.  With `commentLines`, the `%` that
    /// starts each line is not data (Illustrator's private data in an EPS).
    static func decode(_ text: Data, commentLines: Bool = false) -> Data? {
        var output = [UInt8]()
        output.reserveCapacity(text.count / 5 * 4 + 4)
        var group: UInt64 = 0
        var count = 0
        var lineStart = true
        func flush(_ digits: Int) -> Bool {
            var value = group
            for _ in digits..<5 { value = value * 85 + 84 }
            guard value <= UInt64(UInt32.max) else { return false }
            for shift in stride(from: 24, to: 24 - 8 * (digits - 1), by: -8) { output.append(UInt8(value >> UInt64(shift) & 0xFF)) }
            return true
        }
        let finished: Bool? = text.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                if commentLines && lineStart && byte == UInt8(ascii: "%") {
                    lineStart = false
                    continue
                }
                lineStart = byte == 10 || byte == 13
                switch byte {
                case 33...117:
                    group = group * 85 + UInt64(byte - 33)
                    count += 1
                    if count == 5 {
                        guard flush(5) else { return false }
                        group = 0
                        count = 0
                    }
                case UInt8(ascii: "z") where count == 0:
                    output.append(contentsOf: [0, 0, 0, 0])
                case UInt8(ascii: "~"):
                    return true
                case 0, 9, 10, 12, 13, 32:
                    continue
                default:
                    return false
                }
            }
            return nil
        }
        guard finished != false else { return nil }
        if count > 1 {
            guard flush(count) else { return nil }
        }
        return Data(output)
    }
}

/// Gives an imported page's objects the names of the native art's (D-095).
enum IllustratorObjectNames {
    /// One drawn object of the imported tree: its kind and, for a path, its scene bounds.
    struct SceneLeaf {
        var kind: IllustratorNativeArt.Kind
        var bounds: Rect?
    }

    /// How far (points) the sides of a native path and an imported one may lie apart and still
    /// be the same object.
    static let tolerance = 0.5

    /// Native coordinates to the page's: x moved by `dx`, y flipped about `dy` (native y up) or
    /// moved by it.
    struct Offset: Equatable {
        var dx: Double
        var dy: Double
        var flipped: Bool

        func apply(_ rect: Rect) -> Rect {
            flipped
                ? Rect(minX: rect.minX + dx, minY: dy - rect.maxY, maxX: rect.maxX + dx, maxY: dy - rect.minY)
                : Rect(minX: rect.minX + dx, minY: rect.minY + dy, maxX: rect.maxX + dx, maxY: rect.maxY + dy)
        }
    }

    /// A whole-point grid cell: of a place, or of a size.
    struct Cell: Hashable {
        var x: Int
        var y: Int

        init(_ x: Double, _ y: Double) {
            self.x = Int(x.rounded())
            self.y = Int(y.rounded())
        }

        /// This cell and its eight neighbours.
        var around: [Cell] {
            (-1...1).flatMap { dx in (-1...1).map { dy in Cell(x: x + dx, y: y + dy) } }
        }

        private init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    /// A layer group of the page and its native layer.
    struct Pair {
        var node: Int
        var layer: Int
        var leaves: [SceneLeaf]
    }

    /// `nodes` -- a page's or a scene's top-level nodes, its layers among them -- with the names
    /// of `art`'s objects that match; how many names were given.
    @discardableResult
    static func apply(_ art: IllustratorNativeArt, to nodes: inout [ImportedNode]) -> Int {
        let pairs = pairs(art, nodes)
        let offset = offset(pairs.map { ($0.leaves, art.layers[$0.layer].leaves) })
        var given = 0
        for pair in pairs {
            let native = art.layers[pair.layer]
            let matches = match(pair.leaves, native.leaves, groups: native.groups, offset: offset)
            guard !matches.isEmpty, case .group(var layer) = nodes[pair.node] else { continue }
            var names = [String?](repeating: nil, count: pair.leaves.count)
            for (scene, index) in matches { names[scene] = native.leaves[index].name }
            var counter = 0
            given += nameLeaves(names, in: &layer.children, counter: &counter)
            let sceneOf = Dictionary(uniqueKeysWithValues: matches.map { ($1, $0) })
            for group in native.groups.sorted(by: { ($0.range.count, $0.range.lowerBound) < ($1.range.count, $1.range.lowerBound) }) {
                // Every object of the group matched, and nothing of another group's among them.
                let scenes = group.range.compactMap { sceneOf[$0] }
                guard scenes.count == group.range.count, let low = scenes.min(), let high = scenes.max(),
                      (low...high).allSatisfy({ matches[$0].map(group.range.contains) ?? true }) else { continue }
                if nameGroup(IllustratorNativeArt.Group(range: low..<(high + 1), name: group.name), in: &layer.children, start: 0) {
                    given += 1
                }
            }
            nodes[pair.node] = .group(layer)
        }
        return given
    }

    /// Each layer group of `nodes` with the native layer of its name (in order; a name the
    /// importer made unique with " 2", " 3" … by its base), when that layer names anything.
    static func pairs(_ art: IllustratorNativeArt, _ nodes: [ImportedNode]) -> [Pair] {
        var used = Set<Int>()
        var pairs: [Pair] = []
        for (index, node) in nodes.enumerated() {
            guard case .group(let group) = node, group.role == .layer, let name = group.name else { continue }
            let base = name.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)
            guard let match = art.layers.indices.first(where: { !used.contains($0) && art.layers[$0].name == name })
                    ?? art.layers.indices.first(where: { !used.contains($0) && art.layers[$0].name == base }) else { continue }
            used.insert(match)
            guard art.layers[match].leaves.contains(where: { $0.name != nil }) || !art.layers[match].groups.isEmpty else { continue }
            var leaves: [SceneLeaf] = []
            collect(group.children, .identity, into: &leaves)
            pairs.append(Pair(node: index, layer: match, leaves: leaves))
        }
        return pairs
    }

    /// The page's offset: the one most pairs of same-sized paths agree on (a size shared by more
    /// than eight native paths does not vote), or nil without two agreeing pairs.
    static func offset(_ layers: [([SceneLeaf], [IllustratorNativeArt.Leaf])]) -> Offset? {
        struct Vote: Hashable {
            var cell: Cell
            var flipped: Bool
        }
        var votes: [Vote: [(Double, Double)]] = [:]
        for (scene, native) in layers {
            var bySize: [Cell: [Rect]] = [:]
            for case let bounds? in native.map(\.bounds) where finite(bounds) {
                bySize[Cell(bounds.width, bounds.height), default: []].append(bounds)
            }
            for case let s? in scene.map(\.bounds) where finite(s) {
                let candidates = Cell(s.width, s.height).around.flatMap { bySize[$0] ?? [] }
                    .filter { abs($0.width - s.width) <= tolerance && abs($0.height - s.height) <= tolerance }
                guard candidates.count <= 8 else { continue }
                for n in candidates {
                    let dx = s.minX - n.minX
                    for (flipped, dy) in [(true, s.minY + n.maxY), (false, s.minY - n.minY)] {
                        votes[Vote(cell: Cell(dx, dy), flipped: flipped), default: []].append((dx, dy))
                    }
                }
            }
        }
        func support(_ vote: Vote) -> [(Double, Double)] {
            vote.cell.around.flatMap { votes[Vote(cell: $0, flipped: vote.flipped)] ?? [] }
        }
        let ranked = votes.keys.map { ($0, support($0)) }.sorted { a, b in
            a.1.count != b.1.count ? a.1.count > b.1.count : (a.0.flipped != b.0.flipped ? a.0.flipped : (a.0.cell.x, a.0.cell.y) < (b.0.cell.x, b.0.cell.y))
        }
        guard let (best, values) = ranked.first, values.count >= 2 else { return nil }
        let dx = values.map(\.0).reduce(0, +) / Double(values.count)
        let dy = values.map(\.1).reduce(0, +) / Double(values.count)
        return Offset(dx: dx, dy: dy, flipped: best.flipped)
    }

    /// Whether `a` and `b` are the same box, side by side within `tolerance`.
    static func same(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    static func finite(_ rect: Rect) -> Bool {
        !rect.isNull && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy { $0.isFinite && abs($0) < 1e9 }
    }

    /// Which native leaf each imported leaf is, imported index to native index, in drawing order:
    /// paths the longest run of native paths of their size at their place under `offset` (but
    /// not a native path with a twin -- the same box -- of another name or group when the import
    /// has fewer paths there than the native art: which of them it drew cannot be told); text
    /// and images between two matched paths (or the layer's ends) when both sides hold the same
    /// kinds there.
    static func match(_ scene: [SceneLeaf], _ native: [IllustratorNativeArt.Leaf], groups: [IllustratorNativeArt.Group] = [], offset: Offset?) -> [Int: Int] {
        var result: [Int: Int] = [:]
        if let offset {
            let placed = native.map { leaf in leaf.bounds.flatMap { finite($0) ? offset.apply($0) : nil } }
            var byPlace: [Cell: [Int]] = [:]
            for (index, bounds) in placed.enumerated() {
                if let bounds { byPlace[Cell(bounds.minX, bounds.minY), default: []].append(index) }
            }
            func twins(_ box: Rect) -> [Int] {
                Cell(box.minX, box.minY).around.flatMap { byPlace[$0] ?? [] }.filter { same(placed[$0]!, box) }
            }
            // The longest increasing run of native indices (patience sorting over the pairs).
            var tails: [Int] = []
            var links: [(scene: Int, native: Int, previous: Int?)] = []
            var tailLinks: [Int] = []
            for (index, leaf) in scene.enumerated() {
                guard let box = leaf.bounds, finite(box) else { continue }
                for candidate in twins(box).sorted(by: >) {
                    var low = 0
                    var high = tails.count
                    while low < high {
                        let middle = (low + high) / 2
                        if tails[middle] < candidate { low = middle + 1 } else { high = middle }
                    }
                    // A later piece of the same native path keeps the earlier match.
                    if low < tails.count, tails[low] == candidate { continue }
                    links.append((index, candidate, low > 0 ? tailLinks[low - 1] : nil))
                    if low == tails.count {
                        tails.append(candidate)
                        tailLinks.append(links.count - 1)
                    } else {
                        tails[low] = candidate
                        tailLinks[low] = links.count - 1
                    }
                }
            }
            func signature(_ index: Int) -> [String] {
                [native[index].name ?? ""] + groups.filter { $0.range.contains(index) }.map(\.name)
            }
            var sceneByPlace: [Cell: [Rect]] = [:]
            for case let box? in scene.map(\.bounds) where finite(box) {
                sceneByPlace[Cell(box.minX, box.minY), default: []].append(box)
            }
            var link = tailLinks.last
            while let current = link {
                let pair = links[current]
                let box = placed[pair.native]!
                let alike = twins(box)
                let drawn = Cell(box.minX, box.minY).around.flatMap { sceneByPlace[$0] ?? [] }.filter { same($0, box) }.count
                // Twins all drawn match in order; with some left out, only when they are alike.
                if drawn >= alike.count || Set(alike.map(signature)).count == 1 {
                    result[pair.scene] = pair.native
                }
                link = pair.previous
            }
        }
        var previous = (scene: -1, native: -1)
        for anchor in result.sorted(by: { $0.key < $1.key }).map({ ($0.key, $0.value) }) + [(scene.count, native.count)] {
            let sceneGap = ((previous.scene + 1)..<anchor.0).filter { scene[$0].kind != .path }
            let nativeGap = ((previous.native + 1)..<anchor.1).filter { native[$0].kind != .path }
            if sceneGap.count == nativeGap.count, zip(sceneGap, nativeGap).allSatisfy({ scene[$0].kind == native[$1].kind }) {
                for (s, n) in zip(sceneGap, nativeGap) { result[s] = n }
            }
            previous = (anchor.0, anchor.1)
        }
        return result
    }

    /// The drawn objects under `nodes` in drawing order, `transform` taking them to the scene.
    static func collect(_ nodes: [ImportedNode], _ transform: AffineTransform, into leaves: inout [SceneLeaf]) {
        for node in nodes {
            switch node {
            case .group(let group):
                collect(group.children, group.transform.concatenating(transform), into: &leaves)
            case .path(let path):
                let total = path.transform.concatenating(transform)
                leaves.append(SceneLeaf(kind: .path, bounds: Rect(boundingPoints: path.contours.flatMap(\.allPoints).map(total.apply))))
            case .text:
                leaves.append(SceneLeaf(kind: .text))
            case .image, .placed:
                leaves.append(SceneLeaf(kind: .image))
            }
        }
    }

    /// How many drawn objects are under `node`.
    static func leafCount(_ node: ImportedNode) -> Int {
        if case .group(let group) = node {
            return group.children.reduce(0) { $0 + leafCount($1) }
        }
        return 1
    }

    /// Names the drawn objects under `nodes` from `names` in drawing order; how many it named.
    static func nameLeaves(_ names: [String?], in nodes: inout [ImportedNode], counter: inout Int) -> Int {
        var given = 0
        func next(_ current: String?) -> String? {
            defer { counter += 1 }
            guard let name = names[counter] else { return current }
            given += 1
            return name
        }
        for index in nodes.indices {
            switch nodes[index] {
            case .group(var group):
                given += nameLeaves(names, in: &group.children, counter: &counter)
                nodes[index] = .group(group)
            case .path(var path):
                path.name = next(path.name)
                nodes[index] = .path(path)
            case .text(var text):
                text.name = next(text.name)
                nodes[index] = .text(text)
            case .image(var image):
                image.name = next(image.name)
                nodes[index] = .image(image)
            case .placed(var placed):
                placed.name = next(placed.name)
                nodes[index] = .placed(placed)
            }
        }
        return given
    }

    /// Names the group holding exactly the imported objects `named.range` -- an unnamed group of
    /// those objects, else a new group around the run of nodes that holds them; false when they
    /// are not one run.
    static func nameGroup(_ named: IllustratorNativeArt.Group, in nodes: inout [ImportedNode], start: Int) -> Bool {
        let counts = nodes.map(leafCount)
        var offset = start
        var first: Int?
        for index in nodes.indices {
            let range = offset..<(offset + counts[index])
            if range == named.range, case .group(var group) = nodes[index], group.role == .group, group.name == nil {
                group.name = named.name
                nodes[index] = .group(group)
                return true
            }
            if range != named.range, range.lowerBound <= named.range.lowerBound, named.range.upperBound <= range.upperBound, case .group(var group) = nodes[index] {
                let found = nameGroup(named, in: &group.children, start: offset)
                nodes[index] = .group(group)
                return found
            }
            if first == nil, offset == named.range.lowerBound, counts[index] > 0 { first = index }
            offset = range.upperBound
            if let begin = first, offset == named.range.upperBound {
                let run = Array(nodes[begin...index])
                nodes.replaceSubrange(begin...index, with: [.group(ImportedGroup(children: run, name: named.name))])
                return true
            }
        }
        return false
    }
}
