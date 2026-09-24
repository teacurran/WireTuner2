// The output warnings of web output (web/publish-html.adoc, "Output warnings"; WEB-010): one list
// of warnings, each with the node the Publish sheet's btn:[Show] selects, raised by the link
// resolution, the SVG writer and the HTML publisher.  Stable across runs for the same input.

import Foundation
import WTRender

/// One thing that could not be reproduced exactly.
public struct ExportWarning: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// An effect SVG has no equivalent for, rasterized.
        case rasterizedEffect
        /// A font whose license forbids embedding, converted to outlines.
        case outlinedFont
        /// A missing font, converted to outlines.
        case missingFont
        /// A link whose URL could not be made valid.
        case invalidLink
        /// A link on a stroke-only path (image maps respond only on the stroke).
        case strokeOnlyLink
        /// A placed SVG animation that depends on script.
        case scriptAnimation
        /// A page larger than 16,384 pixels on a side, clamped in PNG mode.
        case clampedPage
        /// A link overridden by the object's page link.
        case unusedLink
        /// A page link to a page the output leaves out.
        case missingPage
        /// A placed image or animation whose blob is not on this Mac, drawn as its placeholder.
        case pendingAsset
    }

    public var kind: Kind
    /// The node to select; nil for a page-level warning.
    public var node: NodeID?
    /// The page (1-based) for page-level warnings.
    public var page: Int?
    public var message: String

    public init(_ kind: Kind, node: NodeID? = nil, page: Int? = nil, _ message: String) {
        self.kind = kind
        self.node = node
        self.page = page
        self.message = message
    }
}

/// The warnings sink: collects warnings, drops duplicates and keeps them in a stable order (by
/// page, node, kind, then message).
public struct ExportWarnings: Hashable, Sendable {
    public private(set) var all: [ExportWarning] = []

    public init(_ warnings: [ExportWarning] = []) {
        for warning in warnings { append(warning) }
    }

    public mutating func append(_ warning: ExportWarning) {
        guard !all.contains(warning) else { return }
        all.append(warning)
    }

    public mutating func append(contentsOf warnings: [ExportWarning]) {
        for warning in warnings { append(warning) }
    }

    /// The warnings in their stable order.
    public var sorted: [ExportWarning] {
        all.sorted { a, b in
            let pa = a.page ?? 0, pb = b.page ?? 0
            if pa != pb { return pa < pb }
            let na = a.node ?? NodeID(counter: 0, replica: 0), nb = b.node ?? NodeID(counter: 0, replica: 0)
            if na != nb { return na < nb }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.message < b.message
        }
    }

    public var isEmpty: Bool { all.isEmpty }
}
