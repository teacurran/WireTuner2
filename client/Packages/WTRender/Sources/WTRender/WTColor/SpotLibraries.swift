// Spot colour libraries and their preview (CMS-014; docs/_includes/cms/color-tables.adoc, "Spot
// preview").  A library is app data, never document data: one `SpotLibrary` resource per library
// (`Resources/SpotLibraries/<id>.binpb`, generated at build time by tools/spot-libraries from the
// vendor's data files), read lazily by `SpotLibraryStore`.  A swatch stores only the library id,
// the ink name and its nominal values; its chip is previewed from the library's measured Lab
// (managed) or from the nominal CMYK mix (unmanaged, or when the library or ink is not here).
//
// The resource is the sketched protobuf message, encoded and decoded by hand here in exactly its
// wire format (SpotLibrary: id 1, name 2, version 3, inks 4; SpotInk: name 1, lab_l 2, lab_a 3,
// lab_b 4, c 5, m 6, y 7, k 8, the numbers `float`) -- the format is a bundle resource, not API,
// so it is not in proto/ and no generated code is needed for eight fields.

import CoreGraphics
import Foundation

extension WTColor {
    /// One spot colour library (`SpotLibrary` of color-tables.adoc).
    public struct SpotLibrary: Hashable, Sendable {
        /// One ink of a library (`SpotInk`).
        public struct Ink: Hashable, Sendable {
            /// The ink's name, the value a swatch stores ("PANTONE 300 C").
            public var name: String
            /// Measured CIELAB, D50, 2° observer.
            public var lab: SIMD3<Double>
            /// Nominal process equivalent, inks 0...1.
            public var cmyk: SIMD4<Double>

            public init(name: String, lab: SIMD3<Double>, cmyk: SIMD4<Double>) {
                self.name = name
                self.lab = lab
                self.cmyk = cmyk
            }
        }

        /// Stable id ("pantone-solid-coated"): the value a swatch's `library` stores.
        public var id: String
        /// Shown in the Swatches library menu.
        public var name: String
        /// The vendor's edition, shown in About.
        public var version: String
        public var inks: [Ink]

        public init(id: String, name: String, version: String = "", inks: [Ink]) {
            self.id = id
            self.name = name
            self.version = version
            self.inks = inks
        }

        /// The ink named `name`.
        public func ink(named name: String) -> Ink? {
            inks.first { $0.name == name }
        }

        /// The development library shipped until vendor data is licensed (decisions.adoc D-072):
        /// six inks with invented Lab values, all inside sRGB, and plausible nominal mixes.
        public static let placeholder = SpotLibrary(id: "wiretuner-development", name: "WireTuner Development Spot", version: "1", inks: [
            Ink(name: "WT Dev Red", lab: SIMD3(48, 68, 48), cmyk: SIMD4(0, 0.95, 0.85, 0.05)),
            Ink(name: "WT Dev Blue", lab: SIMD3(32, 20, -62), cmyk: SIMD4(1, 0.8, 0, 0.05)),
            Ink(name: "WT Dev Green", lab: SIMD3(58, -46, 24), cmyk: SIMD4(0.8, 0, 0.75, 0.1)),
            Ink(name: "WT Dev Yellow", lab: SIMD3(88, -4, 80), cmyk: SIMD4(0.03, 0.08, 0.95, 0)),
            Ink(name: "WT Dev Violet", lab: SIMD3(38, 44, -40), cmyk: SIMD4(0.55, 0.85, 0, 0)),
            Ink(name: "WT Dev Gray", lab: SIMD3(60, 0, 0), cmyk: SIMD4(0, 0, 0, 0.55)),
        ])

        // MARK: Resource format

        /// The resource bytes (protobuf wire format of the sketched message).
        public func encoded() -> Data {
            var out = Data()
            SpotWire.string(1, id, into: &out)
            SpotWire.string(2, name, into: &out)
            SpotWire.string(3, version, into: &out)
            for ink in inks {
                var record = Data()
                SpotWire.string(1, ink.name, into: &record)
                for (field, value) in zip(2...8, [ink.lab.x, ink.lab.y, ink.lab.z, ink.cmyk.x, ink.cmyk.y, ink.cmyk.z, ink.cmyk.w]) {
                    SpotWire.float(UInt64(field), value, into: &record)
                }
                SpotWire.bytes(4, record, into: &out)
            }
            return out
        }

        /// The library `data` encodes; nil when it is not one (truncated, wrong wire types).
        public init?(decoding data: Data) {
            guard let fields = SpotWire.fields([UInt8](data)) else { return nil }
            var id = "", name = "", version = ""
            var inks: [Ink] = []
            for field in fields {
                switch (field.number, field.value) {
                case (1, .bytes(let bytes)): id = String(decoding: bytes, as: UTF8.self)
                case (2, .bytes(let bytes)): name = String(decoding: bytes, as: UTF8.self)
                case (3, .bytes(let bytes)): version = String(decoding: bytes, as: UTF8.self)
                case (4, .bytes(let bytes)):
                    guard let ink = Self.ink(bytes) else { return nil }
                    inks.append(ink)
                default: continue
                }
            }
            self.init(id: id, name: name, version: version, inks: inks)
        }

        private static func ink(_ bytes: [UInt8]) -> Ink? {
            guard let fields = SpotWire.fields(bytes) else { return nil }
            var name = ""
            var values = [Double](repeating: 0, count: 7)
            for field in fields {
                switch (field.number, field.value) {
                case (1, .bytes(let bytes)): name = String(decoding: bytes, as: UTF8.self)
                case (2...8, .float(let value)): values[Int(field.number) - 2] = value
                default: continue
                }
            }
            return Ink(name: name, lab: SIMD3(values[0], values[1], values[2]), cmyk: SIMD4(values[3], values[4], values[5], values[6]))
        }
    }

    /// How a spot chip is previewed: the document's *Color manage spot colors* choice and the
    /// working profiles (`ColorSettings`), the cache key of a preview.
    public struct SpotPreviewSettings: Hashable, Sendable {
        /// `ColorSettings.no_spot_color_management` false: preview from measured Lab.
        public var managed: Bool
        public var rgbProfile: ProfileRef
        public var cmykProfile: ProfileRef
        public var intent: RenderingIntent

        public init(managed: Bool = true, rgbProfile: ProfileRef? = nil, cmykProfile: ProfileRef? = nil,
                    intent: RenderingIntent = .relativeColorimetric, registry: ProfileRegistry = .shared) {
            self.managed = managed
            self.rgbProfile = rgbProfile ?? registry.sRGB
            self.cmykProfile = cmykProfile ?? registry.defaultCMYK
            self.intent = intent
        }
    }

    /// A spot chip's preview.
    public struct SpotPreview: Hashable, Sendable {
        /// The chip's components in `space`: Working RGB (managed) or Working CMYK (unmanaged,
        /// or the library is not here), 0...1.
        public var components: [Double]
        /// The profile `components` are in.
        public var profile: ProfileRef
        /// False when the swatch names a library or ink this app does not have: the Swatches
        /// panel marks it "library not available" and the preview is the nominal mix.
        public var libraryAvailable: Bool
        /// The display-list colour the canvas draws: CIELAB (managed) or CMYK (unmanaged), with
        /// the tint applied, so both renderers convert it like any other colour.
        public var color: Color

        /// The preview as a `CGColor` tagged with its profile.
        public func cgColor(registry: ProfileRegistry = .shared) -> CGColor? {
            guard let space = registry.colorSpace(for: profile) else { return nil }
            return CGColor(colorSpace: space, components: components.map { CGFloat($0) } + [1])
        }
    }

    /// The spot libraries this app has (color-tables.adoc, "Client"): the built-in development
    /// library plus every `<id>.binpb` in `directory` (the app bundle's `SpotLibraries`), each read
    /// the first time it is asked for; previews cached per `(library, ink, tint, settings)`.
    public final class SpotLibraryStore: @unchecked Sendable {
        public let directory: URL?
        public let converter: Converter
        private let lock = NSLock()
        private var libraries: [String: SpotLibrary?] = [SpotLibrary.placeholder.id: .placeholder]
        private var previews: [PreviewKey: SpotPreview] = [:]

        private struct PreviewKey: Hashable {
            var library: String
            var ink: String
            var nominal: SIMD4<Double>
            var tint: Double
            var settings: SpotPreviewSettings
        }

        public init(directory: URL? = nil, converter: Converter = .shared) {
            self.directory = directory
            self.converter = converter
        }

        /// The library ids available: the built-in one and every resource in `directory`, sorted.
        public var libraryIDs: [String] {
            var ids = Set([SpotLibrary.placeholder.id])
            if let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
                for name in names where name.hasSuffix(".binpb") {
                    ids.insert(String(name.dropLast(6)))
                }
            }
            return ids.sorted()
        }

        /// The library `id`, loaded on first use; nil when this app does not have it (or its
        /// resource does not decode).
        public func library(_ id: String) -> SpotLibrary? {
            if let known = lock.withLock({ libraries[id] }) { return known }
            let loaded = directory.flatMap { try? Data(contentsOf: $0.appending(path: "\(id).binpb")) }.flatMap(SpotLibrary.init(decoding:))
            lock.withLock { libraries[id] = .some(loaded) }
            return loaded
        }

        /// How many previews are cached (for tests of the cache).
        public var cachedPreviewCount: Int { lock.withLock { previews.count } }

        /// The chip of ink `ink` of library `library` at `tint` (0...1): managed, its Lab (tinted
        /// toward paper white in Lab) converted into Working RGB; unmanaged, its nominal CMYK
        /// (scaled by the tint) in Working CMYK.  A library or ink this app does not have
        /// previews from `nominal` (the swatch's stored CMYK) with `libraryAvailable` false.
        public func previewColor(library: String, ink: String, nominal: SIMD4<Double>, tint: Double = 1,
                                 settings: SpotPreviewSettings) -> SpotPreview {
            let tint = min(max(tint.isFinite ? tint : 1, 0), 1)
            let key = PreviewKey(library: library, ink: ink, nominal: nominal, tint: tint, settings: settings)
            if let cached = lock.withLock({ previews[key] }) { return cached }
            let found = self.library(library)?.ink(named: ink)
            let preview: SpotPreview
            if let found, settings.managed {
                let lab = SIMD3(100 - tint * (100 - found.lab.x), tint * found.lab.y, tint * found.lab.z)
                let color = Color(labL: lab.x, a: lab.y, b: lab.z)
                // A custom Working RGB whose bytes are pending previews through sRGB meanwhile.
                let profile = converter.registry.colorSpace(for: settings.rgbProfile) != nil ? settings.rgbProfile : converter.registry.sRGB
                let rgb = converter.convert(color, to: profile, intent: settings.intent, blackPointCompensation: true)!
                preview = SpotPreview(components: rgb, profile: profile, libraryAvailable: true, color: color)
            } else {
                let cmyk = (found?.cmyk ?? nominal) * tint
                let profile = converter.registry.colorSpace(for: settings.cmykProfile) != nil ? settings.cmykProfile : converter.registry.defaultCMYK
                preview = SpotPreview(components: [cmyk.x, cmyk.y, cmyk.z, cmyk.w], profile: profile, libraryAvailable: found != nil,
                                      color: Color(cyan: cmyk.x, magenta: cmyk.y, yellow: cmyk.z, black: cmyk.w))
            }
            lock.withLock { previews[key] = preview }
            return preview
        }

        /// Forgets every cached preview (a working profile's bytes arrived).
        public func removeCachedPreviews() {
            lock.withLock { previews = [:] }
        }
    }
}

/// The protobuf wire subset the spot library resource uses: length-delimited strings and
/// messages, and 32-bit floats.
enum SpotWire {
    enum Value: Equatable {
        case bytes([UInt8])
        case float(Double)
        case varint(UInt64)
    }

    struct Field: Equatable {
        var number: UInt64
        var value: Value
    }

    static func varint(_ value: UInt64, into out: inout Data) {
        var value = value
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
    }

    static func bytes(_ field: UInt64, _ bytes: Data, into out: inout Data) {
        varint(field << 3 | 2, into: &out)
        varint(UInt64(bytes.count), into: &out)
        out.append(bytes)
    }

    static func string(_ field: UInt64, _ value: String, into out: inout Data) {
        guard !value.isEmpty else { return }
        bytes(field, Data(value.utf8), into: &out)
    }

    static func float(_ field: UInt64, _ value: Double, into out: inout Data) {
        guard value != 0 else { return }
        varint(field << 3 | 5, into: &out)
        withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { out.append(contentsOf: $0) }
    }

    /// The fields of `bytes`; nil when they are not well-formed (64-bit and group wire types are
    /// not used by the format and read as malformed).
    static func fields(_ bytes: [UInt8]) -> [Field]? {
        var index = 0
        func readVarint() -> UInt64? {
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
        var result: [Field] = []
        while index < bytes.count {
            guard let key = readVarint() else { return nil }
            let number = key >> 3
            switch key & 7 {
            case 0:
                guard let value = readVarint() else { return nil }
                result.append(Field(number: number, value: .varint(value)))
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return nil }
                result.append(Field(number: number, value: .bytes(Array(bytes[index..<index + Int(length)]))))
                index += Int(length)
            case 5:
                guard bytes.count - index >= 4 else { return nil }
                let bits = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
                index += 4
                // A float carries about seven digits: read back to six decimals, so a value written
                // from a short decimal ("0.95") reads as that decimal.
                result.append(Field(number: number, value: .float((Double(Float(bitPattern: bits)) * 1e6).rounded() / 1e6)))
            default:
                return nil
            }
        }
        return result
    }
}
