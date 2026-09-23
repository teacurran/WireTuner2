// Layout goldens (docs/spec/testing.adoc, "Geometry and rendering": `WTText` layout goldens for
// the type chapter's features): every glyph's placement as JSON, compared within a tolerance,
// and the layout drawn by WTRender's Core Graphics reference renderer as PNG, compared per
// pixel.  Run with `WTTEXT_RECORD_GOLDENS=1` to (re)write them under Goldens/, then commit.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
import WTRender
import struct WTGeometry.AffineTransform
@testable import WTText

enum Goldens {
    static let recordKey = "WTTEXT_RECORD_GOLDENS"
    static var isRecording: Bool { ProcessInfo.processInfo.environment[recordKey] == "1" }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // WTTextTests
        .appendingPathComponent("Goldens", isDirectory: true)

    /// Glyph origins within this many points of the golden's pass.
    static let positionTolerance = 0.05
    /// Per-channel difference that counts a pixel as different, and the share of pixels
    /// (anti-aliased glyph edges) allowed to differ.
    static let pixelTolerance = 24
    static let pixelShare = 0.002

    struct Glyph: Codable, Equatable {
        var glyph: Int
        var offset: Int
        var container: Int
        var transform: [Double]
    }

    /// Compares (or records) `layout`'s glyphs and its render.
    static func check(_ layout: TextLayout, name: String, size: Size, sourceLocation: SourceLocation = #_sourceLocation) {
        checkGlyphs(layout, name: name, sourceLocation: sourceLocation)
        checkRender(layout, name: name, size: size, sourceLocation: sourceLocation)
    }

    static func checkGlyphs(_ layout: TextLayout, name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let glyphs = layout.glyphs().map { glyph in
            Glyph(glyph: Int(glyph.glyph), offset: glyph.offset, container: glyph.container, transform: [
                glyph.transform.a, glyph.transform.b, glyph.transform.c, glyph.transform.d, glyph.transform.tx, glyph.transform.ty,
            ].map { ($0 * 1000).rounded() / 1000 })
        }
        let url = directory.appendingPathComponent("\(name).json")
        if isRecording {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect((try? encoder.encode(glyphs).write(to: url)) != nil, sourceLocation: sourceLocation)
            return
        }
        guard let data = try? Data(contentsOf: url), let golden = try? JSONDecoder().decode([Glyph].self, from: data) else {
            Issue.record("missing golden \(url.lastPathComponent); run with \(recordKey)=1 and commit it", sourceLocation: sourceLocation)
            return
        }
        #expect(golden.count == glyphs.count, "\(name): \(glyphs.count) glyphs, golden has \(golden.count)", sourceLocation: sourceLocation)
        for (expected, actual) in zip(golden, glyphs) {
            let close = expected.glyph == actual.glyph && expected.offset == actual.offset && expected.container == actual.container
                && zip(expected.transform, actual.transform).allSatisfy { abs($0 - $1) <= positionTolerance }
            if !close {
                Issue.record("\(name): glyph at offset \(actual.offset) \(actual) differs from golden \(expected)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    /// The layout's items drawn over white at 2×.
    static func render(_ layout: TextLayout, size: Size, extra: [DisplayItem] = []) -> CGImage? {
        var items = extra
        for container in layout.containers.indices {
            items.append(contentsOf: layout.displayItems(forContainer: container))
        }
        let list = DisplayList(canvas: "text", items: items)
        return CoreGraphicsRenderer(background: .white).renderBitmap(list, viewport: Viewport(size: size), scale: 2)
    }

    static func checkRender(_ layout: TextLayout, name: String, size: Size, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let image = render(layout, size: size) else {
            Issue.record("\(name): no render", sourceLocation: sourceLocation)
            return
        }
        checkImage(image, name: name, sourceLocation: sourceLocation)
    }

    /// Compares (or records) a render.
    static func checkImage(_ image: CGImage, name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = directory.appendingPathComponent("\(name).png")
        if isRecording {
            #expect(write(image, to: url), sourceLocation: sourceLocation)
            return
        }
        guard let golden = read(url), let candidate = BitmapSurface(drawing: image) else {
            Issue.record("missing golden \(url.lastPathComponent); run with \(recordKey)=1 and commit it", sourceLocation: sourceLocation)
            return
        }
        #expect(golden.width == candidate.width && golden.height == candidate.height, sourceLocation: sourceLocation)
        var different = 0
        for y in 0..<min(golden.height, candidate.height) {
            for x in 0..<min(golden.width, candidate.width) where golden.pixel(x: x, y: y).maxChannelDifference(to: candidate.pixel(x: x, y: y)) > pixelTolerance {
                different += 1
            }
        }
        let share = Double(different) / Double(max(golden.width * golden.height, 1))
        #expect(share <= pixelShare, "\(name): \(different) pixels differ", sourceLocation: sourceLocation)
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    static func read(_ url: URL) -> BitmapSurface? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return BitmapSurface(drawing: image)
    }
}

func approx(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 0.01) -> Bool {
    abs(lhs - rhs) <= tolerance
}

/// Common fixtures.
enum Fixture {
    static let body = TextAttributes(fontFamily: "Helvetica", size: 12)
    static let lorem = "Typography is the craft of arranging type to make written language legible, readable and appealing when displayed. The arrangement of type involves selecting typefaces, point sizes, line lengths, line spacing and letter spacing."

    static func block(width: Double = 200, height: Double = 200, _ configure: (inout TextBlock) -> Void = { _ in }) -> TextContainer {
        var block = TextBlock(width: width, height: height)
        configure(&block)
        return .block(block)
    }

    static func layout(_ text: String, style: ParagraphStyle = ParagraphStyle(), attributes: TextAttributes = body, in containers: [TextContainer]) -> TextLayout {
        TextLayoutEngine().layout(TextContent(text, attributes: attributes, style: style), in: containers)
    }

    /// The top-level paths drawn with strokes only: rules and borders.
    static func strokePaths(_ items: [DisplayItem]) -> [PathItem] {
        items.compactMap { item -> PathItem? in
            if case .path(let path) = item, !path.appearance.strokes.isEmpty, path.appearance.fills.isEmpty { return path }
            return nil
        }
    }

    /// Where each placed line's first visible glyph starts and its last one ends (x).
    static func lineExtents(_ layout: TextLayout, text: String) -> [(start: Double, end: Double)] {
        let scalars = Array(text.unicodeScalars)
        let glyphs = layout.glyphs().filter { $0.offset < scalars.count && !scalars[$0.offset].properties.isWhitespace }
        return layout.lineRanges.map { range in
            let inLine = glyphs.filter { range.contains($0.offset) }
            return (inLine.map { $0.origin.x }.min() ?? 0, inLine.map { $0.origin.x + $0.advance }.max() ?? 0)
        }
    }
}
