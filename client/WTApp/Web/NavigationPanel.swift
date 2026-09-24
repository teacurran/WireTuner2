import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Navigation panel's reading of the selection (WEB-002; urls.adoc, "The Navigation panel"):
/// the selected objects' name, link alt text, link, target and page link, each `nil` when the
/// values differ (*Mixed*); in text-range mode (the Text tool has characters selected) the range's
/// `link` mark and its words instead.  Every write is one change.
@MainActor
struct NavigationPanelModel {
    let window: DocumentWindowController
    let web: WindowWeb
    let nodes: [OpID]
    /// The Text tool's selection: the block and the characters.
    let range: (node: OpID, range: Range<Int>)?

    init(window: DocumentWindowController, web: WindowWeb) {
        self.window = window
        self.web = web
        let state = window.documentHandle.state
        nodes = window.selection.selection.ids.map(\.opID).filter { NavigationFields.isLinkable($0, in: state) }
        if let editor = window.textEditor, let node = editor.node, !editor.selectedRange.isEmpty {
            range = (node, editor.selectedRange)
        } else {
            range = nil
        }
    }

    var state: EngineState { window.documentHandle.state }
    var isTextRange: Bool { range != nil }
    var hasSelection: Bool { isTextRange || !nodes.isEmpty }
    var infos: [NavigationInfo] { nodes.map { NavigationInfo($0, in: state) } }

    /// One value when every selected object shares it, nil when they differ.
    static func shared<Value: Equatable>(_ values: [Value]) -> Value?? {
        guard let first = values.first else { return .some(nil) }
        return values.allSatisfy { $0 == first } ? .some(first) : .none
    }

    var name: String?? {
        Self.shared(nodes.map { NavigationFields.common(of: $0, in: state)?.name ?? "" })
    }

    var alt: String?? { Self.shared(infos.map { $0.alt ?? "" }) }

    /// The link: the range's mark in text-range mode, else the objects'.
    var link: String?? {
        if let range, let text = state.textNode(range.node) {
            return .some(TextLinks.link(covering: range.range, in: text) ?? "")
        }
        return Self.shared(infos.map { $0.url ?? "" })
    }

    /// *Text*: the range's words, or a text block's own link.
    var text: String {
        if let range, let text = state.textNode(range.node) {
            let scalars = Array(text.string.unicodeScalars)
            let bounded = range.range.clamped(to: 0..<scalars.count)
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[bounded])
            return String(view)
        }
        if nodes.count == 1, state.store.kind(nodes[0]) == TextFields.kind {
            return TextLinks.runs(nodes[0], in: state).map(\.url).joined(separator: ", ")
        }
        return ""
    }

    var target: LinkOpens?? { Self.shared(infos.map(\.target)) }

    /// *On click* (WEB-021): nothing, a page, or the link.
    enum Click: Hashable {
        case nothing, page(OpID), link, deletedPage
    }

    var click: Click?? {
        Self.shared(infos.map { info -> Click in
            if info.danglingPage != nil && info.goToPage == nil { return .deletedPage }
            switch info.onClick {
            case .nothing: return .nothing
            case .goToPage(let page): return .page(page)
            case .openLink: return .link
            }
        })
    }

    var pages: [Page] { window.documentHandle.pageList.pages }

    /// Every distinct link in the document, for the pop-up.
    var documentLinks: [String] { web.links.urls(in: state) }

    // MARK: Writes

    /// A text field's committed draft: *Name*, *Alt text* or *Link*.
    @discardableResult
    func write(_ field: String, _ text: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        switch field {
        case "name": setName(text)
        case "alt": setAlt(text)
        default: setLink(text)
        }
    }

    @discardableResult
    func setName(_ name: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !nodes.isEmpty else { return nil }
        return window.objectEditing.perform(SetNameOrNote(nodes, .name, name))
    }

    @discardableResult
    func setAlt(_ alt: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !nodes.isEmpty else { return nil }
        return window.objectEditing.perform(SetLinkAlt(nodes, alt: alt))
    }

    /// kbd:[Return] in *Link*: the range's mark, *Update everywhere* when the selection is what
    /// *Find* selected, else each selected object's link.
    @discardableResult
    func setLink(_ url: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range, let text = state.textNode(range.node) {
            return window.objectEditing.perform(SetTextLink(node: range.node, from: text.anchor(at: range.range.lowerBound),
                                                            to: text.anchor(at: range.range.upperBound), url: url))
        }
        if let found = web.found, Set(found.uses.nodes + found.uses.ranges.map(\.node)) == Set(window.selection.selection.ids.map(\.opID)) {
            web.found = nil
            return window.objectEditing.perform(ReplaceLink(found.uses, with: url))
        }
        guard !nodes.isEmpty else { return nil }
        return window.objectEditing.perform(SetLink(nodes, url: url))
    }

    @discardableResult
    func setTarget(_ target: LinkOpens) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !nodes.isEmpty else { return nil }
        return window.objectEditing.perform(SetLinkTarget(nodes, target: target))
    }

    /// *On click*: a page writes `go_to_page`; *Nothing* clears it and leaves the link.
    @discardableResult
    func setClick(_ click: Click) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !nodes.isEmpty else { return nil }
        switch click {
        case .page(let page):
            return window.objectEditing.perform(SetGoToPage(nodes, page: page, pageNumber: pages.first { $0.id == page }?.number))
        case .nothing, .link, .deletedPage:
            return window.objectEditing.perform(SetGoToPage(nodes, page: nil))
        }
    }

    /// btn:[Find]: selects every object and text block using `url` and scrolls to the first.
    @discardableResult
    func find(_ url: String) -> Int {
        let uses = web.links.uses(of: url, in: state)
        let ids = (uses.nodes + uses.ranges.map(\.node)).map(SelectionID.init)
        var seen: Set<SelectionID> = []
        let unique = ids.filter { seen.insert($0).inserted }
        window.selection.model.apply(unique, mode: .replace)
        web.found = unique.isEmpty ? nil : (url, uses)
        if !unique.isEmpty { window.fit(selection: window.selection.selectedBounds) }
        let count = uses.count
        window.statusBar.show(message: count == 1 ? "1 use of \(url) found" : "\(count) uses of \(url) found")
        return count
    }
}

/// A field that commits on kbd:[Return] and remembers what the model held when typing began, so
/// a remote change underneath shows the "changed by someone else" hint instead of replacing the
/// keystrokes.
@MainActor
@Observable
final class NavigationFieldState {
    var drafts: [String: String] = [:]
    var baselines: [String: String] = [:]

    init() {}

    /// The field's text: the draft while one is open, else the model's value.
    func text(_ field: String, stored: String) -> String { drafts[field] ?? stored }

    func edit(_ field: String, _ text: String, stored: String) {
        if drafts[field] == nil { baselines[field] = stored }
        drafts[field] = text
    }

    /// Whether the value changed underneath an open draft.
    func changedUnderneath(_ field: String, stored: String) -> Bool {
        drafts[field] != nil && baselines[field] != stored
    }

    /// The draft to commit, closing it.
    func commit(_ field: String) -> String? {
        baselines[field] = nil
        return drafts.removeValue(forKey: field)
    }

    func revert(_ field: String) {
        drafts[field] = nil
        baselines[field] = nil
    }
}

enum NavigationPanel {
    @MainActor
    static func descriptor(state: WebPanelState, features: WebFeatures) -> PanelDescriptor {
        PanelDescriptor(id: WebFeatures.navigationPanel, title: "Navigation", icon: "link", defaultGroup: PanelCatalog.Group.navigation, menuOrder: 70,
                        helpSlug: "urls") {
            NavigationPanelBody(state: state, fields: NavigationFieldState())
        }
    }

    static let mixed = "Mixed"
    static let deletedPage = "(deleted page)"

    /// A text field's binding: typing opens a draft; the model value shows otherwise.
    @MainActor
    static func binding(_ fields: NavigationFieldState, _ field: String, stored: String) -> Binding<String> {
        Binding(get: { fields.text(field, stored: stored) }, set: { fields.edit(field, $0, stored: stored) })
    }

    /// kbd:[Return]: the draft is written.
    @MainActor
    static func commit(_ fields: NavigationFieldState, _ field: String, _ model: NavigationPanelModel) -> () -> Void {
        { if let text = fields.commit(field) { model.write(field, text) } }
    }

    @MainActor
    static func target(_ model: NavigationPanelModel) -> Binding<LinkOpens?> {
        Binding(get: { model.target ?? nil }, set: { if let target = $0 { model.setTarget(target) } })
    }

    @MainActor
    static func click(_ model: NavigationPanelModel) -> Binding<NavigationPanelModel.Click?> {
        Binding(get: { model.click ?? nil }, set: { if let click = $0 { model.setClick(click) } })
    }

    @MainActor
    static func chooseLink(_ model: NavigationPanelModel, _ fields: NavigationFieldState, _ url: String) -> () -> Void {
        {
            fields.revert("link")
            if model.hasSelection { model.setLink(url) } else { fields.edit("link", url, stored: "") }
        }
    }

    @MainActor
    static func find(_ model: NavigationPanelModel, _ fields: NavigationFieldState) -> () -> Void {
        { model.find(fields.text("link", stored: (model.link ?? nil) ?? "")) }
    }
}

struct NavigationPanelBody: View {
    let state: WebPanelState
    let fields: NavigationFieldState

    var body: some View {
        let _ = state.revision
        if let front = state.front {
            let _ = front.web.revision
            NavigationPanelContent(model: NavigationPanelModel(window: front.window, web: front.web), fields: fields)
        } else {
            Text("Open a document to see its links.").font(.callout).foregroundStyle(.secondary).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct NavigationPanelContent: View {
    let model: NavigationPanelModel
    let fields: NavigationFieldState

    private func row(_ title: String, _ field: String, value: String??, enabled: Bool) -> some View {
        let stored = (value ?? nil) ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).frame(width: 70, alignment: .trailing)
                TextField(value == nil ? NavigationPanel.mixed : "", text: NavigationPanel.binding(fields, field, stored: stored))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(NavigationPanel.commit(fields, field, model))
                    .disabled(!enabled)
                    .accessibilityIdentifier("navigation.\(field)")
            }
            if fields.changedUnderneath(field, stored: stored) {
                Text("Changed by someone else — press Return to keep yours").font(.caption).foregroundStyle(.orange).padding(.leading, 76)
            }
        }
    }

    var body: some View {
        let objects = !model.nodes.isEmpty && !model.isTextRange
        VStack(alignment: .leading, spacing: 6) {
            row("Name", "name", value: model.name, enabled: objects)
            row("Alt text", "alt", value: model.alt, enabled: objects)
            HStack {
                row("Link", "link", value: model.link, enabled: true)
                Menu {
                    ForEach(model.documentLinks, id: \.self) { url in
                        Button(url, action: NavigationPanel.chooseLink(model, fields, url))
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("navigation.links")
                Button("Find", action: NavigationPanel.find(model, fields)).accessibilityIdentifier("navigation.find")
            }
            HStack {
                Text("Text").frame(width: 70, alignment: .trailing)
                Text(model.text).foregroundStyle(.secondary).lineLimit(2).accessibilityIdentifier("navigation.text")
            }
            Picker("Opens in", selection: NavigationPanel.target(model)) {
                Text("Same window").tag(LinkOpens.sameWindow as LinkOpens?)
                Text("New tab").tag(LinkOpens.newTab as LinkOpens?)
                if model.target == nil { Text(NavigationPanel.mixed).tag(nil as LinkOpens?) }
            }
            .disabled(!objects)
            Picker("On click", selection: NavigationPanel.click(model)) {
                Text("Nothing").tag(NavigationPanelModel.Click.nothing as NavigationPanelModel.Click?)
                Text("Open link").tag(NavigationPanelModel.Click.link as NavigationPanelModel.Click?)
                ForEach(model.pages) { page in
                    Text("Go to \(page.name)").tag(NavigationPanelModel.Click.page(page.id) as NavigationPanelModel.Click?)
                }
                if model.click == .some(.deletedPage) { Text(NavigationPanel.deletedPage).tag(NavigationPanelModel.Click.deletedPage as NavigationPanelModel.Click?) }
                if model.click == nil { Text(NavigationPanel.mixed).tag(nil as NavigationPanelModel.Click?) }
            }
            .disabled(!objects)
            .accessibilityIdentifier("navigation.onClick")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
