// The attributed-string attributes the RTF readers (TextImport, ClipboardReader) take from the
// platform's text system (decisions.adoc D-073): on the Mac AppKit's `NSFont`, `NSColor` and
// `NSImage`, on iPhone and iPad UIKit's `UIFont`, `UIColor` and `UIImage`.  Everything the readers
// hand on is platform-neutral (strings, doubles, `CGImage`, `CGSize`), so nothing above this file
// names a platform type.  The Mac branch is the code the readers held before the iOS build.

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreGraphics
import Foundation

enum PlatformText {
    /// A run's font as the readers need it.
    struct Font {
        var name: String
        var family: String
        var size: Double
        var bold: Bool
        var italic: Bool
        var face: String?
    }

    /// The run's `.font`, nil when it has none.
    static func font(_ attributes: [NSAttributedString.Key: Any]) -> Font? {
        #if canImport(AppKit)
        guard let font = attributes[.font] as? NSFont else { return nil }
        let traits = font.fontDescriptor.symbolicTraits
        return Font(name: font.fontName, family: font.familyName ?? font.fontName, size: Double(font.pointSize),
                    bold: traits.contains(.bold), italic: traits.contains(.italic),
                    face: font.fontDescriptor.object(forKey: .face) as? String)
        #elseif canImport(UIKit)
        guard let font = attributes[.font] as? UIFont else { return nil }
        let traits = font.fontDescriptor.symbolicTraits
        return Font(name: font.fontName, family: font.familyName, size: Double(font.pointSize),
                    bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic),
                    face: font.fontDescriptor.object(forKey: .face) as? String)
        #else
        return nil
        #endif
    }

    /// The run's `.foregroundColor` in sRGB (red, green, blue, alpha), nil when it has none or
    /// it cannot be converted.
    static func sRGBForeground(_ attributes: [NSAttributedString.Key: Any]) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        #if canImport(AppKit)
        guard let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent))
        #elseif canImport(UIKit)
        guard let color = attributes[.foregroundColor] as? UIColor,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 4 else { return nil }
        return (Double(c[0]), Double(c[1]), Double(c[2]), Double(c[3]))
        #else
        return nil
        #endif
    }

    /// The superscript attribute (AppKit's `.superscript`; UIKit has no constant for the same
    /// key, so it is named by its raw value there).
    static var superscriptKey: NSAttributedString.Key {
        #if canImport(AppKit)
        .superscript
        #else
        NSAttributedString.Key("NSSuperScript")
        #endif
    }

    /// An attachment's picture as a `CGImage` and its size in points, from its image or, failing
    /// that, from `data`; nil when neither gives an image.
    static func image(_ attachment: NSTextAttachment, data: Data?) -> (image: CGImage?, size: CGSize)? {
        #if canImport(AppKit)
        let image = attachment.image ?? data.flatMap { NSImage(data: $0) }
        guard let image else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return (image.cgImage(forProposedRect: &rect, context: nil, hints: nil), image.size)
        #elseif canImport(UIKit)
        let image = attachment.image ?? data.flatMap { UIImage(data: $0) }
        guard let image else { return nil }
        return (image.cgImage, image.size)
        #else
        return nil
        #endif
    }

    /// An RTFD package read as an attributed string.
    static func rtfd(_ wrapper: FileWrapper, url: URL) -> NSAttributedString? {
        #if canImport(AppKit)
        NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil)
        #else
        // UIKit has no file-wrapper initialiser; its URL reader takes the package directory.
        try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        #endif
    }
}
