import WTCRDT
import WTProto
import WTRender
import WTText

/// The fonts of one open document's text (TXT-002; font-substitution.adoc, "Client"): its WTText
/// `FontManager` (the substitution tables it resolves through), the `TextLayoutEngine` its text
/// is laid out with, and the faces its text names, kept from the changes it applies -- local and
/// remote -- so the Missing Fonts sheet, the substitution badge and the print check read a report
/// without laying anything out, and a font activation or a changed substitution re-lays out just
/// the text whose faces now resolve differently.
///
/// A face is what a run's marks name: the winning `font_family` mark and, when there is one, the
/// winning `font_style` mark; where a run has no family or style mark of its own, its character
/// style's (the `style` mark, through `based_on`; a deleted style's cached settings).
/// A run naming no family is the document default and is not reported (WTText does the same).
/// Only text that is drawn counts: a text node whose node or an enclosing group is deleted is
/// left out (a deleted layer's objects are still shown, so a deleted layer does not hide them).
@MainActor
public final class DocumentFontIndex {
    /// The manager this document's text resolves through: one per document, so its
    /// `documentSubstitutions` stay its own (`FontManager.shared` shares the remembered rows).
    public let manager: FontManager
    /// The layout engine for this document's text (`TextLayoutEngine(fonts: manager)`).
    public let layoutEngine: TextLayoutEngine
    /// Text node → the faces its runs name (text naming none is left out).
    public private(set) var faces: [OpID: Set<FaceName>] = [:]
    /// How each named face resolved when last checked.
    public private(set) var resolutions: [FaceName: FontResolution] = [:]
    private var generation: Int

    /// The fonts of the document in `state`, resolved through `manager` (a fresh manager with the
    /// standard table when none is given; the app passes the preference's table).
    public init(state: EngineState, manager: FontManager = FontManager()) {
        self.manager = manager
        layoutEngine = TextLayoutEngine(fonts: manager)
        generation = manager.generation
        reload(state)
    }

    // MARK: Tables

    /// The remembered substitutions and the default substitute (*Font substitutions*
    /// preference, `Preferences.font_substitutions`).
    public var substitutions: FontSubstitutionTable {
        get { manager.substitutions }
        set { manager.substitutions = newValue }
    }

    /// This document's own substitutions on this Mac (the sheet without *Remember this
    /// substitution*, restored from the per-document `view` record); before the remembered rows.
    public var documentSubstitutions: [FontSubstitution] {
        get { manager.documentSubstitutions }
        set { manager.documentSubstitutions = newValue }
    }

    /// The team font library's catalog families (reported as waiting for the library).
    public var teamLibraryFamilies: Set<String> {
        get { manager.teamLibraryFamilies }
        set { manager.teamLibraryFamilies = newValue }
    }

    // MARK: Reports

    /// Every face the drawn text of `state` names: what the Missing Fonts sheet asks about
    /// before a document opens, without keeping an index.
    public nonisolated static func namedFaces(in state: EngineState) -> Set<FaceName> {
        faces(in: state).values.reduce(into: []) { $0.formUnion($1) }
    }

    /// Every face the document's drawn text names.
    public var allFaces: Set<FaceName> {
        faces.values.reduce(into: []) { $0.formUnion($1) }
    }

    /// The report over every face the document names, without laying out: what the Missing Fonts
    /// sheet reads before the document's first render (`facesNeedingSheet`), the badge
    /// (`substitutedFaces`) and the print check.
    public func report() -> FontReport {
        manager.report(for: allFaces)
    }

    /// The report over `faces` (a selection's, a print job's).
    public func report(for faces: Set<FaceName>) -> FontReport {
        manager.report(for: faces)
    }

    /// The text nodes naming `face`.
    public func nodes(naming face: FaceName) -> Set<OpID> {
        Set(faces.filter { $0.value.contains(face) }.keys)
    }

    // MARK: Keeping up

    /// Re-reads every text node of `state` (a document opened or its state replaced).
    public func reload(_ state: EngineState) {
        faces = Self.faces(in: state)
        recordResolutions()
    }

    /// Takes a change the document applied (`Document.observe`): re-reads the text nodes it
    /// touched, the subtrees it deleted, restored or moved, and every text node when it changed a
    /// style; a reload reads everything.
    public func apply(_ event: DocumentEvent) {
        guard event.origin != .reload else {
            reload(event.after)
            return
        }
        let state = event.after
        var nodes: Set<OpID> = []
        var styles = false
        for (op, id) in zip(event.change.ops, event.change.opIDs) {
            switch op.op {
            case .create?:
                nodes.insert(id)
            case .setDeleted(let delete)?:
                Self.subtree(OpID(delete.node), in: state, into: &nodes)
            case .move(let move)?:
                Self.subtree(OpID(move.node), in: state, into: &nodes)
            default:
                for (node, _) in DocumentDisplayListBuilder.targets(op) {
                    nodes.insert(node)
                    styles = styles || state.store.kind(node) == Self.styleKind
                }
            }
        }
        if styles {
            faces = Self.faces(in: state)
        } else {
            for node in nodes {
                let named = Self.isDrawnText(node, in: state) ? Self.faces(of: node, in: state) : []
                faces[node] = named.isEmpty ? nil : named
            }
        }
        recordResolutions()
    }

    /// After the fonts could resolve differently (`FontManager.generation` moved: a font
    /// activated, Font Book changed, a substitution row or the team catalog changed): the text
    /// nodes naming a face that now resolves differently, which the caller re-lays out
    /// (`DocumentDisplayListBuilder.invalidate`) and repaints.  Empty when nothing moved.
    public func fontsChanged() -> Set<OpID> {
        let current = manager.generation
        guard current != generation else { return [] }
        generation = current
        var changed: Set<FaceName> = []
        for face in allFaces {
            let now = manager.resolve(face)
            if resolutions[face] != now {
                changed.insert(face)
                resolutions[face] = now
            }
        }
        guard !changed.isEmpty else { return [] }
        return Set(faces.filter { !$0.value.isDisjoint(with: changed) }.keys)
    }

    private func recordResolutions() {
        let named = allFaces
        resolutions = resolutions.filter { named.contains($0.key) }
        for face in named where resolutions[face] == nil {
            resolutions[face] = manager.resolve(face)
        }
    }

    // MARK: Reading faces

    nonisolated static let textKind: UInt32 = 130
    nonisolated static let styleKind: UInt32 = 154

    /// Every drawn text node of `state` with the faces it names.
    public nonisolated static func faces(in state: EngineState) -> [OpID: Set<FaceName>] {
        var result: [OpID: Set<FaceName>] = [:]
        for node in state.store.nodes where state.store.kind(node) == textKind && isDrawnText(node, in: state) {
            let named = faces(of: node, in: state)
            if !named.isEmpty { result[node] = named }
        }
        return result
    }

    /// The faces the live runs of text node `node` name.
    public nonisolated static func faces(of node: OpID, in state: EngineState) -> Set<FaceName> {
        var result: Set<FaceName> = []
        var styleFaces: [OpID: (family: String?, style: String?)] = [:]
        for path in state.store.textPaths(node) {
            guard let text = state.store.text(node, path) else { continue }
            for run in text.runs {
                var family: String?
                var style: String?
                var characterStyle: Wiretuner_Doc_V1_NodeRef?
                for attribute in run.attributes {
                    guard let value = try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: attribute.value) else { continue }
                    switch value.value {
                    case .fontFamily(let name)?: family = name
                    case .fontStyle(let name)?: style = name
                    case .style(let ref)?: characterStyle = ref
                    default: break
                    }
                }
                if family == nil || style == nil, let ref = characterStyle {
                    let id = OpID(ref.id)
                    let inherited = styleFaces[id] ?? characterFont(ref, in: state)
                    styleFaces[id] = inherited
                    family = family ?? inherited.family
                    style = style ?? inherited.style
                }
                if let family, !family.isEmpty {
                    result.insert(FaceName(family: family, style: style.flatMap { $0.isEmpty ? nil : $0 }))
                }
            }
        }
        return result
    }

    /// The family and style a character style names: its own settings, then those of the styles
    /// it is based on; a deleted style's cached settings.
    nonisolated static func characterFont(_ ref: Wiretuner_Doc_V1_NodeRef, in state: EngineState) -> (family: String?, style: String?) {
        var family: String?
        var style: String?
        var current: OpID? = OpID(ref.id)
        var seen: Set<OpID> = []
        func take(_ settings: Wiretuner_Doc_V1_CharacterSettings) {
            if family == nil, settings.hasFontFamily { family = settings.fontFamily }
            if style == nil, settings.hasFontStyle { style = settings.fontStyle }
        }
        if !state.isLive(OpID(ref.id)) || state.store.kind(OpID(ref.id)) != styleKind {
            if let cached = try? Wiretuner_Doc_V1_TextStyleAttrs(serializedBytes: ref.cached) { take(cached.character) }
            return (family, style)
        }
        while let id = current, seen.insert(id).inserted, state.isLive(id), state.store.kind(id) == styleKind {
            let props = state.props(id).style
            take(props.text.character)
            current = props.hasBasedOn ? OpID(props.basedOn.id) : nil
        }
        return (family, style)
    }

    /// Whether text node `node` is drawn: it and every enclosing node other than a layer live.
    nonisolated static func isDrawnText(_ node: OpID, in state: EngineState) -> Bool {
        guard state.store.kind(node) == textKind else { return false }
        var current: OpID? = node
        while let id = current {
            if state.store.kind(id) != LayerFields.kind, !state.isLive(id) { return false }
            current = state.store.placement(id)?.parent
        }
        return true
    }

    /// `node` and every node below it.
    nonisolated static func subtree(_ node: OpID, in state: EngineState, into result: inout Set<OpID>) {
        guard result.insert(node).inserted else { return }
        for child in state.store.children(node) {
            subtree(child, in: state, into: &result)
        }
    }
}
