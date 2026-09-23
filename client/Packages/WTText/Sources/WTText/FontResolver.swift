// Character attributes to Core Text fonts (type-specifications, "Layout" and "Axes and
// features"): the family and face by descriptor, the size, a horizontal scale as the font
// matrix, variation axes through `kCTFontVariationAttribute` and OpenType features through
// `kCTFontFeatureSettingsAttribute` (OFF writes value 0 so an on-by-default feature turns off).
// Missing families fall back to Core Text's default until TXT-002's substitution table.

import CoreText
import Foundation

/// The family laid out when a run names none.
let defaultFontFamily = "Helvetica"

final class FontResolver: @unchecked Sendable {
    static let shared = FontResolver()

    private struct Key: Hashable {
        let family: String
        let style: String?
        let size: Double
        let horizontalScale: Double
        let features: [String: FeatureState]
        let axes: [String: Double]
        let smallCaps: Bool
        let upright: Bool
    }

    private let lock = NSLock()
    private var fonts: [Key: CTFont] = [:]

    /// The font for `attributes`; `upright` adds the `vert` feature (vertical alternates for
    /// characters set upright in vertical text).
    func font(for attributes: TextAttributes, upright: Bool = false) -> CTFont {
        let key = Key(
            family: attributes.fontFamily ?? defaultFontFamily,
            style: attributes.fontStyle,
            size: max(attributes.size, 0.01),
            horizontalScale: attributes.horizontalScale > 0 ? attributes.horizontalScale / 100 : 1,
            features: attributes.features,
            axes: attributes.axes,
            smallCaps: attributes.smallCaps,
            upright: upright
        )
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[key] {
            return font
        }
        let font = FontResolver.make(key)
        fonts[key] = font
        return font
    }

    private static func make(_ key: Key) -> CTFont {
        var descriptorAttributes: [CFString: Any] = [kCTFontFamilyNameAttribute: key.family]
        if let style = key.style {
            descriptorAttributes[kCTFontStyleNameAttribute] = style
        }
        var features: [[CFString: Any]] = []
        var settings = key.features
        if key.smallCaps {
            settings["smcp"] = .on
        }
        if key.upright {
            settings["vert"] = .on
        }
        for (tag, state) in settings.sorted(by: { $0.key < $1.key }) {
            switch state {
            case .default: continue
            case .on: features.append([kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: 1])
            case .off: features.append([kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: 0])
            }
        }
        if !features.isEmpty {
            descriptorAttributes[kCTFontFeatureSettingsAttribute] = features
        }
        let variation = Dictionary(uniqueKeysWithValues: key.axes.compactMap { tag, value in
            fourCharCode(tag).map { (NSNumber(value: $0), NSNumber(value: value)) }
        })
        if !variation.isEmpty {
            descriptorAttributes[kCTFontVariationAttribute] = variation
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(descriptorAttributes as CFDictionary)
        var matrix = CGAffineTransform(scaleX: CGFloat(key.horizontalScale), y: 1)
        return CTFontCreateWithFontDescriptor(descriptor, CGFloat(key.size), &matrix)
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
