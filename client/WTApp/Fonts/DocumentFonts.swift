import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTSync
import WTText

/// Fonts per open document (font-substitution.adoc, "Client"; DOC-024).  When a document opens,
/// its embedded fonts are activated from the blob cache, faces the team's library offers are
/// fetched (silently; offline, the ones fetched before load from the cache), and the Missing
/// Fonts sheet is shown when a face is still left to the default substitute; btn:[Open] applies
/// the choices (the document's rows on this Mac, the remembered rows in the preference, the
/// replacements as one change) and btn:[Cancel] closes the document without writing to it.
/// Closing the document deactivates its embedded fonts (a font two documents embed stays until
/// both are closed).
///
/// Each document has a `DocumentFontIndex` (WTModel) over its own `FontManager` -- the document's
/// rows before the remembered ones -- kept current from the document's changes.  Whenever fonts
/// could resolve differently (an activation, a substitution), the text whose faces now resolve
/// differently is laid out again and repainted (`DocumentHandle.relayout`).
/// `FontManager.shared` follows the preference for layout that is not per document.
@MainActor
final class DocumentFonts {
    let preferences: PreferenceStore
    let substitutions = DocumentSubstitutionStore()
    /// The team font libraries; nil without them.
    var team: (any TeamFontLibrary)?
    /// The file of a cached blob (lower-case hex hash), nil when this Mac does not have it.
    var blobFile: @MainActor (String) -> URL? = { hash in
        (try? BlobCache.defaultDirectory()).map { BlobCache(directory: $0).url(for: hash) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    /// Shows the sheet on the window (the test hook records it).
    var present: @MainActor (NSWindow, DocumentWindowController) -> Void = { sheet, window in window.window?.beginSheet(sheet) }
    /// Closes every view of a document (btn:[Cancel]).
    var closeDocument: @MainActor (DocumentWindowController) -> Void = { $0.window?.close() }

    /// Each open document's fonts, with the document and the observation feeding its index.
    private var open: [String: (index: DocumentFontIndex, document: DocumentHandle, observation: WTModel.Document.ObservationToken)] = [:]
    /// The embedded font files each document activated.
    private var activated: [String: [URL]] = [:]
    /// How many open documents activated each file.
    private var activations: [URL: Int] = [:]
    /// The sheets showing, by document id.
    private(set) var sheets: [String: (window: NSWindow, model: MissingFontsModel)] = [:]
    private var observation: UUID?

    init(preferences: PreferenceStore) {
        self.preferences = preferences
        FontManager.shared.substitutions = FontSubstitutionRows.table(preferences)
        observation = preferences.observe { [weak self] change in
            guard let self, Self.substitutionKeys.contains(change.id) else { return }
            self.substitutionsDidChange()
        }
    }

    static let substitutionKeys: Set<String> = [PreferenceCatalog.Text.fontSubstitutions.id, PreferenceCatalog.Text.defaultSubstitute.id]

    /// The preference changed: every document takes the new table.
    func substitutionsDidChange() {
        let table = FontSubstitutionRows.table(preferences)
        FontManager.shared.substitutions = table
        for entry in open.values { entry.index.substitutions = table }
        fontsChanged()
    }

    /// The font index of an open document.
    func index(for documentID: String) -> DocumentFontIndex? { open[documentID]?.index }

    /// The fonts could resolve differently: every open document lays out again the text whose
    /// faces now do.
    func fontsChanged() {
        for entry in open.values {
            let nodes = entry.index.fontsChanged()
            if !nodes.isEmpty { entry.document.relayout(nodes) }
        }
    }

    // MARK: Opening

    /// A document's first view opened: activate, fetch, and ask when a face is left to the
    /// default substitute.  Returns the sheet's model when it is shown.
    @discardableResult
    func documentDidOpen(_ window: DocumentWindowController) async -> MissingFontsModel? {
        let document = window.documentHandle
        guard let model = await document.openedModel() else { return nil }
        let manager = FontManager(substitutions: FontSubstitutionRows.table(preferences))
        manager.documentSubstitutions = await substitutions.rows(for: document)
        let library = team.flatMap { team in team.team(of: document.id).map { (team, $0) } }
        if let (team, id) = library { manager.teamLibraryFamilies = await team.families(team: id) }
        let index = DocumentFontIndex(state: model.state, manager: manager)
        let token = model.observe { [weak index] event in index?.apply(event) }
        open[document.id] = (index, document, token)
        document.useTextEngine(index.layoutEngine)
        activateEmbedded(EmbeddedFont.all(in: model.state), for: document.id)
        // The library's fonts are fetched silently -- offline, the ones fetched before still load
        // from the cache -- and only what is left asks.
        if let (team, id) = library {
            for family in index.report().teamLibraryPending.sorted() {
                for url in (try? await team.files(forFamily: family, team: id)) ?? [] {
                    _ = try? manager.activate(fontsAt: url, source: .teamLibrary)
                }
            }
        }
        fontsChanged()
        let report = index.report()
        let needing = report.facesNeedingSheet
        guard !needing.isEmpty else { return nil }
        // The library's faces still missing (offline, or the fetch failed) are listed too, for
        // btn:[Fetch from team library].
        let listed = needing.union(index.allFaces.filter { report.teamLibraryPending.contains($0.family) })
        let teamFonts = library.map { team, id in TeamFonts(isOnline: team.isOnline, families: manager.teamLibraryFamilies) { try await team.files(forFamily: $0, team: id) } }
        let sheetModel = MissingFontsModel(faces: Array(listed), defaultSubstitute: manager.substitutions.defaultSubstitute, catalog: manager, team: teamFonts)
        sheetModel.didActivate = { [weak self] in self?.fontsChanged() }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: MissingFontsSheet(model: sheetModel) { [weak self, weak window] open in
            guard let self, let window else { return }
            Task { await self.finish(window, open: open) }
        }))
        sheet.title = "Missing Fonts"
        sheet.identifier = NSUserInterfaceItemIdentifier("missing-fonts")
        sheets[document.id] = (sheet, sheetModel)
        present(sheet, window)
        return sheetModel
    }

    /// btn:[Open] or btn:[Cancel] on `window`'s sheet.  Substitutions are always applied (they
    /// cost nothing); replacements only on btn:[Open], as one change.  btn:[Cancel] then closes the
    /// document.
    func finish(_ window: DocumentWindowController, open: Bool) async {
        let document = window.documentHandle
        guard let (sheet, model) = sheets.removeValue(forKey: document.id) else { return }
        sheet.sheetParent?.endSheet(sheet)
        let decision = model.decision
        FontSubstitutionRows.remember(decision.rememberedRows, in: preferences)
        if !decision.documentRows.isEmpty {
            let rows = await substitutions.rows(for: document) + decision.documentRows
            await substitutions.setRows(rows, for: document)
            self.open[document.id]?.index.documentSubstitutions = rows
            fontsChanged()
        }
        guard open else {
            closeDocument(window)
            return
        }
        if !decision.replacements.isEmpty {
            _ = await document.perform(ReplaceFonts(decision.replacements)).value
        }
    }

    // MARK: Embedded fonts

    /// Activates the cached files of `fonts` for `documentID`; a file not cached yet, or one
    /// whose licence forbids embedding, is skipped.
    func activateEmbedded(_ fonts: [EmbeddedFont], for documentID: String) {
        var urls: [URL] = []
        for font in fonts {
            guard let url = blobFile(font.sha256), !urls.contains(url),
                  (try? FontManager.shared.activate(fontsAt: url, source: .embedded)) != nil else { continue }
            urls.append(url)
            activations[url, default: 0] += 1
        }
        activated[documentID, default: []] += urls
    }

    /// The document's last view closed: its sheet goes, its index stops following it, and its
    /// embedded fonts are deactivated unless another open document activated them too.
    func documentDidClose(_ document: DocumentHandle) {
        if let (sheet, _) = sheets.removeValue(forKey: document.id) { sheet.sheetParent?.endSheet(sheet) }
        if let entry = open.removeValue(forKey: document.id) { document.model?.stopObserving(entry.observation) }
        for url in activated.removeValue(forKey: document.id) ?? [] {
            if let count = activations[url], count > 1 {
                activations[url] = count - 1
            } else {
                activations[url] = nil
                FontManager.shared.deactivate(fontsAt: url)
            }
        }
        fontsChanged()
    }
}
