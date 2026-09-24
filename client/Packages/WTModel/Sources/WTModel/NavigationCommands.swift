import Foundation
import WTCRDT
import WTProto

// WEB-001: navigation properties and text-range links in the model (web/urls.adoc and
// web/interactivity.adoc, "Data model", "Merge semantics").  The object-level link is
// `CommonProps.url` (6), the Navigation panel's other fields `CommonProps.navigation` (8, STRUCT:
// alt 1, target 2, go_to_page 3), a text-range link the `link` mark (TextMarkValue 40).  Every
// kind carries `CommonProps` as its field 1, so the paths are built from the node's kind number
// and cover kinds `NodeKind` does not list (placed SVG animations, images).

/// Why a navigation command refused to build its change.  Thrown before anything is appended.
public enum NavigationError: Error, Hashable, Sendable {
    /// The node does not exist or is not an object that can carry a link.
    case notLinkable(OpID)
    /// The node is not a live page (a master page, a deleted page or another kind).
    case notAPage(OpID)
    /// A string longer than its field allows (url 2,048, alt 1,024 characters).
    case tooLong(String)
}

/// Register paths of the navigation fields of any kind's `CommonProps`.
public enum NavigationFields {
    /// `CommonProps` of kind `kind` (`NodeProps.<kind>.common`).
    public static func common(_ kind: UInt32) -> RegisterPath { RegisterPath([kind, 1]) }
    /// `CommonProps.url`: the object-level link (ATOMIC string).
    public static func url(_ kind: UInt32) -> RegisterPath { common(kind).child(6) }
    /// `CommonProps.navigation` (STRUCT).
    public static func navigation(_ kind: UInt32) -> RegisterPath { common(kind).child(8) }
    /// `NavigationProps.alt`.
    public static func alt(_ kind: UInt32) -> RegisterPath { navigation(kind).child(1) }
    /// `NavigationProps.target`.
    public static func target(_ kind: UInt32) -> RegisterPath { navigation(kind).child(2) }
    /// `NavigationProps.go_to_page`.
    public static func goToPage(_ kind: UInt32) -> RegisterPath { navigation(kind).child(3) }

    /// The longest `url` (and `link` mark), in characters.
    public static let maxURL = 2048
    /// The longest `navigation.alt`.
    public static let maxAlt = 1024

    /// Kinds that are not objects: the document, settings, pages, master pages, layers and the
    /// collections' entries (swatches, styles, symbols' masters, brushes, assets).
    static let nonObjects: Set<UInt32> = [0, SettingsFields.kind, PageFields.kind, MasterPageFields.kind, LayerFields.kind]

    /// A sparse `NodeProps` of kind `kind` whose `CommonProps` `build` fills (any kind: the value
    /// is assembled at the wire level, `NodeProps.<kind> = 1 { common }`).
    public static func values(kind: UInt32, _ build: (inout Wiretuner_Doc_V1_CommonProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var common = Wiretuner_Doc_V1_CommonProps()
        build(&common)
        let bytes = Wire.field(kind, Wire.field(1, Wire.bytes { try common.serializedBytes() }))
        return (try? Wiretuner_Doc_V1_NodeProps(serializedBytes: bytes)) ?? Wiretuner_Doc_V1_NodeProps()
    }

    /// The `CommonProps` of a node of any kind, from its merged props (nil when the node has
    /// no kind).
    public static func common(of node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_CommonProps? {
        let kind = state.store.kind(node)
        guard kind != 0 else { return nil }
        let bytes = Wire.bytes { try state.props(node).serializedBytes() }
        guard let body = WireFields.payload(of: kind, in: bytes) else { return Wiretuner_Doc_V1_CommonProps() }
        guard let common = WireFields.payload(of: 1, in: body) else { return Wiretuner_Doc_V1_CommonProps() }
        return (try? Wiretuner_Doc_V1_CommonProps(serializedBytes: common)) ?? Wiretuner_Doc_V1_CommonProps()
    }

    /// Whether `node` exists and is an object that can carry a link (a path, shape, group, text
    /// block, image, placed file or animation -- not a layer, page or collection entry).
    public static func isLinkable(_ node: OpID, in state: EngineState) -> Bool {
        let kind = state.store.kind(node)
        guard state.store.exists(node), !nonObjects.contains(kind) else { return false }
        return Reachability.root(of: node, in: state) != nil
    }
}

/// Reading length-delimited fields of an encoded message without a schema.
enum WireFields {
    /// The payloads of every LEN record of field `number` in `bytes`, concatenated (protobuf
    /// merges repeated occurrences of a message field); nil when there is none or the bytes do
    /// not parse.
    static func payload(of number: UInt32, in bytes: [UInt8]) -> [UInt8]? {
        var index = 0
        var out: [UInt8]?
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let tag = varint() else { return nil }
            switch tag & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                index += 8
            case 5:
                index += 4
            case 2:
                guard let length = varint(), index + Int(length) <= bytes.count else { return nil }
                if UInt32(tag >> 3) == number { out = (out ?? []) + bytes[index..<index + Int(length)] }
                index += Int(length)
            default:
                return nil
            }
            guard index <= bytes.count else { return nil }
        }
        return out
    }
}

/// Where a node hangs in the tree, as the tree walks read it: a node is reachable when it and
/// every ancestor is live and the chain ends at a well-known collection (layers, pages, masters,
/// symbols ...).  A node under a deleted group or layer is not reachable -- though it is still
/// "live" by `isLive` -- so it drops out of the link list with its container.
public enum Reachability {
    /// The well-known node the chain of `node` ends at, or nil when a node on it is deleted or
    /// the chain ends at an unknown parent.
    public static func root(of node: OpID, in state: EngineState) -> OpID? {
        var current = node
        var steps = 0
        while steps < 10_000 {
            if current.replica == 0 { return current }
            guard state.isLive(current), let parent = state.store.placement(current)?.parent else { return nil }
            current = parent
            steps += 1
        }
        return nil
    }

    /// Whether `node` is reachable (see above).
    public static func isReachable(_ node: OpID, in state: EngineState) -> Bool {
        root(of: node, in: state) != nil
    }
}

/// What happens when the object is clicked in exported and published output (interactivity.adoc,
/// "Data model"): derived, never stored -- `go_to_page` set wins, then a non-empty `url`.
public enum OnClick: Hashable, Sendable {
    case nothing
    case goToPage(OpID)
    case openLink(String)
}

/// Where an object-level link opens in HTML and SVG output.
public enum LinkOpens: Hashable, Sendable {
    case sameWindow
    case newTab

    init(_ stored: Wiretuner_Doc_V1_LinkTarget) {
        self = stored == .newTab ? .newTab : .sameWindow
    }

    var stored: Wiretuner_Doc_V1_LinkTarget { self == .newTab ? .newTab : .sameWindow }
}

/// The navigation properties of one object as read, with the read-time normalizations applied
/// (urls.adoc and interactivity.adoc, "Read-time normalization"): a `url` empty after trimming
/// reads as unset, an unspecified target as *Same window*, and a `go_to_page` naming a node that
/// is not a live page (deleted, a master page, another kind) as unset.
public struct NavigationInfo: Hashable, Sendable {
    public var url: String?
    public var alt: String?
    public var target: LinkOpens
    public var goToPage: OpID?
    /// The page reference as stored, when it dangles (the panel shows *(deleted page)*).
    public var danglingPage: OpID?

    public init(url: String? = nil, alt: String? = nil, target: LinkOpens = .sameWindow, goToPage: OpID? = nil, danglingPage: OpID? = nil) {
        self.url = url
        self.alt = alt
        self.target = target
        self.goToPage = goToPage
        self.danglingPage = danglingPage
    }

    /// `node`'s navigation properties (all unset for a node without `CommonProps`).
    public init(_ node: OpID, in state: EngineState) {
        guard let common = NavigationFields.common(of: node, in: state) else {
            self.init(url: nil)
            return
        }
        self.init(common, in: state)
    }

    /// The navigation properties `common` holds.
    public init(_ common: Wiretuner_Doc_V1_CommonProps, in state: EngineState) {
        self.init(url: nil)
        url = Self.normalized(common.url)
        alt = common.navigation.alt.isEmpty ? nil : common.navigation.alt
        target = LinkOpens(common.navigation.target)
        if common.navigation.hasGoToPage {
            let page = OpID(common.navigation.goToPage.id)
            if Self.isPage(page, in: state) { goToPage = page } else { danglingPage = page }
        }
    }

    /// The click precedence rule: page, then link, then nothing.
    public var onClick: OnClick {
        if let goToPage { return .goToPage(goToPage) }
        if let url { return .openLink(url) }
        return .nothing
    }

    /// An object with both a link and a page target exports the page and warns about the link.
    public var hasUnusedLink: Bool { goToPage != nil && url != nil }

    /// `url` as read: nil when empty after trimming whitespace.
    public static func normalized(_ url: String) -> String? {
        url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : url
    }

    /// Whether `node` is a live page of the document (a child of 0:2 of kind `page`).
    public static func isPage(_ node: OpID, in state: EngineState) -> Bool {
        state.store.kind(node) == PageFields.kind && state.isLive(node) && state.store.placement(node)?.parent == WellKnown.pages
    }
}

/// The text-range links of text blocks (`link` marks): each run of characters carrying a
/// non-empty link.
public enum TextLinks {
    /// One linked run: live character offsets and the URL.
    public struct Run: Hashable, Sendable {
        public var range: Range<Int>
        public var url: String

        public init(range: Range<Int>, url: String) {
            self.range = range
            self.url = url
        }
    }

    /// The linked runs of text node `text`, adjacent runs with one URL joined.
    public static func runs(_ text: TextNode) -> [Run] {
        var result: [Run] = []
        for run in text.runs {
            let url = run.values.compactMap { value -> String? in
                if case .link(let link)? = value.value { return link }
                return nil
            }.first
            guard let url, NavigationInfo.normalized(url) != nil else { continue }
            if let last = result.last, last.url == url, last.range.upperBound == run.range.lowerBound {
                result[result.count - 1].range = last.range.lowerBound..<run.range.upperBound
            } else {
                result.append(Run(range: run.range, url: url))
            }
        }
        return result
    }

    /// The linked runs of the text node `node` (empty for any other node).
    public static func runs(_ node: OpID, in state: EngineState) -> [Run] {
        guard state.store.kind(node) == TextFields.kind, let text = TextNode(node, in: state) else { return [] }
        return runs(text)
    }

    /// The URL covering the whole live range `range` of `text` when it is one link throughout
    /// (the panel's *Text* and *Link* fields for a range selection), nil for none or mixed.
    public static func link(covering range: Range<Int>, in text: TextNode) -> String? {
        guard !range.isEmpty else { return nil }
        return runs(text).first { $0.range.lowerBound <= range.lowerBound && $0.range.upperBound >= range.upperBound }?.url
    }
}

/// Shared checks of the navigation commands.
enum Navigation {
    /// The kind numbers of the linkable `nodes`, duplicates removed, or throws for the first one
    /// that is not linkable.
    static func linkable(_ nodes: [OpID], in state: EngineState) throws -> [(node: OpID, kind: UInt32)] {
        var seen: Set<OpID> = []
        var result: [(OpID, UInt32)] = []
        for node in nodes where seen.insert(node).inserted {
            guard NavigationFields.isLinkable(node, in: state) else { throw NavigationError.notLinkable(node) }
            result.append((node, state.store.kind(node)))
        }
        return result
    }

    static func checkURL(_ url: String) throws {
        guard url.unicodeScalars.count <= NavigationFields.maxURL else { throw NavigationError.tooLong("url") }
    }

    /// "Link", or "Change link on N objects" when several objects change at once.
    static func label(_ verb: String, count: Int) -> String {
        count > 1 ? "Change link on \(count) objects" : verb
    }
}

// MARK: - Commands

/// Sets (or, with an empty string, clears) the object-level link of each node: one `SetFields`
/// of `url` per node in one change.  "Link" / "Remove Link", or "Change link on N objects" for
/// several (the Navigation panel on a multiple selection, and *Update everywhere*).  A URL is
/// stored exactly as typed.
public struct SetLink: Command {
    public var nodes: [OpID]
    public var url: String

    public init(_ nodes: [OpID], url: String) {
        self.nodes = nodes
        self.url = url
    }

    public var label: String { Navigation.label(url.isEmpty ? "Remove Link" : "Link", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try Navigation.checkURL(url)
        for (node, kind) in try Navigation.linkable(nodes, in: state) {
            builder.append(Ops.set(node, [NavigationFields.url(kind)], values: NavigationFields.values(kind: kind) { $0.url = url }))
        }
    }
}

/// Links (or, with an empty string, unlinks) the characters between two anchors of a text block:
/// one `link` mark, which later marks override where they overlap and which does not grow when
/// text is typed at its end (TYPE pages).  "Link" / "Remove Link".
public struct SetTextLink: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var url: String

    public init(node: OpID, from start: Anchor, to end: Anchor, url: String) {
        self.node = node
        self.start = start
        self.end = end
        self.url = url
    }

    public var label: String { url.isEmpty ? "Remove Link" : "Link" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try Navigation.checkURL(url)
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.link = url
        try ApplyMark(node: node, from: start, to: end, value: value, label: label).execute(&builder, state: state)
    }
}

/// Sets the link's alt text (`navigation.alt`, describing the destination) on each node.
/// "Link Alt Text".
public struct SetLinkAlt: Command {
    public var nodes: [OpID]
    public var alt: String
    public var label: String { "Link Alt Text" }

    public init(_ nodes: [OpID], alt: String) {
        self.nodes = nodes
        self.alt = alt
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard alt.unicodeScalars.count <= NavigationFields.maxAlt else { throw NavigationError.tooLong("alt") }
        for (node, kind) in try Navigation.linkable(nodes, in: state) {
            builder.append(Ops.set(node, [NavigationFields.alt(kind)], values: NavigationFields.values(kind: kind) { $0.navigation.alt = alt }))
        }
    }
}

/// Sets *Opens in* (`navigation.target`) on each node.  "Opens In".
public struct SetLinkTarget: Command {
    public var nodes: [OpID]
    public var target: LinkOpens
    public var label: String { "Opens In" }

    public init(_ nodes: [OpID], target: LinkOpens) {
        self.nodes = nodes
        self.target = target
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, kind) in try Navigation.linkable(nodes, in: state) {
            builder.append(Ops.set(node, [NavigationFields.target(kind)], values: NavigationFields.values(kind: kind) { $0.navigation.target = target.stored }))
        }
    }
}

/// Sets the page-to-page link (`navigation.go_to_page`) of each node, or clears it with nil
/// (*On click* › *Nothing*, which leaves `url` alone).  "Link to page N" / "Remove page link".
public struct SetGoToPage: Command {
    public var nodes: [OpID]
    public var page: OpID?
    /// The page's number, for the label (the panel knows it).
    public var pageNumber: Int?

    public init(_ nodes: [OpID], page: OpID?, pageNumber: Int? = nil) {
        self.nodes = nodes
        self.page = page
        self.pageNumber = pageNumber
    }

    public var label: String {
        guard page != nil else { return "Remove page link" }
        return pageNumber.map { "Link to page \($0)" } ?? "Link to page"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let page, !NavigationInfo.isPage(page, in: state) { throw NavigationError.notAPage(page) }
        for (node, kind) in try Navigation.linkable(nodes, in: state) {
            let values = NavigationFields.values(kind: kind) { common in
                if let page { common.navigation.goToPage.id = page.proto }
            }
            builder.append(Ops.set(node, [NavigationFields.goToPage(kind)], values: values))
        }
    }
}

/// *Update everywhere* (WEB-003's model half): rewrites the link of every use found -- objects'
/// `url` and text ranges' `link` marks -- to `url`, as one change labelled "Change link on N
/// objects".  Only the uses given are rewritten, so an object linked to the old URL concurrently
/// on another replica keeps it (urls.adoc, "Update everywhere").
public struct ReplaceLink: Command {
    public var uses: LinkUses
    public var url: String

    public init(_ uses: LinkUses, with url: String) {
        self.uses = uses
        self.url = url
    }

    public var label: String {
        let count = uses.count
        return count == 1 ? (url.isEmpty ? "Remove Link" : "Link") : "Change link on \(count) objects"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try Navigation.checkURL(url)
        for (node, kind) in try Navigation.linkable(uses.nodes, in: state) {
            builder.append(Ops.set(node, [NavigationFields.url(kind)], values: NavigationFields.values(kind: kind) { $0.url = url }))
        }
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.link = url
        for range in uses.ranges {
            guard let text = TextNode(range.node, in: state), range.range.upperBound <= text.length, !range.range.isEmpty else { continue }
            try ApplyMark(node: range.node, from: text.anchor(at: range.range.lowerBound), to: text.anchor(at: range.range.upperBound), value: value)
                .execute(&builder, state: state)
        }
    }
}
