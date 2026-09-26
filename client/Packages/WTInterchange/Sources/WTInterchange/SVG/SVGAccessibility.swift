// SVG accessibility output (IO-031; export-vector.adoc, "What SVG keeps live" and "Client";
// names-notes.adoc).  An object with alt text becomes a figure: `role="img"`, a `<title>` (the
// first line of the text) as its first child and a `<desc>` (the other lines) after it, named by
// `aria-labelledby` and `aria-describedby`.  A decorative object gets `aria-hidden="true"`.  A
// group with alt text is one figure and its members carry nothing of their own; a decorative
// group hides its members with it.  Live text is read as its characters and gets nothing; text
// written as outlines is a figure titled with its characters, so it is still read.  An `<a>` keeps
// the link's own `<title>`; the object's sits on the element inside it, so both are read.
// Rasterized effects are `<image>` elements tagged with their node, so they carry its figure.
//
// Nothing is written unless some object of the document has alt text or is decorative: the
// files of undescribed documents are unchanged.

import WTRender

/// What an element says to assistive technology.
enum SVGAccessibility: Equatable {
    case none
    /// Described: the description, first line the title.
    case figure(String)
    /// Decorative: hidden from assistive technology.
    case hidden
}

extension SVGBuild {
    /// `text` as a description: trimmed, nil when nothing is left.
    static func description(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A description's title (its first line) and the rest (the `<desc>`), blank lines dropped.
    static func label(_ description: String) -> (title: String, desc: String?) {
        let lines = description.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let rest = lines.dropFirst().joined(separator: "\n")
        return (lines.first ?? description, rest.isEmpty ? nil : rest)
    }

    /// What `node` says, from its alt text and *Decorative*, or from the characters of outlined
    /// text.  Nothing inside an open figure or hidden element, or when the document describes
    /// nothing.
    func accessibility(of node: FlatNode) -> SVGAccessibility {
        guard accessible, figureDepth == 0 else { return .none }
        let info = scene.info(for: node.node)
        if info?.decorative == true {
            return .hidden
        }
        if let description = Self.description(info?.alt) ?? outlinedCharacters(node) {
            return .figure(description)
        }
        return .none
    }

    /// The characters of `node` when it is text written as outlines: one outlined run, or a group
    /// holding only outlined runs and no object of its own (a text block's lines).
    func outlinedCharacters(_ node: FlatNode) -> String? {
        switch node {
        case .path(let path):
            return Self.description(path.readAs)
        case .group(let group):
            var runs: [String] = []
            for child in group.children {
                guard child.node == nil, let characters = outlinedCharacters(child) else { return nil }
                runs.append(characters)
            }
            return Self.description(runs.joined(separator: " "))
        default:
            return nil
        }
    }

    /// Live text the writer outlines after all (its glyphs do not map onto its characters, or its
    /// font cannot be embedded) is read as its characters.
    func readAsOutlines(_ characters: String) {
        guard accessible, figureDepth == 0, pending == .none, let description = Self.description(characters) else { return }
        pending = .figure(description)
    }

    /// Opens `name`, marked as `pending` says: a figure's attributes and its `<title>` and `<desc>`
    /// children, or `aria-hidden`.  The caller closes it.
    func begin(_ name: String, _ attributes: [(String, String?)]) {
        let marks = pending
        pending = .none
        switch marks {
        case .none:
            body.start(name, attributes)
        case .hidden:
            body.start(name, attributes + [("aria-hidden", "true")])
        case .figure(let description):
            let (title, desc) = Self.label(description)
            let titleID = ids.generate("wt-title-")
            let descID = desc.map { _ in ids.generate("wt-desc-") }
            body.start(name, attributes + [("role", "img"), ("aria-labelledby", titleID), ("aria-describedby", descID)])
            body.element("title", [("id", titleID)], text: title)
            if let desc, let descID {
                body.element("desc", [("id", descID)], lines: desc)
            }
            figures += 1
        }
    }

    /// An element with no children of its own (or only `text`), marked as `pending` says.  A
    /// described `<text>` is wrapped in a figure group: a `<title>` inside it would be character
    /// data under `xml:space="preserve"`.
    func emit(_ name: String, _ attributes: [(String, String?)], text: String? = nil) {
        guard let text else {
            begin(name, attributes)
            body.end()
            return
        }
        switch pending {
        case .figure:
            begin("g", [])
            body.element(name, attributes, text: text)
            body.end()
        case .hidden:
            pending = .none
            body.element(name, attributes + [("aria-hidden", "true")], text: text)
        case .none:
            body.element(name, attributes, text: text)
        }
    }

    // MARK: Root

    /// The root `<svg>`'s role and label references: `img` when nothing on the page is a figure,
    /// `group` when something is (an `img` root makes its children presentational, so the
    /// figures would not be read).
    func rootAccessibility() -> [(String, String?)] {
        guard accessible else { return [] }
        let (_, desc) = rootLabel
        rootIDs = (ids.generate("wt-title-"), desc.map { _ in ids.generate("wt-desc-") })
        return [("role", figures > 0 ? "group" : "img"), ("aria-labelledby", rootIDs.title), ("aria-describedby", rootIDs.desc)]
    }

    /// The root's title -- Document Info's title, else the file name -- and description.
    var rootLabel: (title: String, desc: String?) {
        let info = scene.info
        let metadata = info.metadata?.normalized
        let title = Self.description(metadata?.title) ?? Self.description(info.title) ?? scene.name
        return (title, Self.description(metadata?.description) ?? Self.description(info.description))
    }

    func writeRootLabel(into out: inout XMLStream) {
        let (title, desc) = rootLabel
        out.element("title", [("id", rootIDs.title)], lines: title)
        if let desc, let id = rootIDs.desc {
            out.element("desc", [("id", id)], lines: desc)
        }
    }
}
