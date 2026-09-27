// Embedded profiles at image import (CMS-012; docs/_includes/cms/image-color.adoc, "Client"): the
// ICC profile a TIFF, PNG, JPEG or PSD file carries, read from the file's own structure -- JPEG
// `APP2 ICC_PROFILE` segments in sequence order, PNG `iCCP` (inflated; an `sRGB` chunk stands for the
// bundled sRGB profile), TIFF tag 34675 of the first IFD, the PSD image resource 0x040F -- rather than
// from ImageIO's decoded colour space, which reports sRGB for a file that carries no profile at all.
// The profile is registered with the profile registry, which recognizes a bundled profile by hash
// (so a hundred sRGB images add no profile asset), and any other profile's bytes become a blob the
// document stores beside the image.

import Foundation
import WTRender

/// A profile found inside an imported image.
public struct ImportedProfile: Hashable, Sendable {
    /// The profile (`ImageColorSettings.embedded_profile`).
    public var profile: WTColor.ProfileRef
    /// The ICC bytes as a blob the document stores (`ProfileAssetProps`); nil for a bundled
    /// profile, which every Mac has.
    public var blob: ImportedBlob?

    public init(profile: WTColor.ProfileRef, blob: ImportedBlob?) {
        self.profile = profile
        self.blob = blob
    }
}

/// What an import does with an embedded profile (the *Embedded image profiles* preference, its
/// *Ask* answered before the import writes anything).
public enum EmbeddedProfilePolicy: Hashable, Sendable {
    /// Record the profile and read the image through it.
    case useEmbedded
    /// Record the profile but read the image through the document default.
    case ignore
}

public enum EmbeddedProfiles {
    /// The profile embedded in image file `data`, registered with `registry`; nil when the file
    /// carries none (or one ColorSync cannot read).
    public static func extract(_ data: Data, registry: WTColor.ProfileRegistry = .shared) -> ImportedProfile? {
        guard let icc = iccData(in: data), let profile = registry.register(iccData: icc) else { return nil }
        return ImportedProfile(profile: profile, blob: profile.isBundled ? nil : ImportedBlob(data: icc, uti: "com.apple.colorsync-profile"))
    }

    /// The ICC bytes embedded in `data` (JPEG, PNG, TIFF or PSD), nil when there are none.
    public static func iccData(in data: Data, registry: WTColor.ProfileRegistry = .shared) -> Data? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xD8]) { return jpeg(bytes) }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return png(bytes, registry: registry) }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return tiff(bytes) }
        if bytes.starts(with: Array("8BPS".utf8)) { return psd(bytes) }
        return nil
    }

    /// The big- or little-endian integer of `width` bytes at `at`; 0 past the end (every caller
    /// then finds nothing where it looks).
    static func integer(_ bytes: [UInt8], _ at: Int, width: Int, bigEndian: Bool = true) -> Int {
        guard at >= 0, at + width <= bytes.count else { return 0 }
        let slice = bytes[at..<(at + width)].map(Int.init)
        return (bigEndian ? slice : slice.reversed()).reduce(0) { $0 << 8 | $1 }
    }

    /// JPEG: every `APP2` segment starting `ICC_PROFILE\0`, joined in sequence order.
    static func jpeg(_ bytes: [UInt8]) -> Data? {
        let signature = Array("ICC_PROFILE".utf8) + [0]
        var chunks: [(Int, ArraySlice<UInt8>)] = []
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            // Start of scan or end of image: no metadata follows.
            if marker == 0xDA || marker == 0xD9 { break }
            // Markers without a length (fill bytes, restart markers, TEM).
            if marker == 0xFF || (0xD0...0xD7).contains(marker) || marker == 0x01 { index += marker == 0xFF ? 1 : 2; continue }
            let length = integer(bytes, index + 2, width: 2)
            guard length >= 2, index + 2 + length <= bytes.count else { break }
            let body = bytes[(index + 4)..<(index + 2 + length)]
            if marker == 0xE2, body.count > signature.count + 2, body.starts(with: signature) {
                let start = body.startIndex + signature.count
                chunks.append((Int(body[start]), body[(start + 2)...]))
            }
            index += 2 + length
        }
        guard !chunks.isEmpty else { return nil }
        return Data(chunks.sorted { $0.0 < $1.0 }.flatMap(\.1))
    }

    /// PNG: the `iCCP` chunk's profile inflated, or the bundled sRGB profile for an `sRGB` chunk.
    static func png(_ bytes: [UInt8], registry: WTColor.ProfileRegistry) -> Data? {
        var index = 8
        while index + 12 <= bytes.count {
            let length = integer(bytes, index, width: 4)
            let type = String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self)
            guard type != "IDAT", type != "IEND", index + 12 + length <= bytes.count else { return nil }
            let body = Array(bytes[(index + 8)..<(index + 8 + length)])
            if type == "iCCP" {
                // Name, NUL, compression method 0, zlib stream.
                guard let nul = body.firstIndex(of: 0), nul + 4 < body.count, body[nul + 1] == 0,
                      let inflated = try? (Data(body[(nul + 4)...]) as NSData).decompressed(using: .zlib) as Data, !inflated.isEmpty else { return nil }
                return inflated
            }
            if type == "sRGB" {
                return registry.iccData(for: registry.sRGB)
            }
            index += 12 + length
        }
        return nil
    }

    /// TIFF: tag 34675 (ICC profile) of the first IFD.
    static func tiff(_ bytes: [UInt8]) -> Data? {
        let big = bytes[0] == 0x4D
        let ifd = integer(bytes, 4, width: 4, bigEndian: big)
        let count = integer(bytes, ifd, width: 2, bigEndian: big)
        for entry in 0..<count where integer(bytes, ifd + 2 + entry * 12, width: 2, bigEndian: big) == 34675 {
            let at = ifd + 2 + entry * 12
            let length = integer(bytes, at + 4, width: 4, bigEndian: big)
            let offset = length <= 4 ? at + 8 : integer(bytes, at + 8, width: 4, bigEndian: big)
            guard length > 0, offset + length <= bytes.count else { return nil }
            return Data(bytes[offset..<(offset + length)])
        }
        return nil
    }

    /// PSD: image resource 0x040F in the image resources section.
    static func psd(_ bytes: [UInt8]) -> Data? {
        // Header (26 bytes), colour mode data (length + data), image resources (length + data).
        let resources = 30 + integer(bytes, 26, width: 4)
        var index = resources + 4
        let end = min(index + integer(bytes, resources, width: 4), bytes.count)
        while index + 12 <= end, bytes[index..<(index + 4)].elementsEqual("8BIM".utf8) {
            let id = integer(bytes, index + 4, width: 2)
            let name = (1 + Int(bytes[index + 6]) + 1) & ~1
            let size = integer(bytes, index + 6 + name, width: 4)
            let data = index + 10 + name
            guard data + size <= end else { return nil }
            if id == 0x040F { return Data(bytes[data..<(data + size)]) }
            index = data + ((size + 1) & ~1)
        }
        return nil
    }
}
