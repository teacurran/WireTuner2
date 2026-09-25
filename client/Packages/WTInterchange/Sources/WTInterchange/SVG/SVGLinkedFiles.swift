// Shared, content-named files for the HTML publisher's SVG pages (web/publish-html.adoc, "What the
// folder contains"; WEB-008): placed bitmaps go to `images/` in the setting's format and quality,
// embedded fonts to `fonts/` as WOFF2 subsets, each named by the SHA-256 of its bytes so the same
// image or subset on several pages is one file and republishing an unchanged document rewrites
// nothing.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTRender

/// Where an SVG page's linked images and fonts go, relative to the SVG file.
public struct SVGLinkedFiles: Hashable, Sendable {
    /// The images folder relative to the SVG (`../images` for `pages/page-1.svg`).
    public var imageFolder: String
    /// The fonts folder relative to the SVG.
    public var fontFolder: String
    /// *Images*: JPEG, PNG or WebP; a bitmap with transparency is PNG unless WebP is chosen.
    public var imageFormat: HTMLImageFormat
    /// JPEG and WebP quality, 1 ... 100.
    public var imageQuality: Int

    public init(imageFolder: String = "../images", fontFolder: String = "../fonts", imageFormat: HTMLImageFormat = .jpeg, imageQuality: Int = 80) {
        self.imageFolder = imageFolder
        self.fontFolder = fontFolder
        self.imageFormat = imageFormat
        self.imageQuality = imageQuality
    }

    /// The first 16 bytes of the SHA-256 of `data` in lowercase hex: the file's name.
    static func name(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `image` in the chosen format: the placed JPEG's own bytes when JPEG is chosen and it has
    /// them; PNG for a bitmap with transparency under JPEG, and for WebP where this Mac cannot
    /// encode it.  Returns the bytes and the file extension.
    func encode(_ image: CGImage, original: Data?, webPAvailable: Bool = BitmapExporter.canEncode(.webp)) -> (data: Data, ext: String) {
        let quality = [kCGImageDestinationLossyCompressionQuality: Double(imageQuality) / 100]
        switch imageFormat {
        case .jpeg:
            if let original { return (original, "jpg") }
            if RGBAPixels(image).isOpaque, let jpeg = ImageEncoding.encode(image, type: .jpeg, properties: quality) {
                return (jpeg, "jpg")
            }
        case .webp:
            if webPAvailable, let webp = ImageEncoding.encode(image, type: .webP, properties: quality) {
                return (webp, "webp")
            }
        case .png:
            break
        }
        // Every CGImage the flattener produces encodes as PNG.
        return (ImageEncoding.encode(image, type: .png)!, "png")
    }
}

/// Text written as outlines because its font could not be embedded.
public struct SVGOutlinedFont: Hashable, Sendable {
    public var postScriptName: String
    public var node: NodeID?
    /// The font's `fsType` forbids embedding (otherwise it has no TrueType outlines to subset,
    /// or is a variable-font instance).
    public var restricted: Bool

    public init(postScriptName: String, node: NodeID?, restricted: Bool) {
        self.postScriptName = postScriptName
        self.node = node
        self.restricted = restricted
    }
}

extension SVGBuild {
    /// The reference to `image` as a content-named file in `files.imageFolder`, added to the
    /// resources once.
    func linkedImage(_ image: CGImage, original: Data?, in files: SVGLinkedFiles) -> String {
        let (data, ext) = files.encode(image, original: original)
        return linkedResource(data, folder: files.imageFolder, ext: ext)
    }

    /// The reference to a TrueType subset as a content-named WOFF2 file in `files.fontFolder`;
    /// nil when it cannot be compressed (the caller falls back to a data URL).
    func linkedFont(_ subset: Data, in files: SVGLinkedFiles) -> String? {
        guard let woff2 = try? WOFF2Writer.woff2(subset) else { return nil }
        return linkedResource(woff2, folder: files.fontFolder, ext: "woff2")
    }

    func linkedResource(_ data: Data, folder: String, ext: String) -> String {
        let path = "\(folder)/\(SVGLinkedFiles.name(data)).\(ext)"
        if !resources.contains(where: { $0.path == path }) {
            resources.append((path, data))
        }
        return path
    }
}
