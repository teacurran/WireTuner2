// The options of one HTML setting (web/publish-html.adoc, "HTML settings"; `HtmlSetting` in
// doc/v1/web.proto): what the HTML publisher reads.  WTModel reads the document's settings into
// these values (WEB-007); the publisher needs no WTModel.

import Foundation

/// *Layout*: one picture per page, or one per top-level object placed with CSS.
public enum HTMLLayout: String, CaseIterable, Hashable, Sendable, Codable {
    case wholePages
    case positionedObjects
}

/// *Pages*: every page in `index.html`, or one file per page.
public enum HTMLPageMode: String, CaseIterable, Hashable, Sendable, Codable {
    case stacked
    case separateFiles
}

/// *Vector art*: SVG pages, or PNG pages at *Scale* with image maps for links.
public enum HTMLVectorFormat: String, CaseIterable, Hashable, Sendable, Codable {
    case svg
    case png
}

/// *Images*: the format placed bitmaps are written in.
public enum HTMLImageFormat: String, CaseIterable, Hashable, Sendable, Codable {
    case jpeg
    case png
    case webp
}

/// *Fonts*: embedded subsets, outlines, or system font names.
public enum HTMLFontMode: String, CaseIterable, Hashable, Sendable, Codable {
    case embed
    case outlines
    case system
}

/// *Page background*.
public enum HTMLBackground: String, CaseIterable, Hashable, Sendable, Codable {
    case document
    case white
    case transparent
}

/// Every option of one HTML setting except its name and the Mac-local *Location*.
public struct HTMLPublishSettings: Hashable, Sendable, Codable {
    public var layout: HTMLLayout
    public var pageMode: HTMLPageMode
    public var vectorFormat: HTMLVectorFormat
    /// PNG output: CSS pixels per point, 1 ... 3.
    public var scale: Int
    public var imageFormat: HTMLImageFormat
    /// JPEG and WebP quality, 1 ... 100.
    public var imageQuality: Int
    public var fontMode: HTMLFontMode
    /// *Animation* › *Still*: publish the pages as they look on the canvas.
    public var animationStill: Bool
    /// *SVG animations* › *Poster only*.
    public var svgAnimationPosterOnly: Bool
    /// *Allow scripts* inside placed SVG animations.
    public var allowScripts: Bool
    public var background: HTMLBackground
    /// The `<title>`; empty for the document name.
    public var title: String

    public init(layout: HTMLLayout = .wholePages, pageMode: HTMLPageMode = .stacked, vectorFormat: HTMLVectorFormat = .svg, scale: Int = 2,
                imageFormat: HTMLImageFormat = .jpeg, imageQuality: Int = 80, fontMode: HTMLFontMode = .embed, animationStill: Bool = false,
                svgAnimationPosterOnly: Bool = false, allowScripts: Bool = false, background: HTMLBackground = .document, title: String = "") {
        self.layout = layout
        self.pageMode = pageMode
        self.vectorFormat = vectorFormat
        self.scale = scale
        self.imageFormat = imageFormat
        self.imageQuality = imageQuality
        self.fontMode = fontMode
        self.animationStill = animationStill
        self.svgAnimationPosterOnly = svgAnimationPosterOnly
        self.allowScripts = allowScripts
        self.background = background
        self.title = title
    }

    /// The built-in *Default* setting: SVG pages, JPEG images at 80, embedded fonts.
    public static let defaults = HTMLPublishSettings()

    /// Rejects values outside the Setup sheet's ranges.
    public func validate() throws {
        guard (1...3).contains(scale) else { throw ExportError.invalidOption("The PNG scale must be 1×, 2× or 3×.") }
        guard (1...100).contains(imageQuality) else { throw ExportError.invalidOption("Image quality must be 1 to 100.") }
        guard title.unicodeScalars.count <= 256 else { throw ExportError.invalidOption("The title can be at most 256 characters.") }
    }
}
