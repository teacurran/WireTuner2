import CoreGraphics
import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender
import WTText

// IO-033: the accessibility check (names-notes.adoc, "Checking a document for accessibility").  It
// reads the document and a display list of it and writes nothing: objects a reader cannot read
// that have no description, text whose colour falls below the WCAG contrast ratio against what is
// drawn beneath it, each page's reading order, and a missing document language.  WTApp's sheet
// lists the report; its inline fixes are the ordinary `SetAlt` and `SetDecorative`.

/// What the accessibility check found.
public struct AccessibilityReport: Equatable, Sendable {
    /// An object a reader cannot read that has neither alt text nor *Decorative*.
    public struct Missing: Equatable, Sendable, Identifiable {
        public enum Reason: String, Equatable, Sendable {
            case image = "Image"
            case placedFile = "Placed file"
            case tracing = "Traced artwork"
            case outlinedText = "Text converted to paths"
        }

        public var node: OpID
        public var reason: Reason
        public var name: String
        /// The page number it is on; nil on the pasteboard.
        public var page: Int?
        public var id: OpID { node }
    }

    /// A line of text below the contrast it needs.
    public struct LowContrast: Equatable, Sendable, Identifiable {
        public var node: OpID
        /// The line of the block (0 first).
        public var line: Int
        /// The worse measured ratio against the backdrop.
        public var ratio: Double
        /// 4.5, or 3 for large text.
        public var required: Double
        public var isLarge: Bool
        public var page: Int?
        public var id: String { "\(node)-\(line)" }
    }

    /// One page's reading order.
    public struct PageOrder: Equatable, Sendable, Identifiable {
        public var page: OpID
        public var number: Int
        public var name: String
        public var order: [OpID]
        public var id: OpID { page }
    }

    public var missing: [Missing] = []
    public var lowContrast: [LowContrast] = []
    public var readingOrder: [PageOrder] = []
    /// Document Info has no language (tagged PDF needs one).
    public var missingLanguage = false

    public init(missing: [Missing] = [], lowContrast: [LowContrast] = [], readingOrder: [PageOrder] = [], missingLanguage: Bool = false) {
        self.missing = missing
        self.lowContrast = lowContrast
        self.readingOrder = readingOrder
        self.missingLanguage = missingLanguage
    }

    public var isClean: Bool { missing.isEmpty && lowContrast.isEmpty && !missingLanguage }
}

/// The check.
public enum AccessibilityCheck {
    /// The line menu:Text[Convert to Paths] writes into its group's note, which marks the group
    /// as text a reader can no longer read.
    public static let outlinedTextNote = "Converted from text"
    /// The name a traced group starts with (the Trace tool's "Trace" and "Trace of <name>").
    public static let tracePrefix = "Trace"

    /// The whole report for `state`, the contrast measured against `displayList` (the document's
    /// scene); `layout` gives a text node's layout (the window's cache in the app).
    public static func run(_ state: EngineState, displayList: DisplayList, layout: (OpID) -> TextLayout?) -> AccessibilityReport {
        let pages = PageList(state)
        let readingOrder = pages.pages.map { page in
            AccessibilityReport.PageOrder(page: page.id, number: page.number, name: page.name.isEmpty ? "Page \(page.number)" : page.name,
                                          order: ReadingOrder.order(of: page, in: state, pages: pages))
        }
        return AccessibilityReport(missing: missingDescriptions(in: state, pages: pages),
                                   lowContrast: lowContrast(in: state, displayList: displayList, pages: pages, layout: layout),
                                   readingOrder: readingOrder, missingLanguage: DocumentInfoValues(state)[.language].isEmpty)
    }

    /// `run` with the layouts made by a fresh engine.
    @MainActor
    public static func run(_ state: EngineState, displayList: DisplayList) -> AccessibilityReport {
        let engine = TextLayoutEngine(fonts: .shared)
        let colors = ColorResolver(state)
        return run(state, displayList: displayList) { node in
            state.textNode(node).map { TextLayoutReading.layout($0, engine: engine, colors: colors, state: state) }
        }
    }

    // MARK: Missing descriptions

    /// Why `node` needs a description, nil when it needs none: an image, a placed file, a traced
    /// group or text converted to paths.
    public static func reason(_ node: OpID, in state: EngineState) -> AccessibilityReport.Missing.Reason? {
        switch state.nodeKind(node) {
        case .image: return .image
        case .placedFile: return .placedFile
        case .group:
            let common = NavigationFields.common(of: node, in: state)
            if common?.note.split(separator: "\n").contains(where: { $0 == outlinedTextNote }) == true { return .outlinedText }
            if common?.name.hasPrefix(tracePrefix) == true { return .tracing }
            return nil
        default: return nil
        }
    }

    /// Whether `node` carries alt text or *Decorative*.
    static func isDescribed(_ node: OpID, in state: EngineState) -> Bool {
        guard let common = NavigationFields.common(of: node, in: state) else { return false }
        return common.decorative || !common.alt.isEmpty
    }

    /// Every object that needs a description and has none, in stacking order.  A described or
    /// decorative group covers its members; a traced or outlined group is listed as one.
    public static func missingDescriptions(in state: EngineState, pages: PageList) -> [AccessibilityReport.Missing] {
        var result: [AccessibilityReport.Missing] = []
        func visit(_ node: OpID) {
            if isDescribed(node, in: state) { return }
            if let reason = reason(node, in: state) {
                let page = Objects.bounds(of: node, in: state).flatMap(pages.page(ofBounds:))?.number
                result.append(AccessibilityReport.Missing(node: node, reason: reason, name: state.displayName(of: node), page: page))
                return
            }
            if state.nodeKind(node) == .group { state.liveChildren(node).forEach(visit) }
        }
        PageObjects.topLevel(in: state).forEach(visit)
        return result
    }

    // MARK: Contrast (WCAG 2.1)

    /// The relative luminance of an sRGB channel triple, each 0...1.
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public static func luminance(_ color: Color) -> Double {
        let rgb = color.srgb
        return luminance(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    /// The contrast ratio of two luminances, 1...21.
    public static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Large text: 18 pt and up, or 14 pt and up at weight 700 or more.
    public static func isLarge(size: Double, weight: Int) -> Bool {
        size >= 18 || (size >= 14 && weight >= 700)
    }

    public static func required(large: Bool) -> Double { large ? 3 : 4.5 }

    /// The weight a face name implies: 700 for bold, heavy and black faces, 400 otherwise.
    public static func weight(ofStyle style: String?) -> Int {
        let lower = (style ?? "").lowercased()
        return ["bold", "heavy", "black"].contains { lower.contains($0) } ? 700 : 400
    }

    /// The worse ratio of `text` against the 10th and 90th percentile luminance of `backdrop`;
    /// nil for no backdrop.
    public static func worstRatio(text: Double, backdrop: [Double]) -> Double? {
        guard !backdrop.isEmpty else { return nil }
        let sorted = backdrop.sorted()
        func percentile(_ p: Double) -> Double { sorted[Int((Double(sorted.count - 1) * p).rounded())] }
        return min(ratio(text, percentile(0.1)), ratio(text, percentile(0.9)))
    }

    /// Every line of text below the ratio it needs.
    public static func lowContrast(in state: EngineState, displayList: DisplayList, pages: PageList,
                                   layout: (OpID) -> TextLayout?) -> [AccessibilityReport.LowContrast] {
        var result: [AccessibilityReport.LowContrast] = []
        let colors = ColorResolver(state)
        for (top, node) in textNodes(in: state) {
            guard let text = state.textNode(node), let layout = layout(node),
                  let index = displayList.nodeIDs.firstIndex(of: NodeID(top)) else { continue }
            let backdrop = DisplayList(canvas: displayList.canvas, items: Array(displayList.items[..<index]),
                                       itemBounds: Array(displayList.itemBounds[..<index]), nodeIDs: Array(displayList.nodeIDs[..<index]))
            let transform = Objects.pasteboardTransform(of: node, in: state)
            for (line, range) in layout.lineRanges.enumerated() where !range.isEmpty {
                let corners = layout.selection(from: range.lowerBound, to: range.upperBound).flatMap(\.corners).map(transform.apply)
                guard let rect = Rect(enclosing: corners), rect.width > 0, rect.height > 0 else { continue }
                let attributes = TextLayoutReading.attributes(text.values(at: range.lowerBound), colors: colors)
                let large = isLarge(size: attributes.size, weight: weight(ofStyle: attributes.fontStyle))
                guard let measured = worstRatio(text: luminance(attributes.fill), backdrop: luminances(backdrop, in: rect)) else { continue }
                let needed = required(large: large)
                if measured < needed {
                    result.append(AccessibilityReport.LowContrast(node: node, line: line, ratio: measured, required: needed, isLarge: large,
                                                                  page: pages.page(ofBounds: rect)?.number))
                }
            }
        }
        return result
    }

    /// The live text nodes of the main canvas with the top-level object each is drawn in.
    static func textNodes(in state: EngineState) -> [(top: OpID, node: OpID)] {
        var result: [(OpID, OpID)] = []
        func visit(_ node: OpID, top: OpID) {
            switch state.nodeKind(node) {
            case .text: result.append((top, node))
            case .group: state.liveChildren(node).forEach { visit($0, top: top) }
            default: break
            }
        }
        for node in PageObjects.topLevel(in: state) { visit(node, top: node) }
        return result
    }

    /// The luminance of each pixel of `displayList` drawn over `rect` (pasteboard) at 2×, at most
    /// 512 pixels a side; the pasteboard (nothing drawn) reads as white.
    public static func luminances(_ displayList: DisplayList, in rect: Rect) -> [Double] {
        let zoom = min(2, 512 / max(rect.width, rect.height))
        let width = max(Int((rect.width * zoom).rounded(.up)), 1), height = max(Int((rect.height * zoom).rounded(.up)), 1)
        let viewport = Viewport(scrollOrigin: Point(x: rect.minX, y: rect.minY), zoom: zoom, size: Size(width: Double(width), height: Double(height)))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let image = CoreGraphicsRenderer().renderBitmap(displayList, viewport: viewport), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { i in
            luminance(red: Double(bytes[i]) / 255, green: Double(bytes[i + 1]) / 255, blue: Double(bytes[i + 2]) / 255)
        }
    }
}

extension Rect {
    /// The smallest rectangle holding `points`; nil for none.
    init?(enclosing points: [Point]) {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// An inline fix of the check's sheet: alt text typed in a row, or *Decorative* ticked there, as
/// the ordinary register writes, labelled `Describe "name"`.  One change.
public struct DescribeObject: Command {
    public enum Fix: Hashable, Sendable {
        case alt(String)
        case decorative(Bool)
    }

    public var node: OpID
    public var fix: Fix
    /// The object's display name for the label.
    public var name: String

    public init(_ node: OpID, _ fix: Fix, name: String) {
        self.node = node
        self.fix = fix
        self.name = name
    }

    public var label: String { "Describe \"\(name)\"" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        switch fix {
        case .alt(let alt): try SetAlt([node], alt: alt).execute(&builder, state: state)
        case .decorative(let on): try SetDecorative([node], decorative: on).execute(&builder, state: state)
        }
    }
}
