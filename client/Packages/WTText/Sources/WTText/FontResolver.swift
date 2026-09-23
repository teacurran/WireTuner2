// Character attributes to Core Text fonts (type-specifications, "Layout" and "Axes and
// features"; TYPE-021, TYPE-047).  The family and face by descriptor; a face the family lacks
// by its traits, and failing those synthesized (a slant in the font matrix, a heavier stroke
// drawn by WTText); a family that is not installed falls back to the default family until
// TXT-002's substitution table.  Variation axes go through `kCTFontVariationAttribute` --
// clamped to the resolved font's ranges, tags it lacks dropped -- with automatic optical size
// while `opsz` is unset; OpenType features go through `kCTFontFeatureSettingsAttribute`, OFF
// writing value 0 so an on-by-default feature turns off, tags the font lacks dropped.  What
// was dropped, synthesized or substituted is reported for the Missing Fonts sheet.
//
// Fonts are cached by (family, style, size, horizontal scale, axis tuple, feature set).

import CoreText
import Foundation

/// The family laid out when a run names none, or names one that is not installed.
let defaultFontFamily = "Helvetica"

/// A family and face as the document names them.
public struct FaceName: Hashable, Sendable, CustomStringConvertible {
    public var family: String
    public var style: String?

    public init(family: String, style: String? = nil) {
        self.family = family
        self.style = style
    }

    public var description: String { style.map { "\(family) \($0)" } ?? family }
}

/// What layout could not honour in the fonts a flow names (the Missing Fonts sheet, TXT-002):
/// families not installed, faces drawn synthesized, and variation axes and OpenType features
/// the resolved (or substitute) font lacks.  The marks themselves are untouched.
public struct FontReport: Hashable, Sendable {
    public var missingFamilies: Set<String> = []
    public var synthesizedFaces: Set<FaceName> = []
    public var droppedAxes: [FaceName: Set<String>] = [:]
    public var droppedFeatures: [FaceName: Set<String>] = [:]

    public init() {}

    public var isEmpty: Bool {
        missingFamilies.isEmpty && synthesizedFaces.isEmpty && droppedAxes.isEmpty && droppedFeatures.isEmpty
    }

    mutating func merge(_ other: FontReport) {
        missingFamilies.formUnion(other.missingFamilies)
        synthesizedFaces.formUnion(other.synthesizedFaces)
        droppedAxes.merge(other.droppedAxes) { $0.union($1) }
        droppedFeatures.merge(other.droppedFeatures) { $0.union($1) }
    }
}

/// A run's font as resolved.
struct ResolvedFont: @unchecked Sendable {
    let font: CTFont
    /// The width of the stroke that synthesizes a bold face (points); 0 for a real face.
    let emboldening: Double
    let report: FontReport
}

final class FontResolver: @unchecked Sendable {
    static let shared = FontResolver()

    /// A synthesized oblique's slant: tan 12°.
    static let syntheticObliqueness = 0.2126
    /// A synthesized bold's stroke width, as a fraction of the size.
    static let syntheticEmboldening = 0.04

    private struct Key: Hashable {
        let family: String
        let style: String?
        let size: Double
        let horizontalScale: Double
        let features: [String: FeatureState]
        let axes: [String: Double]
        let upright: Bool
    }

    private let lock = NSLock()
    /// Serializes font creation: concurrent font-matching requests from many threads have hung
    /// in the font registry's XPC reply (observed under parallel tests), and misses are rare.
    private let creation = NSLock()
    private var fonts: [Key: ResolvedFont] = [:]
    private var families: Set<String>?
    private var featureTags: [String: Set<String>] = [:]

    /// The font for `attributes` and whether it came from the cache; `upright` adds the `vert`
    /// feature (vertical alternates for characters set upright in vertical text).
    func resolve(_ attributes: TextAttributes, upright: Bool = false) -> (font: ResolvedFont, hit: Bool) {
        let key = Key(
            family: attributes.fontFamily ?? defaultFontFamily,
            style: attributes.fontStyle,
            size: attributes.size,
            horizontalScale: attributes.horizontalScale > 0 ? attributes.horizontalScale / 100 : 1,
            features: attributes.features,
            axes: attributes.axes,
            upright: upright
        )
        lock.lock()
        if let font = fonts[key] {
            lock.unlock()
            return (font, true)
        }
        lock.unlock()
        creation.lock()
        defer { creation.unlock() }
        lock.lock()
        if let font = fonts[key] {
            lock.unlock()
            return (font, true)
        }
        lock.unlock()
        let font = make(key)
        lock.lock()
        fonts[key] = font
        lock.unlock()
        return (font, false)
    }

    /// The Core Text font for `attributes`.
    func font(for attributes: TextAttributes, upright: Bool = false) -> CTFont {
        resolve(attributes, upright: upright).font.font
    }

    // MARK: Faces

    private func make(_ key: Key) -> ResolvedFont {
        var report = FontReport()
        let name = FaceName(family: key.family, style: key.style)
        var family = key.family
        if !isInstalled(family) {
            report.missingFamilies.insert(family)
            family = defaultFontFamily
        }
        // The named face, or the family's default face and its traits.
        var base: CTFont
        var obliqueness = 0.0
        var emboldening = 0.0
        if let style = key.style, let face = FontResolver.face(family: family, style: style, size: key.size) {
            base = face
        } else {
            base = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary), CGFloat(key.size), nil)
            if let style = key.style?.lowercased() {
                var wanted: CTFontSymbolicTraits = []
                if style.contains("bold") || style.contains("black") || style.contains("heavy") {
                    wanted.insert(.traitBold)
                }
                if style.contains("italic") || style.contains("oblique") {
                    wanted.insert(.traitItalic)
                }
                if !wanted.isEmpty, let traited = CTFontCreateCopyWithSymbolicTraits(base, CGFloat(key.size), nil, wanted, wanted) {
                    base = traited
                }
                let traits = CTFontGetSymbolicTraits(base)
                if wanted.contains(.traitBold) && !traits.contains(.traitBold) {
                    emboldening = key.size * FontResolver.syntheticEmboldening
                }
                if wanted.contains(.traitItalic) && !traits.contains(.traitItalic) {
                    obliqueness = FontResolver.syntheticObliqueness
                }
                if emboldening > 0 || obliqueness != 0 {
                    report.synthesizedFaces.insert(name)
                }
            }
        }

        var attributes: [CFString: Any] = [:]
        // Axes: clamped to the resolved font's ranges; tags it lacks are dropped.
        let axes = FontResolver.axes(of: base)
        // Layered over the named instance the face already is.
        var variation: [NSNumber: NSNumber] = [:]
        if !key.axes.isEmpty, let instance = CTFontCopyVariation(base) as? [NSNumber: NSNumber] {
            variation = instance
        }
        for (tag, value) in key.axes.sorted(by: { $0.key < $1.key }) {
            guard let code = fourCharCode(tag), let range = axes[code] else {
                report.droppedAxes[name, default: []].insert(tag)
                continue
            }
            variation[NSNumber(value: code)] = NSNumber(value: min(max(value, range.lowerBound), range.upperBound))
        }
        if !variation.isEmpty {
            attributes[kCTFontVariationAttribute] = variation
        }
        // Optical size follows the type size while `opsz` is unset.
        if key.axes["opsz"] == nil, let opsz = fourCharCode("opsz"), axes[opsz] != nil {
            attributes[kCTFontOpticalSizeAttribute] = "auto" as CFString
        }
        // Features the font offers; `vert` is WTText's own and always applies.
        let offered = featureTags(of: base)
        var settings: [[CFString: Any]] = []
        var requested = key.features
        if key.upright {
            requested["vert"] = .on
        }
        for (tag, state) in requested.sorted(by: { $0.key < $1.key }) where state != .default {
            guard tag == "vert" || offered.contains(tag) else {
                report.droppedFeatures[name, default: []].insert(tag)
                continue
            }
            settings.append([kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: state == .on ? 1 : 0])
        }
        if !settings.isEmpty {
            attributes[kCTFontFeatureSettingsAttribute] = settings
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attributes as CFDictionary)
        var matrix = CGAffineTransform(a: CGFloat(key.horizontalScale), b: 0, c: CGFloat(obliqueness), d: 1, tx: 0, ty: 0)
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(key.size), &matrix)
        return ResolvedFont(font: font, emboldening: emboldening, report: report)
    }

    /// The face of `family` whose style name is `style` (ignoring case), if installed: the font
    /// the descriptor asks for, when Core Text found that very face.
    private static func face(family: String, style: String, size: Double) -> CTFont? {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family, kCTFontStyleNameAttribute: style] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(size), nil)
        let found = (CTFontCopyName(font, kCTFontStyleNameKey) as String?)?.lowercased()
        return CTFontCopyFamilyName(font) as String == family && found == style.lowercased() ? font : nil
    }

    /// Whether `family` is among the families macOS can load (read once).
    private func isInstalled(_ family: String) -> Bool {
        if families == nil {
            families = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        }
        return families?.contains(family) ?? false
    }

    // MARK: Axes and features

    /// The font's variation axes: range by tag.
    static func axes(of font: CTFont) -> [UInt32: ClosedRange<Double>] {
        guard let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] else {
            return [:]
        }
        var result: [UInt32: ClosedRange<Double>] = [:]
        for axis in axes {
            guard let tag = (axis[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value,
                  let low = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue,
                  let high = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue
            else {
                continue
            }
            result[tag] = min(low, high)...max(low, high)
        }
        return result
    }

    /// The OpenType feature tags the font offers: its GSUB and GPOS feature lists, and the
    /// tags Core Text reports for its AAT features.
    func featureTags(of font: CTFont) -> Set<String> {
        let name = CTFontCopyPostScriptName(font) as String
        lock.lock()
        if let known = featureTags[name] {
            lock.unlock()
            return known
        }
        lock.unlock()
        var tags = FontResolver.layoutFeatureTags(font, table: CTFontTableTag(kCTFontTableGSUB))
            .union(FontResolver.layoutFeatureTags(font, table: CTFontTableTag(kCTFontTableGPOS)))
        for feature in CTFontCopyFeatures(font) as? [[CFString: Any]] ?? [] {
            let type = (feature[kCTFontFeatureTypeIdentifierKey] as? NSNumber)?.intValue ?? -1
            for selector in feature[kCTFontFeatureTypeSelectorsKey] as? [[CFString: Any]] ?? [] {
                if let tag = selector[kCTFontOpenTypeFeatureTag] as? String {
                    tags.insert(tag)
                } else if let identifier = (selector[kCTFontFeatureSelectorIdentifierKey] as? NSNumber)?.intValue,
                          let tag = FontResolver.aatFeatureTag(type: type, selector: identifier) {
                    tags.insert(tag)
                }
            }
        }
        lock.lock()
        featureTags[name] = tags
        lock.unlock()
        return tags
    }

    /// The OpenType tag Core Text maps an AAT feature selector to (Apple's font feature
    /// registry: the "on" selectors of the features the Character section offers).
    static func aatFeatureTag(type: Int, selector: Int) -> String? {
        switch (type, selector) {
        case (1, 2): return "liga"                      // Ligatures: common
        case (1, 4): return "dlig"                      // Ligatures: rare
        case (1, 18): return "clig"                     // Ligatures: contextual
        case (3, 3), (37, 1): return "smcp"             // Letter case / lower case: small caps
        case (38, 1): return "c2sc"                     // Upper case: small caps
        case (6, 0): return "tnum"                      // Number spacing: monospaced
        case (6, 1): return "pnum"                      // Number spacing: proportional
        case (21, 0): return "onum"                     // Number case: lower case
        case (21, 1): return "lnum"                     // Number case: upper case
        case (11, 1), (11, 2): return "frac"            // Fractions
        case (8, _), (36, 2): return "swsh"             // Smart swash; swash alternates
        case (36, 0): return "calt"                     // Contextual alternates
        case (35, let on) where on >= 2 && on <= 40 && on % 2 == 0:
            return String(format: "ss%02d", on / 2)     // Stylistic alternatives one to twenty
        default: return nil
        }
    }

    /// The feature tags of a GSUB or GPOS table's FeatureList.
    static func layoutFeatureTags(_ font: CTFont, table: CTFontTableTag) -> Set<String> {
        guard let data = CTFontCopyTable(font, table, []) as Data? else {
            return []
        }
        return layoutFeatureTags(in: [UInt8](data))
    }

    /// The feature tags in a GSUB or GPOS table's bytes (header: version, ScriptList offset,
    /// FeatureList offset; FeatureList: count, then (tag, offset) records).
    static func layoutFeatureTags(in bytes: [UInt8]) -> Set<String> {
        func u16(_ offset: Int) -> Int? {
            offset + 1 < bytes.count ? Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) : nil
        }
        guard let list = u16(6), let count = u16(list) else {
            return []
        }
        var tags = Set<String>()
        for index in 0..<count {
            let record = list + 2 + index * 6
            guard record + 4 <= bytes.count, let tag = String(bytes: bytes[record..<record + 4], encoding: .ascii) else {
                break
            }
            tags.insert(tag)
        }
        return tags
    }
}

/// A four-character OpenType tag as its big-endian integer; nil unless exactly four ASCII
/// characters.
func fourCharCode(_ tag: String) -> UInt32? {
    let bytes = Array(tag.utf8)
    guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else {
        return nil
    }
    return bytes.reduce(0) { $0 << 8 | UInt32($1) }
}
