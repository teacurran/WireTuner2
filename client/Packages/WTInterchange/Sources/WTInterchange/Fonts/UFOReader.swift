// FONT-024: reading a UFO package (font-export.adoc, "UFO packages" and "Client", UFO): UFO 2 and 3
// -- `metainfo.plist`, `fontinfo.plist` into names, metrics and OS/2 values, the default layer's
// glyphs (`glyphs/contents.plist` and `.glif` files: contours with `move`/`line`/`curve`/`qcurve`/
// `offcurve` points, quadratics converted to cubics exactly, components with their six-number
// transforms, anchors -- UFO 3 `anchor` elements or UFO 2 single-point named contours --, advance
// widths, unicodes and the `public.markColor` of the glyph's lib), `groups.plist` and
// `kerning.plist` into kerning classes, cells and pairs (UFO 3 `public.kern1.`/`public.kern2.`
// groups; in UFO 2 any group a kerning pair uses on its side), `features.fea`, the glyph order
// (`public.glyphOrder`, the remaining glyphs after it by name, `.notdef` first) and the rest of
// `lib.plist` as an opaque blob.  The result is an `ImportedFont` -- what WTModel's font import
// writes -- plus what the OpenType reader has no place for.  Whatever is not read is listed in the
// report.  Since FONT-023 also each glyph's `note`, its as-drawn artwork (`UFOWriter.artworkKey` in
// its lib) and its kind from `public.openTypeCategories`, so a WireTuner export reads back whole.

import Foundation
import WTGeometry

/// A UFO as read.
public struct UFOFont: Sendable {
    /// Glyphs (in glyph order), outlines, names, metrics, OS/2 values and kerning.
    public var font: ImportedFont
    /// The UFO format version (2 or 3).
    public var formatVersion: Int
    /// Each glyph's anchors, parallel to `font.glyphs` (font units, y up).
    public var anchors: [[FontSource.Anchor]]
    /// Each glyph's mark color as the grid's index (1 ... 12, 0 none), parallel to `font.glyphs`.
    public var markColors: [Int]
    /// `features.fea`.
    public var features: String
    /// `lib.plist` without the keys read here, as a binary property list (nil when empty).
    public var lib: Data?
    /// Each glyph's `note`, parallel to `font.glyphs` (FONT-023).
    public var notes: [String]
    /// Each glyph's kind from `public.openTypeCategories`, parallel to `font.glyphs`; nil when the
    /// lib does not name it (FONT-023).
    public var kinds: [FontSource.GlyphKind?]
    /// Each glyph's as-drawn artwork (`UFOWriter.artworkKey` in its lib), parallel to `font.glyphs`
    /// (FONT-023).
    public var artwork: [Data?]

    public init(font: ImportedFont, formatVersion: Int, anchors: [[FontSource.Anchor]], markColors: [Int], features: String, lib: Data?,
                notes: [String]? = nil, kinds: [FontSource.GlyphKind?]? = nil, artwork: [Data?]? = nil) {
        self.font = font
        self.formatVersion = formatVersion
        self.anchors = anchors
        self.markColors = markColors
        self.features = features
        self.lib = lib
        self.notes = notes ?? Array(repeating: "", count: font.glyphs.count)
        self.kinds = kinds ?? Array(repeating: nil, count: font.glyphs.count)
        self.artwork = artwork ?? Array(repeating: nil, count: font.glyphs.count)
    }
}

/// Reads UFO packages.
public enum UFOReader {
    /// Why a package could not be read.
    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// No `metainfo.plist`, or a format other than 2 or 3.
        case notAUFO(String)
        /// A file that does not parse.
        case malformed(String)

        public var description: String {
            switch self {
            case .notAUFO(let why): "Not a UFO package: \(why)"
            case .malformed(let why): "The UFO is damaged: \(why)"
            }
        }
    }

    /// The grid's twelve mark colors (the system colors WTApp draws them in), for the nearest match.
    static let markPalette: [(Double, Double, Double)] = [
        (1, 0.231, 0.188), (1, 0.584, 0), (1, 0.8, 0), (0.204, 0.78, 0.349), (0, 0.78, 0.745), (0.188, 0.69, 0.78),
        (0.196, 0.678, 0.902), (0, 0.478, 1), (0.345, 0.337, 0.839), (0.686, 0.322, 0.871), (1, 0.176, 0.333), (0.635, 0.518, 0.369),
    ]

    /// Reads the package at `url`.
    public static func read(at url: URL) throws -> UFOFont {
        guard let meta = try? plist(url.appending(component: "metainfo.plist")) as? [String: Any] else {
            throw Failure.notAUFO("no metainfo.plist")
        }
        let version = (meta["formatVersion"] as? Int) ?? 0
        guard version == 2 || version == 3 else { throw Failure.notAUFO("format version \(version)") }
        var report: [String] = []
        let info = (try optionalPlist(url.appending(component: "fontinfo.plist"))) ?? [:]
        var lib = (try optionalPlist(url.appending(component: "lib.plist"))) ?? [:]
        let groups = ((try optionalPlist(url.appending(component: "groups.plist"))) ?? [:]).compactMapValues { $0 as? [String] }
        let kerning = ((try optionalPlist(url.appending(component: "kerning.plist"))) ?? [:]).compactMapValues { $0 as? [String: Any] }
        let features = (try? String(contentsOf: url.appending(component: "features.fea"), encoding: .utf8)) ?? ""

        // The default layer.
        var glyphDirectory = "glyphs"
        if version == 3, let layers = try? plist(url.appending(component: "layercontents.plist")) as? [[String]] {
            if let first = layers.first(where: { $0.count == 2 && $0[1] == "glyphs" }) ?? layers.first, first.count == 2 { glyphDirectory = first[1] }
            for layer in layers where layer.count == 2 && layer[1] != glyphDirectory {
                report.append("The layer \(layer[0]) was not imported (only the default layer is read).")
            }
        }
        for extra in ["images", "data"] where FileManager.default.fileExists(atPath: url.appending(component: extra).path) {
            report.append("The package's \(extra) folder was not imported.")
        }
        let directory = url.appending(component: glyphDirectory)
        guard let contents = try optionalPlist(directory.appending(component: "contents.plist")) else {
            throw Failure.malformed("\(glyphDirectory)/contents.plist is missing")
        }
        var parsed: [String: GlifGlyph] = [:]
        for (name, file) in contents {
            guard let file = file as? String else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: directory.appending(component: file))
            } catch {
                throw Failure.malformed("the glyph file \(file) is missing")
            }
            var glyph = try GlifParser.parse(data, file: file)
            if glyph.name.isEmpty { glyph.name = name }
            report += glyph.notes.map { "\(name): \($0)" }
            parsed[name] = glyph
        }

        // Glyph order: the lib's, then the rest by name; `.notdef` first.
        var ordered: Set<String> = []
        var order = ((lib["public.glyphOrder"] as? [String]) ?? []).filter { parsed[$0] != nil && ordered.insert($0).inserted }
        order += parsed.keys.filter { !ordered.contains($0) }.sorted()
        if let notdef = order.firstIndex(of: ".notdef"), notdef > 0 { order.insert(order.remove(at: notdef), at: 0) }
        lib["public.glyphOrder"] = nil
        let categories = (lib[UFOWriter.categoriesKey] as? [String: String]).map { found in
            lib[UFOWriter.categoriesKey] = nil
            return found
        }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })

        var glyphs: [ImportedFont.Glyph] = []
        var anchors: [[FontSource.Anchor]] = []
        var colors: [Int] = []
        var notes: [String] = []
        var kinds: [FontSource.GlyphKind?] = []
        var artwork: [Data?] = []
        for name in order {
            let glyph = parsed[name]!
            let components = glyph.components.compactMap { component -> ImportedFont.Component? in
                guard let target = index[component.base] else {
                    report.append("\(name): the component \(component.base) is not in the font and was left out.")
                    return nil
                }
                return ImportedFont.Component(glyph: target, transform: component.transform)
            }
            glyphs.append(ImportedFont.Glyph(name: name, codepoints: glyph.unicodes, advanceWidth: glyph.advance, contours: glyph.contours,
                                             components: components))
            anchors.append(glyph.anchors)
            colors.append(glyph.markColor.map(markColor) ?? 0)
            notes.append(glyph.note)
            artwork.append(glyph.artwork)
            // A lib with categories names every glyph that is not a base.
            kinds.append(categories.map { $0[name].flatMap(UFOWriter.kind(category:)) ?? .base })
        }

        let names = self.names(info)
        let metrics = self.metrics(info)
        let os2 = self.os2(info)
        let kern = self.kerning(kerning, groups: groups, index: index, version: version, report: &report)
        let passthrough = lib.isEmpty ? nil : try? PropertyListSerialization.data(fromPropertyList: lib, format: .binary, options: 0)
        let font = ImportedFont(names: names, metrics: metrics, os2: os2, glyphs: glyphs, kerning: kern, report: report)
        return UFOFont(font: font, formatVersion: version, anchors: anchors, markColors: colors, features: features, lib: passthrough, notes: notes,
                       kinds: kinds, artwork: artwork)
    }

    // MARK: Property lists

    static func plist(_ url: URL) throws -> Any {
        let data = try Data(contentsOf: url)
        do {
            return try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw Failure.malformed("\(url.lastPathComponent) does not parse")
        }
    }

    /// The dictionary in `url`, nil when the file is absent.
    static func optionalPlist(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let dictionary = try plist(url) as? [String: Any] else { throw Failure.malformed("\(url.lastPathComponent) is not a dictionary") }
        return dictionary
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func names(_ info: [String: Any]) -> FontSource.Names {
        func string(_ key: String) -> String { info[key] as? String ?? "" }
        let family = string("familyName").isEmpty ? "Untitled" : string("familyName")
        let style = string("styleName").isEmpty ? "Regular" : string("styleName")
        let postscript = string("postscriptFontName").isEmpty
            ? (family + "-" + style).filter { $0.isASCII && !$0.isWhitespace } : string("postscriptFontName")
        let major = info["versionMajor"] as? Int ?? 1, minor = info["versionMinor"] as? Int ?? 0
        var names = FontSource.Names(family: family, style: style, postscript: postscript,
                                     full: string("postscriptFullName").isEmpty ? "\(family) \(style)" : string("postscriptFullName"),
                                     version: String(format: "%d.%03d", major, minor))
        names.copyright = string("copyright")
        names.trademark = string("trademark")
        names.designer = string("openTypeNameDesigner")
        names.designerURL = string("openTypeNameDesignerURL")
        names.manufacturer = string("openTypeNameManufacturer")
        names.manufacturerURL = string("openTypeNameManufacturerURL")
        names.description = string("openTypeNameDescription")
        names.sampleText = string("openTypeNameSampleText")
        names.license = string("openTypeNameLicense")
        names.licenseURL = string("openTypeNameLicenseURL")
        return names
    }

    static func metrics(_ info: [String: Any]) -> FontSource.Metrics {
        let upm = Int(number(info["unitsPerEm"]) ?? 1_000)
        let ascender = number(info["ascender"]) ?? Double(upm) * 0.8
        let descender = number(info["descender"]) ?? -Double(upm) * 0.2
        let lineGap = number(info["openTypeHheaLineGap"]) ?? 0
        return FontSource.Metrics(unitsPerEm: upm, ascender: ascender, descender: descender, xHeight: number(info["xHeight"]) ?? Double(upm) / 2,
                                  capHeight: number(info["capHeight"]) ?? Double(upm) * 0.7, italicAngle: number(info["italicAngle"]) ?? 0,
                                  underlinePosition: number(info["postscriptUnderlinePosition"]) ?? -Double(upm) / 10,
                                  underlineThickness: number(info["postscriptUnderlineThickness"]) ?? Double(upm) / 20, lineGap: lineGap,
                                  winAscent: number(info["openTypeOS2WinAscent"]), winDescent: number(info["openTypeOS2WinDescent"]),
                                  typoAscender: number(info["openTypeOS2TypoAscender"]), typoDescender: number(info["openTypeOS2TypoDescender"]),
                                  typoLineGap: number(info["openTypeOS2TypoLineGap"]))
    }

    static func os2(_ info: [String: Any]) -> FontSource.OS2 {
        let styleMap = info["styleMapStyleName"] as? String ?? ""
        var fsType: UInt16 = 0
        for bit in info["openTypeOS2Type"] as? [Int] ?? [] where (0..<16).contains(bit) { fsType |= 1 << UInt16(bit) }
        let panose = (info["openTypeOS2Panose"] as? [Int]).map { $0.map { UInt8(clamping: $0) } }
        return FontSource.OS2(weightClass: info["openTypeOS2WeightClass"] as? Int ?? 400, widthClass: info["openTypeOS2WidthClass"] as? Int ?? 5,
                              vendorID: info["openTypeOS2VendorID"] as? String ?? "WTNR", bold: styleMap.contains("bold"),
                              italic: styleMap.contains("italic"), fsType: fsType,
                              panose: panose?.count == 10 ? panose! : [UInt8](repeating: 0, count: 10))
    }

    /// The nearest of the grid's colors to a UFO color string `r,g,b,a` (0 when transparent).
    static func markColor(_ value: String) -> Int {
        let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[3] > 0 else { return 0 }
        var best = (index: 0, distance: Double.infinity)
        for (offset, color) in markPalette.enumerated() {
            let distance = pow(color.0 - parts[0], 2) + pow(color.1 - parts[1], 2) + pow(color.2 - parts[2], 2)
            if distance < best.distance { best = (offset + 1, distance) }
        }
        return best.index
    }

    // MARK: Kerning

    /// Pairs between glyphs, and class cells between groups.  A glyph kerned against a group (an
    /// exception) becomes pairs with each member, which win over the class cells as UFO kerning
    /// says; a pair of two glyphs wins over both.
    static func kerning(_ kerning: [String: [String: Any]], groups: [String: [String]], index: [String: Int], version: Int,
                        report: inout [String]) -> FontSource.Kerning {
        func isGroup(_ name: String, side: Int) -> Bool {
            guard groups[name] != nil else { return false }
            if version == 3 { return name.hasPrefix(side == 1 ? "public.kern1." : "public.kern2.") }
            return true
        }
        var result = FontSource.Kerning()
        var left: [String: Int] = [:], right: [String: Int] = [:]
        func label(_ group: String) -> String {
            for prefix in ["public.kern1.", "public.kern2.", "@MMK_L_", "@MMK_R_", "@"] where group.hasPrefix(prefix) {
                return String(group.dropFirst(prefix.count))
            }
            return group
        }
        // A glyph belongs to one class per side: the first group that takes it.
        var claimed: [Int: Set<Int>] = [1: [], 2: []]
        func classIndex(_ group: String, side: Int) -> Int {
            if let found = side == 1 ? left[group] : right[group] { return found }
            let ids = (groups[group] ?? []).compactMap { index[$0] }.filter { !claimed[side]!.contains($0) }
            claimed[side]!.formUnion(ids)
            if side == 1 {
                left[group] = result.leftClasses.count
                result.leftClasses.append(ids)
                result.leftClassNames.append(label(group))
                return result.leftClasses.count - 1
            }
            right[group] = result.rightClasses.count
            result.rightClasses.append(ids)
            result.rightClassNames.append(label(group))
            return result.rightClasses.count - 1
        }
        var entries: [(first: String, second: String, value: Int, rank: Int)] = []
        for first in kerning.keys.sorted() {
            for (second, value) in kerning[first]!.sorted(by: { $0.key < $1.key }) {
                guard let amount = number(value) else { continue }
                let leftGroup = isGroup(first, side: 1), rightGroup = isGroup(second, side: 2)
                guard leftGroup || index[first] != nil, rightGroup || index[second] != nil else {
                    report.append("The kerning pair \(first) \(second) names a glyph not in the font.")
                    continue
                }
                entries.append((first, second, Int(amount.rounded()), (leftGroup ? 1 : 0) + (rightGroup ? 1 : 0)))
            }
        }
        var paired: Set<[Int]> = []
        for entry in entries.filter({ $0.rank < 2 }).sorted(by: { $0.rank < $1.rank }) {
            let lefts = index[entry.first].map { [$0] } ?? (groups[entry.first] ?? []).compactMap { index[$0] }
            let rights = index[entry.second].map { [$0] } ?? (groups[entry.second] ?? []).compactMap { index[$0] }
            for l in lefts {
                for r in rights where paired.insert([l, r]).inserted { result.pairs.append(.init(left: l, right: r, value: entry.value)) }
            }
        }
        for entry in entries where entry.rank == 2 {
            result.classValues.append(.init(left: classIndex(entry.first, side: 1), right: classIndex(entry.second, side: 2), value: entry.value))
        }
        // Kerning groups no pair uses are classes too (UFO 3 names them), so they survive a round trip.
        for (group, _) in groups.sorted(by: { $0.key < $1.key }) where version == 3 {
            if group.hasPrefix("public.kern1.") { _ = classIndex(group, side: 1) }
            if group.hasPrefix("public.kern2.") { _ = classIndex(group, side: 2) }
        }
        return result
    }
}

/// One `.glif` file as read.
struct GlifGlyph {
    struct Component {
        var base: String
        var transform: WTGeometry.AffineTransform
    }

    var name = ""
    var advance: Double = 0
    var unicodes: [UInt32] = []
    var contours: [Contour] = []
    var components: [Component] = []
    var anchors: [FontSource.Anchor] = []
    var markColor: String?
    var note = ""
    var artwork: Data?
    /// What was not read or had to be repaired.
    var notes: [String] = []
}

/// A `.glif` parser (GLIF 1 and 2) over `XMLParser`.
final class GlifParser: NSObject, XMLParserDelegate {
    struct Point {
        var x: Double
        var y: Double
        var type: String
        var name: String?
    }

    private var glyph = GlifGlyph()
    private var contour: [Point]?
    private var inLib = false
    private var inNote = false
    private var failure: String?

    /// The glyph in `data`.
    static func parse(_ data: Data, file: String) throws -> GlifGlyph {
        let delegate = GlifParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw UFOReader.Failure.malformed("the glyph file \(file) does not parse" + (delegate.failure.map { ": \($0)" } ?? ""))
        }
        var glyph = delegate.glyph
        let lib = self.lib(in: data)
        glyph.markColor = lib?["public.markColor"] as? String
        glyph.artwork = lib?[UFOWriter.artworkKey] as? Data
        return glyph
    }

    /// `public.markColor` from the glyph's `<lib>`.
    static func markColor(in data: Data) -> String? {
        lib(in: data)?["public.markColor"] as? String
    }

    /// The glyph's `<lib>` (a property list dictionary).
    static func lib(in data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8), let open = text.range(of: "<lib>"),
              let close = text.range(of: "</lib>", range: open.upperBound..<text.endIndex) else { return nil }
        let body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\">" + text[open.upperBound..<close.lowerBound] + "</plist>"
        return try? PropertyListSerialization.propertyList(from: Data(body.utf8), format: nil) as? [String: Any]
    }

    private func number(_ attributes: [String: String], _ key: String, _ fallback: Double = 0) -> Double {
        attributes[key].flatMap(Double.init) ?? fallback
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard !inLib else { return }
        switch element {
        case "glyph":
            glyph.name = attributes["name"] ?? ""
        case "advance":
            glyph.advance = number(attributes, "width")
        case "unicode":
            if let hex = attributes["hex"], let value = UInt32(hex, radix: 16) {
                glyph.unicodes.append(value)
            } else {
                glyph.notes.append("an unreadable unicode value was left out.")
            }
        case "anchor":
            glyph.anchors.append(FontSource.Anchor(name: attributes["name"] ?? "", x: number(attributes, "x"), y: number(attributes, "y")))
        case "contour":
            contour = []
        case "point":
            contour?.append(Point(x: number(attributes, "x"), y: number(attributes, "y"), type: attributes["type"] ?? "offcurve", name: attributes["name"]))
        case "component":
            guard let base = attributes["base"] else {
                glyph.notes.append("a component without a base glyph was left out.")
                return
            }
            let transform = WTGeometry.AffineTransform(a: number(attributes, "xScale", 1), b: number(attributes, "xyScale"),
                                                       c: number(attributes, "yxScale"), d: number(attributes, "yScale", 1),
                                                       tx: number(attributes, "xOffset"), ty: number(attributes, "yOffset"))
            glyph.components.append(GlifGlyph.Component(base: base, transform: transform))
        case "lib":
            inLib = true
        case "note":
            inNote = true
        case "image":
            glyph.notes.append("the background image was not imported.")
        case "guideline":
            glyph.notes.append("a guideline was not imported.")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "lib" {
            inLib = false
            return
        }
        if element == "note" {
            inNote = false
            return
        }
        guard !inLib, element == "contour", let points = contour else { return }
        contour = nil
        // A UFO 2 anchor: one named point.
        if points.count == 1, let name = points[0].name {
            glyph.anchors.append(FontSource.Anchor(name: name, x: points[0].x, y: points[0].y))
            return
        }
        if let built = Self.contour(points) {
            glyph.contours.append(built)
        } else if !points.isEmpty {
            glyph.notes.append("a contour of \(points.count) point\(points.count == 1 ? "" : "s") could not be read and was left out.")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inNote, !inLib { glyph.note += string }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: any Error) {
        failure = error.localizedDescription
    }

    /// The contour of `points`: open when it starts with a `move`, else closed; `curve` takes the
    /// off-curve points before it as cubic controls (one: a quadratic), `qcurve` as a quadratic
    /// spline with implied on-curve midpoints; a closed contour of off-curve points only is a
    /// TrueType spline.  Nil when it has no segment.
    static func contour(_ points: [Point]) -> Contour? {
        guard !points.isEmpty else { return nil }
        func p(_ point: Point) -> WTGeometry.Point { WTGeometry.Point(x: point.x, y: point.y) }
        let open = points[0].type == "move"
        var sequence = points
        if !open {
            if let start = sequence.firstIndex(where: { $0.type != "offcurve" }) {
                sequence = Array(sequence[start...]) + Array(sequence[..<start])
            } else {
                // All off-curve: a quadratic loop from the midpoint of the last and first.
                let first = sequence[0], last = sequence[sequence.count - 1]
                sequence = [Point(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2, type: "qcurve", name: nil)] + sequence
            }
        }
        var segments: [CubicBezier] = []
        var current = p(sequence[0])
        var controls: [WTGeometry.Point] = []
        func add(_ next: Point) {
            let end = p(next)
            switch next.type {
            case "curve" where controls.count >= 2:
                segments.append(CubicBezier(current, controls[0], controls[controls.count - 1], end))
            case "curve" where controls.count == 1, "qcurve":
                var points = [current] + controls + [end]
                if points.count == 2 { points.insert(WTGeometry.Point(x: (current.x + end.x) / 2, y: (current.y + end.y) / 2), at: 1) }
                // Implied on-curve points between consecutive controls.
                var start = points[0]
                for index in 1..<(points.count - 1) {
                    let control = points[index]
                    let stop = index == points.count - 2 ? points[index + 1]
                        : WTGeometry.Point(x: (control.x + points[index + 1].x) / 2, y: (control.y + points[index + 1].y) / 2)
                    segments.append(QuadraticBezier(start, control, stop).elevated())
                    start = stop
                }
            default:
                if end != current { segments.append(Line(start: current, end: end).elevated()) }
            }
            current = end
            controls = []
        }
        for point in sequence.dropFirst() {
            if point.type == "offcurve" {
                controls.append(p(point))
            } else {
                add(point)
            }
        }
        // A closed contour returns to its start as the start point's type says, through the
        // off-curve points after the last on-curve one.
        if !open, !controls.isEmpty || current != p(sequence[0]) {
            add(sequence[0])
        }
        return segments.isEmpty ? nil : Contour(segments: segments, closed: !open)
    }
}
