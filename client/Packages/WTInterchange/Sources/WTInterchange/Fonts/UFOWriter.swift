// FONT-023: writing a UFO 3 package (font-export.adoc, "UFO packages" and "Client", UFO) --
// `metainfo.plist`, `fontinfo.plist` (the keys `UFOReader` reads back), `layercontents.plist` and
// the default layer (`glyphs/contents.plist` with a GLIF 2 file per glyph: advance, unicodes, note,
// anchors, contours with `move`/`line`/`curve`/`offcurve` points, components with their six
// numbers, and a lib with `public.markColor` and, for an as-drawn export, the artwork), `groups.plist`
// and `kerning.plist` (`public.kern1.<name>` / `public.kern2.<name>` groups; glyph pairs, glyph
// against group and group pairs as the model's lookup gives them), `features.fea` and `lib.plist`
// (`public.glyphOrder`, `public.openTypeCategories`, and the imported package's unread keys written
// back).  Output is deterministic: property lists with sorted keys, glyph files named by the UFO 3
// user-name convention, numbers written as integers when whole.  WTModel builds the package
// (`UFOExport`); nothing here reads the document.

import Foundation
import WTGeometry

/// Everything a UFO export writes.
public struct UFOPackage: Hashable, Sendable {
    /// A component: another glyph of the package placed by an affine transform (font units, y up).
    public struct Component: Hashable, Sendable {
        public var base: String
        public var transform: AffineTransform

        public init(base: String, transform: AffineTransform = .identity) {
            self.base = base
            self.transform = transform
        }
    }

    public struct Glyph: Hashable, Sendable {
        public var name: String
        public var codepoints: [UInt32]
        public var advanceWidth: Double
        /// Font units, y up; open contours are written with a `move` point.
        public var contours: [Contour]
        public var components: [Component]
        public var anchors: [FontSource.Anchor]
        public var note: String
        /// The grid's mark color index (1 ... 12), 0 for none.
        public var markColor: Int
        public var kind: FontSource.GlyphKind
        /// The as-drawn artwork as a pasteboard payload, written to the glyph's lib.
        public var artwork: Data?

        public init(name: String, codepoints: [UInt32] = [], advanceWidth: Double, contours: [Contour] = [], components: [Component] = [],
                    anchors: [FontSource.Anchor] = [], note: String = "", markColor: Int = 0, kind: FontSource.GlyphKind = .base, artwork: Data? = nil) {
            self.name = name
            self.codepoints = codepoints
            self.advanceWidth = advanceWidth
            self.contours = contours
            self.components = components
            self.anchors = anchors
            self.note = note
            self.markColor = markColor
            self.kind = kind
            self.artwork = artwork
        }
    }

    public var names: FontSource.Names
    public var metrics: FontSource.Metrics
    public var os2: FontSource.OS2
    /// In glyph order.
    public var glyphs: [Glyph]
    /// Indices into `glyphs`; the class names are the groups' names after their prefix.
    public var kerning: FontSource.Kerning
    /// `features.fea` as written (the user's text, plus the generated features when asked).
    public var features: String
    /// Keys an imported package carried that nothing reads, as a binary property list; written
    /// back into `lib.plist` under the keys written here.
    public var lib: Data?

    public init(names: FontSource.Names, metrics: FontSource.Metrics = .init(), os2: FontSource.OS2 = .init(), glyphs: [Glyph],
                kerning: FontSource.Kerning = .init(), features: String = "", lib: Data? = nil) {
        self.names = names
        self.metrics = metrics
        self.os2 = os2
        self.glyphs = glyphs
        self.kerning = kerning
        self.features = features
        self.lib = lib
    }
}

/// Writes UFO 3 packages.
public enum UFOWriter {
    /// `metainfo.plist`'s creator.
    public static let creator = "com.villagecompute.wiretuner"
    /// The glyph lib key holding the as-drawn artwork (a pasteboard payload).
    public static let artworkKey = "com.villagecompute.wiretuner.artwork"
    /// The lib key of the glyphs' OpenType categories.
    public static let categoriesKey = "public.openTypeCategories"

    /// Writes `package` at `url`, replacing what is there.
    public static func write(_ package: UFOPackage, to url: URL) throws {
        let files = try files(package)
        let manager = FileManager.default
        let staging = url.deletingLastPathComponent().appending(component: ".\(url.lastPathComponent)-\(UUID().uuidString)")
        try manager.createDirectory(at: staging.appending(component: "glyphs"), withIntermediateDirectories: true)
        do {
            for (path, data) in files { try data.write(to: staging.appending(path: path)) }
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: url)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// The package's files by path inside the package.
    public static func files(_ package: UFOPackage) throws -> [String: Data] {
        var files: [String: Data] = [:]
        files["metainfo.plist"] = try plist(["creator": creator, "formatVersion": 3])
        files["fontinfo.plist"] = try plist(fontInfo(package))
        files["layercontents.plist"] = try plist([["public.default", "glyphs"]])
        var contents: [String: String] = [:]
        var taken: Set<String> = []
        for glyph in package.glyphs where contents[glyph.name] == nil {
            let file = fileName(glyph.name, taken: taken)
            taken.insert(file.lowercased())
            contents[glyph.name] = file
            files["glyphs/\(file)"] = try glif(glyph)
        }
        files["glyphs/contents.plist"] = try plist(contents)
        let (groups, kerning) = self.kerning(package)
        if !groups.isEmpty { files["groups.plist"] = try plist(groups) }
        if !kerning.isEmpty { files["kerning.plist"] = try plist(kerning) }
        if !package.features.isEmpty { files["features.fea"] = Data(package.features.utf8) }
        files["lib.plist"] = try plist(lib(package))
        return files
    }

    // MARK: Font info

    static func fontInfo(_ package: UFOPackage) -> [String: Any] {
        let n = package.names, m = package.metrics, o = package.os2
        var info: [String: Any] = [
            "familyName": n.family, "styleName": n.style, "postscriptFontName": n.postscript, "postscriptFullName": n.full,
            "styleMapFamilyName": n.family,
            "styleMapStyleName": o.bold && o.italic ? "bold italic" : o.bold ? "bold" : o.italic ? "italic" : "regular",
            "unitsPerEm": m.unitsPerEm, "ascender": value(m.ascender), "descender": value(m.descender), "xHeight": value(m.xHeight),
            "capHeight": value(m.capHeight), "italicAngle": value(m.italicAngle), "postscriptUnderlinePosition": value(m.underlinePosition),
            "postscriptUnderlineThickness": value(m.underlineThickness), "openTypeHheaAscender": value(m.ascender),
            "openTypeHheaDescender": value(m.descender), "openTypeHheaLineGap": value(m.lineGap), "openTypeOS2TypoAscender": value(m.typoAscender),
            "openTypeOS2TypoDescender": value(m.typoDescender), "openTypeOS2TypoLineGap": value(m.typoLineGap),
            "openTypeOS2WeightClass": o.weightClass, "openTypeOS2WidthClass": o.widthClass, "openTypeOS2VendorID": o.vendorID,
            "openTypeOS2Type": (0..<16).filter { o.fsType & (1 << UInt16($0)) != 0 }, "openTypeOS2Panose": o.panose.map(Int.init),
        ]
        let version = self.version(n.version)
        info["versionMajor"] = version.major
        info["versionMinor"] = version.minor
        if let winAscent = m.winAscent { info["openTypeOS2WinAscent"] = value(winAscent) }
        if let winDescent = m.winDescent { info["openTypeOS2WinDescent"] = value(winDescent) }
        let strings: [(String, String)] = [
            ("copyright", n.copyright), ("trademark", n.trademark), ("openTypeNameDesigner", n.designer), ("openTypeNameDesignerURL", n.designerURL),
            ("openTypeNameManufacturer", n.manufacturer), ("openTypeNameManufacturerURL", n.manufacturerURL),
            ("openTypeNameDescription", n.description), ("openTypeNameSampleText", n.sampleText), ("openTypeNameLicense", n.license),
            ("openTypeNameLicenseURL", n.licenseURL),
        ]
        for (key, string) in strings where !string.isEmpty { info[key] = string }
        return info
    }

    /// "1.005" → (1, 5): the minor part is the digits after the point, read as thousandths.
    static func version(_ text: String) -> (major: Int, minor: Int) {
        let parts = text.split(separator: ".", maxSplits: 1).map(String.init)
        let major = parts.first.flatMap { Int($0) } ?? 1
        guard parts.count == 2 else { return (max(major, 0), 0) }
        let digits = String(parts[1].prefix { $0.isASCII && $0.isNumber }.prefix(3))
        let padded = digits.padding(toLength: 3, withPad: "0", startingAt: 0)
        return (max(major, 0), Int(padded) ?? 0)
    }

    /// A whole value as an integer, else the double.
    static func value(_ number: Double) -> Any {
        number.isFinite && number == number.rounded() && abs(number) < 1e15 ? Int(number) as Any : number as Any
    }

    // MARK: Kerning

    /// `groups.plist` and `kerning.plist`: every class as a group, the class values between
    /// groups, the pairs between glyphs.
    static func kerning(_ package: UFOPackage) -> (groups: [String: [String]], kerning: [String: [String: Int]]) {
        let kerning = package.kerning
        let glyphs = package.glyphs
        func names(_ classes: [[Int]], given: [String], prefix: String) -> [String?] {
            var used: Set<String> = []
            return classes.enumerated().map { offset, members in
                let kept = members.filter { glyphs.indices.contains($0) }
                guard !kept.isEmpty else { return nil }
                let label = offset < given.count && !given[offset].isEmpty ? given[offset] : glyphs[kept[0]].name
                var name = prefix + label
                var suffix = 2
                while used.contains(name) {
                    name = "\(prefix)\(label)_\(suffix)"
                    suffix += 1
                }
                used.insert(name)
                return name
            }
        }
        let left = names(kerning.leftClasses, given: kerning.leftClassNames, prefix: "public.kern1.")
        let right = names(kerning.rightClasses, given: kerning.rightClassNames, prefix: "public.kern2.")
        var groups: [String: [String]] = [:]
        for (offset, name) in left.enumerated() {
            if let name { groups[name] = kerning.leftClasses[offset].filter { glyphs.indices.contains($0) }.map { glyphs[$0].name } }
        }
        for (offset, name) in right.enumerated() {
            if let name { groups[name] = kerning.rightClasses[offset].filter { glyphs.indices.contains($0) }.map { glyphs[$0].name } }
        }
        var table: [String: [String: Int]] = [:]
        for cell in kerning.classValues {
            guard left.indices.contains(cell.left), right.indices.contains(cell.right), let l = left[cell.left], let r = right[cell.right] else { continue }
            table[l, default: [:]][r] = cell.value
        }
        for pair in kerning.pairs where glyphs.indices.contains(pair.left) && glyphs.indices.contains(pair.right) {
            table[glyphs[pair.left].name, default: [:]][glyphs[pair.right].name] = pair.value
        }
        return (groups, table)
    }

    // MARK: Lib

    static func lib(_ package: UFOPackage) -> [String: Any] {
        var lib: [String: Any] = [:]
        if let data = package.lib, let kept = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            lib = kept
        }
        lib["public.glyphOrder"] = package.glyphs.map(\.name)
        var categories: [String: String] = [:]
        for glyph in package.glyphs where glyph.kind != .base {
            categories[glyph.name] = category(glyph.kind)
        }
        lib[categoriesKey] = categories.isEmpty ? nil : categories
        return lib
    }

    /// The `public.openTypeCategories` value of `kind`.
    public static func category(_ kind: FontSource.GlyphKind) -> String {
        switch kind {
        case .base: "base"
        case .ligature: "ligature"
        case .mark: "mark"
        case .component: "component"
        }
    }

    /// The kind a `public.openTypeCategories` value names (nil for `unassigned` and unknown words).
    public static func kind(category: String) -> FontSource.GlyphKind? {
        FontSource.GlyphKind.allCases.first { self.category($0) == category }
    }

    // MARK: Glyph files

    /// The UFO 3 user-name-to-file-name convention: illegal characters and a leading period as
    /// `_`, an underscore after each capital, reserved device names prefixed, and a counter when
    /// the name is taken ignoring case (`taken` holds lowercased file names).
    static func fileName(_ name: String, taken: Set<String>) -> String {
        let illegal = Set("\"*+/:<>?[\\]|".unicodeScalars)
        var body = ""
        for (offset, scalar) in name.unicodeScalars.enumerated() {
            if scalar.value < 0x20 || scalar.value == 0x7F || illegal.contains(scalar) || (offset == 0 && scalar == ".") {
                body += "_"
            } else if scalar.properties.isUppercase {
                body += String(scalar) + "_"
            } else {
                body.unicodeScalars.append(scalar)
            }
        }
        let reserved: Set<String> = ["con", "prn", "aux", "clock$", "nul", "a:-z:", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
                                     "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]
        body = body.split(separator: ".", omittingEmptySubsequences: false).map { reserved.contains($0.lowercased()) ? "_" + $0 : String($0) }
            .joined(separator: ".")
        body = String(body.prefix(255 - 5 - 15))
        var candidate = body + ".glif"
        var counter = 1
        while taken.contains(candidate.lowercased()) {
            candidate = body + String(format: "%015d", counter) + ".glif"
            counter += 1
        }
        return candidate
    }

    /// A number as GLIF writes it: an integer when whole, else at most four decimals.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 10_000).rounded() / 10_000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
        var text = String(format: "%.4f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // XML 1.0 has no other control characters.
                if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// The glyph's GLIF 2 file.
    static func glif(_ glyph: UFOPackage.Glyph) throws -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<glyph name=\"\(escape(glyph.name))\" format=\"2\">\n"
        xml += "  <advance width=\"\(number(glyph.advanceWidth))\"/>\n"
        for codepoint in glyph.codepoints { xml += "  <unicode hex=\"\(String(format: "%04X", codepoint))\"/>\n" }
        if !glyph.note.isEmpty { xml += "  <note>\(escape(glyph.note))</note>\n" }
        for anchor in glyph.anchors {
            xml += "  <anchor x=\"\(number(anchor.x))\" y=\"\(number(anchor.y))\" name=\"\(escape(anchor.name))\"/>\n"
        }
        let contours = glyph.contours.filter { !$0.isEmpty }
        if !contours.isEmpty || !glyph.components.isEmpty {
            xml += "  <outline>\n"
            for contour in contours { xml += self.contour(contour) }
            for component in glyph.components {
                let t = component.transform
                var attributes = "base=\"\(escape(component.base))\""
                for (key, value, identity) in [("xScale", t.a, 1.0), ("xyScale", t.b, 0), ("yxScale", t.c, 0), ("yScale", t.d, 1), ("xOffset", t.tx, 0),
                                               ("yOffset", t.ty, 0)] where number(value) != number(identity) {
                    attributes += " \(key)=\"\(number(value))\""
                }
                xml += "    <component \(attributes)/>\n"
            }
            xml += "  </outline>\n"
        }
        var lib: [String: Any] = [:]
        if glyph.markColor > 0, glyph.markColor <= UFOReader.markPalette.count {
            let color = UFOReader.markPalette[glyph.markColor - 1]
            lib["public.markColor"] = "\(number(color.0)),\(number(color.1)),\(number(color.2)),1"
        }
        if let artwork = glyph.artwork { lib[artworkKey] = artwork }
        if !lib.isEmpty {
            let data = try PropertyListSerialization.data(fromPropertyList: lib, format: .xml, options: 0)
            let text = String(decoding: data, as: UTF8.self)
            // The property list's `<dict>` element, indented under `<lib>`.
            if let open = text.range(of: "<dict>"), let close = text.range(of: "</dict>", options: .backwards) {
                let body = text[open.lowerBound..<close.upperBound].split(separator: "\n", omittingEmptySubsequences: false)
                xml += "  <lib>\n" + body.map { "    " + $0 }.joined(separator: "\n") + "\n  </lib>\n"
            }
        }
        xml += "</glyph>\n"
        return Data(xml.utf8)
    }

    /// One contour's points: a closed contour starts at its start point (typed by the segment
    /// that returns to it, the controls of that segment written last); an open one with `move`.
    static func contour(_ contour: Contour) -> String {
        func point(_ p: Point, _ type: String?) -> String {
            "      <point x=\"\(number(p.x))\" y=\"\(number(p.y))\"" + (type.map { " type=\"\($0)\"" } ?? "") + "/>\n"
        }
        var segments = contour.segments
        let start = segments[0].p0
        if contour.isClosed, let closing = contour.closingSegment { segments.append(closing) }
        var xml = "    <contour>\n"
        let closedAtStart = contour.isClosed && segments.count > 1
        if closedAtStart {
            xml += point(start, segments[segments.count - 1].isLinear() ? "line" : "curve")
        } else {
            xml += point(start, contour.isClosed ? "line" : "move")
        }
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            if segment.isLinear() {
                if !(isLast && closedAtStart) { xml += point(segment.p3, "line") }
            } else {
                xml += point(segment.p1, nil) + point(segment.p2, nil)
                if !(isLast && closedAtStart) { xml += point(segment.p3, "curve") }
            }
        }
        return xml + "    </contour>\n"
    }

    static func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
}
