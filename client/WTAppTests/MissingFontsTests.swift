import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTSync
import WTText
@testable import WireTuner

/// Families and styles for the pickers without asking Core Text.
struct FakeFontCatalog: FontCatalog {
    func families() -> [String] { ["Georgia", "Helvetica Neue"] }
    func styles(of family: String) -> [String] { family == "Georgia" ? ["Italic", "Regular"] : [] }
}

/// A team font library that answers from memory.
@MainActor
final class FakeTeamFonts: TeamFontLibrary {
    struct Offline: Error {}
    var isOnline = true
    var teams: [String: String] = [:]
    var catalog: Set<String> = []
    var files: [String: [URL]] = [:]
    private(set) var fetched: [String] = []

    func team(of documentID: String) -> String? { teams[documentID] }
    func families(team: String) async -> Set<String> { catalog }
    func files(forFamily family: String, team: String) async throws -> [URL] {
        fetched.append(family)
        guard let urls = files[family] else { throw Offline() }
        return urls
    }
}

/// Counts a document's redraws that are not changes (text laid out again for its fonts).
@MainActor
final class Relayouts {
    private(set) var count = 0
    private var token: DocumentHandle.ObservationToken?

    init(_ document: DocumentHandle) {
        token = document.observe { [weak self] change in if change.change == nil { self?.count += 1 } }
    }
}

/// A document's text and fonts for the Missing Fonts tests.
@MainActor
enum FontDocuments {
    /// A family no Mac has, unique to the test.
    static func missing(_ tag: String = "Missing") -> String { "WT\(tag)\(UUID().uuidString.prefix(8))" }

    /// A text block whose runs name `fonts` (PostScript names, as an import writes them).
    @discardableResult
    static func text(_ document: DocumentHandle, _ fonts: [String]) async -> OpID? {
        let runs = fonts.enumerated().map { index, font in ImportedTextRun(text: "Ab", fontName: font, fontSize: 12, origin: Point(x: Double(index) * 30, y: 0)) }
        let scene = ImportedScene(kind: .vector, name: "Text", bounds: Rect(x: 0, y: 0, width: 100, height: 20), nodes: [.text(ImportedText(runs: runs))])
        let change = await document.perform(PlaceImportedScene(scene, placement: .at(.zero))).value
        return change.flatMap { PlaceImportedScene.placedRoot(of: $0, in: document.state) }
    }

    /// An `asset` under 0:9 holding a blob of `mediaType` whose hash is `byte` repeated.
    static func asset(_ document: DocumentHandle, byte: UInt8, mediaType: String) async {
        var asset = Wiretuner_Doc_V1_AssetProps()
        asset.sha256 = Data(repeating: byte, count: 32)
        asset.mediaType = mediaType
        var props = Wiretuner_Doc_V1_NodeProps()
        props.asset = asset
        _ = await document.perform(OpsCommand("Embed", ops: [Ops.create(parent: WellKnown.assets, position: [byte], props: props)])).value
    }

    /// A font file of `family` written to a scratch folder.
    static func fontFile(_ family: String) -> URL {
        let url = FontFixture.directory().appending(path: "\(family).ttf")
        try? FontFixture.font(family: family).write(to: url)
        return url
    }
}

/// DOC-024: the Missing Fonts sheet, the substitution preference and its table, replacing fonts,
/// embedded fonts and the team library.
@Suite(.serialized) @MainActor struct MissingFontsTests {
    @Test func substitutionRowsRoundTripThroughThePreference() {
        let bold = FontSubstitution(missing: FaceName(family: "Gone", style: "Bold"), substitute: FaceName(family: "Georgia", style: "Italic"))
        let any = FontSubstitution(missing: FaceName(family: "Gone"), substitute: FaceName(family: "Helvetica Neue"))
        #expect(FontSubstitutionRows.encode(bold) == "Gone\tBold\tGeorgia\tItalic")
        #expect(FontSubstitutionRows.decode(FontSubstitutionRows.encode(bold)) == bold && FontSubstitutionRows.decode(FontSubstitutionRows.encode(any)) == any)
        #expect(FontSubstitutionRows.decode("Gone") == nil && FontSubstitutionRows.decode("\t\tGeorgia\t") == nil && FontSubstitutionRows.decode("Gone\t\t\t") == nil)
        #expect(FontSubstitutionRows.title(bold) == "Gone Bold → Georgia Italic")
        #expect(FontSubstitutionRows.key(FaceName(family: "Gone", style: "BOLD")) == FontSubstitutionRows.key(bold.missing))

        let suite = TestDefaults()
        defer { suite.remove() }
        let preferences = PreferenceStore(defaults: suite.defaults)
        #expect(FontSubstitutionRows.table(preferences) == FontSubstitutionTable())
        FontSubstitutionRows.remember([], in: preferences)
        FontSubstitutionRows.remember([bold, any], in: preferences)
        _ = preferences.set(preferences[PreferenceCatalog.Text.fontSubstitutions] + ["junk"], for: PreferenceCatalog.Text.fontSubstitutions)
        let replaced = FontSubstitution(missing: FaceName(family: "Gone", style: "bold"), substitute: FaceName(family: "Courier"))
        FontSubstitutionRows.remember([replaced], in: preferences)
        #expect(FontSubstitutionRows.table(preferences).rows == [any, replaced], "a row for the same face is replaced; junk goes")
        _ = preferences.set("Georgia", for: PreferenceCatalog.Text.defaultSubstitute)
        #expect(FontSubstitutionRows.table(preferences).defaultSubstitute == FaceName(family: "Georgia"))
        _ = preferences.set("  ", for: PreferenceCatalog.Text.defaultSubstitute)
        #expect(FontSubstitutionRows.table(preferences).defaultSubstitute == FontSubstitutionTable.standardDefault)
    }

    @Test func thePreferenceTableListsRowsAndRemovesThem() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let store = PreferenceStore(defaults: suite.defaults)
        let key = PreferenceCatalog.Text.fontSubstitutions.erased
        let row = PreferenceFormRow(key: key)
        #expect(row.kind == .substitutionTable && key.accepts(.list([])))
        let bindings = PreferenceBindings(store: store, beep: {})
        #expect(bindings.substitutionRows(key).isEmpty)
        ColorPanelFixture.render(PreferenceRowView(row: row, bindings: bindings))
        let rows = [FontSubstitution(missing: FaceName(family: "A"), substitute: FaceName(family: "Georgia")),
                    FontSubstitution(missing: FaceName(family: "B"), substitute: FaceName(family: "Courier"))]
        _ = store.set(rows.map(FontSubstitutionRows.encode) + ["junk"], for: PreferenceCatalog.Text.fontSubstitutions)
        #expect(bindings.substitutionRows(key) == ["A → Georgia", "B → Courier"])
        ColorPanelFixture.render(PreferenceRowView(row: row, bindings: bindings))
        PreferenceRowView.removing(bindings, key, 0)()
        #expect(bindings.substitutionRows(key) == ["B → Courier"])
        bindings.removeSubstitution(key, at: 5)
        #expect(bindings.substitutionRows(key) == ["B → Courier"])
        let other = PreferenceCatalog.Text.defaultSubstitute.erased
        #expect(bindings.substitutionRows(other).isEmpty)
        bindings.removeSubstitution(other, at: 0)
    }

    @Test func theReaderFindsFacesAndEmbeddedFontsAndReplaceWritesOneChange() async throws {
        let document = DocumentHandle.memory(title: "Fonts")
        await document.settle()
        let missing = FontDocuments.missing()
        let text = try #require(await FontDocuments.text(document, [missing, "Helvetica-Bold", missing]))
        // A text block whose text node is deleted, inside a live group, names nothing.
        let gone = try #require(await FontDocuments.text(document, ["Courier"]))
        _ = await document.perform(DeleteNodes(document.state.liveChildren(gone))).value
        #expect(DocumentFontIndex.namedFaces(in: document.state) == [FaceName(family: missing), FaceName(family: "Helvetica", style: "Bold")])
        #expect(ReplaceFonts.face(of: []) == nil)
        await FontDocuments.asset(document, byte: 1, mediaType: "FONT/TTF")
        await FontDocuments.asset(document, byte: 2, mediaType: "image/png")
        #expect(EmbeddedFont.all(in: document.state) == [EmbeddedFont(sha256: String(repeating: "01", count: 32), mediaType: "FONT/TTF")])

        // Replacing a face writes its runs' family (and style, when the replacement has one).
        #expect(ReplaceFonts.matches(FaceName(family: "A", style: "Bold"), FaceName(family: "A")))
        #expect(ReplaceFonts.matches(FaceName(family: "A", style: "Bold"), FaceName(family: "A", style: "bold")))
        #expect(!ReplaceFonts.matches(FaceName(family: "A"), FaceName(family: "A", style: "Bold")))
        let replace = ReplaceFonts([ReplaceFonts.Replacement(old: FaceName(family: missing), new: FaceName(family: "Georgia", style: "Italic"))])
        #expect(replace.label == "Replace font \(missing) with Georgia Italic")
        _ = await document.perform(replace).value
        #expect(document.undoTitle == "Undo \(replace.label)")
        #expect(DocumentFontIndex.namedFaces(in: document.state) == [FaceName(family: "Georgia", style: "Italic"), FaceName(family: "Helvetica", style: "Bold")])
        let both = ReplaceFonts([ReplaceFonts.Replacement(old: FaceName(family: "Georgia"), new: FaceName(family: "Courier")),
                                 ReplaceFonts.Replacement(old: FaceName(family: "Helvetica", style: "Bold"), new: FaceName(family: "Times"))])
        #expect(both.label == "Replace 2 fonts")
        _ = await document.perform(both).value
        #expect(DocumentFontIndex.namedFaces(in: document.state) == [FaceName(family: "Courier", style: "Italic"), FaceName(family: "Times", style: "Bold")])
        _ = await document.perform(DeleteNodes([text])).value
        #expect(DocumentFontIndex.namedFaces(in: document.state).isEmpty)
    }

    @Test func theSheetSelectsSubstitutesReplacesAndDecides() {
        let gone = FaceName(family: "Gone", style: "Bold"), lost = FaceName(family: "Lost"), team = FaceName(family: "TeamFont")
        let model = MissingFontsModel(faces: [lost, gone, team], defaultSubstitute: FaceName(family: "Helvetica Neue"), catalog: FakeFontCatalog())
        #expect(model.rows.map(\.face) == [gone, lost, team] && !model.hasSelection && !model.canFetch && model.fetchHelp == nil)
        #expect(model.caption(for: model.rows[0]) == "Helvetica Neue Bold (default)")
        model.beginPicking(.substitute)
        #expect(model.picking == nil, "nothing selected")
        model.toggle(gone)
        model.beginPicking(.substitute)
        #expect(model.picking == .substitute && model.families == ["Georgia", "Helvetica Neue"] && model.styles.isEmpty)
        model.commitPicking()
        #expect(model.picking == .substitute, "no family chosen yet")
        model.pickerFamily = "Georgia"
        model.pickerStyle = "Italic"
        #expect(model.styles == ["Italic", "Regular"])
        model.commitPicking()
        #expect(model.picking == nil && model.rows[0].choice == .substitute(FaceName(family: "Georgia", style: "Italic"), remember: true))
        #expect(model.caption(for: model.rows[0]) == "Georgia Italic (remembered)")
        // Lost: substituted for this document only.
        model.toggle(gone)
        model.toggle(lost)
        model.remember = false
        model.substitute(with: FaceName(family: "Courier"))
        #expect(model.caption(for: model.rows[1]) == "Courier")
        // Team: replaced.
        model.toggle(lost)
        model.toggle(team)
        model.beginPicking(.replace)
        model.pickerFamily = "Georgia"
        model.commitPicking()
        #expect(model.caption(for: model.rows[2]) == "Replace with Georgia")
        model.beginPicking(.substitute)
        model.cancelPicking()
        #expect(model.picking == nil)
        #expect(model.decision == MissingFontsDecision(
            documentRows: [FontSubstitution(missing: lost, substitute: FaceName(family: "Courier"))],
            rememberedRows: [FontSubstitution(missing: gone, substitute: FaceName(family: "Georgia", style: "Italic"))],
            replacements: [ReplaceFonts.Replacement(old: team, new: FaceName(family: "Georgia"))]))
        // Keep original name off: a substitute (or the default one) is a replacement.
        model.setKeepOriginalName(false, for: lost)
        model.setKeepOriginalName(false, for: FaceName(family: "Nobody"))
        #expect(model.decision.replacements.contains(ReplaceFonts.Replacement(old: lost, new: FaceName(family: "Courier"))))
        model.selectAll()
        #expect(model.selected == [gone, lost, team])
        let plain = MissingFontsModel(faces: [lost], defaultSubstitute: FaceName(family: "Helvetica Neue"), catalog: FakeFontCatalog())
        #expect(plain.decision == MissingFontsDecision())
        plain.setKeepOriginalName(false, for: lost)
        #expect(plain.decision.replacements == [ReplaceFonts.Replacement(old: lost, new: FaceName(family: "Helvetica Neue"))])
    }

    @Test func fetchingFromTheTeamLibraryActivatesAndDropsRows() async throws {
        let family = FontDocuments.missing("Team")
        let url = FontDocuments.fontFile(family)
        defer { FontManager.shared.deactivate(fontsAt: url) }
        let face = FaceName(family: family), other = FaceName(family: "Other")
        let library = FakeTeamFonts()
        library.files = [family: [url]]
        let online = TeamFonts(isOnline: true, families: [family]) { try await library.files(forFamily: $0, team: "t") }
        let model = MissingFontsModel(faces: [face, other], defaultSubstitute: FaceName(family: "Helvetica Neue"), catalog: FakeFontCatalog(), team: online)
        var repainted = 0
        model.didActivate = { repainted += 1 }
        model.toggle(face)
        #expect(model.rows.first { $0.face == face }?.inTeamLibrary == true && model.canFetch && model.fetchHelp == nil)
        await model.fetch()
        #expect(model.rows.map(\.face) == [other] && model.selected.isEmpty && repainted == 1 && model.fetchError == nil)
        #expect(FontManager.shared.isAvailable(family))
        #expect(!model.canFetch, "nothing left in the library")
        await model.fetch()

        // A family that cannot be fetched stays, with the reason.
        library.files = [:]
        let failing = MissingFontsModel(faces: [FaceName(family: family)], defaultSubstitute: FaceName(family: "Helvetica Neue"), catalog: FakeFontCatalog(), team: online)
        await failing.fetch()
        #expect(failing.rows.count == 1 && failing.fetchError?.contains(family) == true && repainted == 1)
        // Offline: greyed and explained.
        let offline = MissingFontsModel(faces: [face], defaultSubstitute: FaceName(family: "Helvetica Neue"), catalog: FakeFontCatalog(),
                                        team: TeamFonts(isOnline: false, families: [family]) { _ in [] })
        #expect(!offline.canFetch && offline.fetchHelp == MissingFontsModel.offlineHelp)
    }

    @Test func theSheetViewRendersAndItsButtonsAct() async {
        let gone = FaceName(family: "Gone")
        let model = MissingFontsModel(faces: [gone, FaceName(family: "Team")], defaultSubstitute: FaceName(family: "Helvetica Neue"), catalog: FakeFontCatalog(),
                                      team: TeamFonts(isOnline: false, families: ["Team"]) { _ in [] })
        var finished: [Bool] = []
        let sheet = MissingFontsSheet(model: model) { finished.append($0) }
        ColorPanelFixture.render(sheet, width: 620, height: 400)
        MissingFontsSheet.action(model.selectAll)()
        MissingFontsSheet.selects(model, gone).wrappedValue = false
        #expect(!MissingFontsSheet.selects(model, gone).wrappedValue && model.selected.count == 1)
        MissingFontsSheet.keepsName(model, gone).wrappedValue = false
        #expect(!MissingFontsSheet.keepsName(model, gone).wrappedValue && MissingFontsSheet.keepsName(model, FaceName(family: "None")).wrappedValue)
        model.beginPicking(.replace)
        model.pickerFamily = "Georgia"
        ColorPanelFixture.render(sheet, width: 620, height: 400)
        ColorPanelFixture.render(FontPickerView(model: model))
        MissingFontsSheet.fetching(model)()
        MissingFontsSheet.finishing({ finished.append($0) }, open: false)()
        MissingFontsSheet.finishing({ finished.append($0) }, open: true)()
        #expect(finished == [false, true])
        model.cancelPicking()
        model.beginSubstitute()
        #expect(model.picking == .substitute)
        model.beginReplace()
        #expect(model.picking == .replace)
    }

    // MARK: Opening documents

    @Test func openingAsksAboutMissingFacesAndOpenWritesOneReplacement() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let fonts = DocumentFonts(preferences: world.environment.preferences)
        var presented: [NSWindow] = []
        var closed = 0
        fonts.present = { sheet, _ in presented.append(sheet) }
        fonts.closeDocument = { _ in closed += 1 }
        await world.document.settle()
        #expect(await fonts.documentDidOpen(world.window) == nil, "no text, nothing to ask")
        let missing = FontDocuments.missing()
        await FontDocuments.text(world.document, [missing, "Helvetica-Bold"])
        let model = try #require(await fonts.documentDidOpen(world.window))
        #expect(presented.last?.identifier?.rawValue == "missing-fonts" && fonts.sheets[world.document.id] != nil)
        #expect(model.rows.map(\.face) == [FaceName(family: missing)] && fonts.index(for: world.document.id) != nil)
        model.selectAll()
        model.replace(with: FaceName(family: "Georgia"))
        // The sheet's btn:[Open].
        let hosting = try #require(presented.last?.contentViewController as? NSHostingController<MissingFontsSheet>)
        hosting.rootView.finish(true)
        #expect(await eventually { world.document.undoTitle == "Undo Replace font \(missing) with Georgia" })
        #expect(closed == 0 && fonts.sheets.isEmpty)
        await fonts.finish(world.window, open: true)
        #expect(DocumentFontIndex.namedFaces(in: world.state).contains(FaceName(family: "Georgia")))
        #expect(fonts.index(for: world.document.id)?.allFaces.contains(FaceName(family: "Georgia")) == true, "the index follows the change")
        #expect(await fonts.documentDidOpen(world.window) == nil, "nothing missing now")
    }

    @Test func rememberedAndDocumentSubstitutionsStopTheSheetAndCancelWritesNothing() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let fonts = DocumentFonts(preferences: world.environment.preferences)
        fonts.present = { _, _ in }
        var closed = 0
        fonts.closeDocument = { _ in closed += 1 }
        await world.document.settle()
        let remembered = FontDocuments.missing(), local = FontDocuments.missing()
        await FontDocuments.text(world.document, [remembered, local])
        let undo = world.document.undoTitle
        let model = try #require(await fonts.documentDidOpen(world.window))
        model.toggle(FaceName(family: remembered))
        model.substitute(with: FaceName(family: "Georgia"))
        model.toggle(FaceName(family: remembered))
        model.toggle(FaceName(family: local))
        model.remember = false
        model.substitute(with: FaceName(family: "Courier"))
        // Cancel: the substitutions are kept (they cost nothing), the document is closed unwritten.
        await fonts.finish(world.window, open: false)
        #expect(closed == 1 && world.document.undoTitle == undo)
        #expect(FontSubstitutionRows.table(world.environment.preferences).rows.map(\.missing) == [FaceName(family: remembered)])
        let manager = try #require(fonts.index(for: world.document.id)?.manager)
        #expect(manager.documentSubstitutions.map(\.missing) == [FaceName(family: local)])
        #expect(manager.resolve(FaceName(family: remembered)).source == .substitution)
        // Opening again asks nothing: every face has a row.
        #expect(await fonts.documentDidOpen(world.window) == nil)
        #expect(await fonts.substitutions.rows(for: world.document).map(\.missing) == [FaceName(family: local)])
        // A preference change reaches the open documents' managers and the shared one.
        _ = world.environment.preferences.set("Courier", for: PreferenceCatalog.Text.defaultSubstitute)
        #expect(fonts.index(for: world.document.id)?.substitutions.defaultSubstitute == FaceName(family: "Courier"))
        #expect(FontManager.shared.substitutions.defaultSubstitute == FaceName(family: "Courier"))
        _ = world.environment.preferences.set("Helvetica Neue", for: PreferenceCatalog.Text.defaultSubstitute)
        _ = world.environment.preferences.set(12, for: PreferenceCatalog.Sync.keepBothOffset)
        fonts.documentDidClose(world.document)
        #expect(fonts.index(for: world.document.id) == nil)
        _ = world.environment.preferences.set([String](), for: PreferenceCatalog.Text.fontSubstitutions)
    }

    @Test func embeddedFontsActivateOnOpenAndDeactivateWhenTheLastDocumentCloses() async throws {
        let family = FontDocuments.missing("Embedded")
        let url = FontDocuments.fontFile(family)
        let first = ImportWorld(), second = ImportWorld()
        defer {
            first.close()
            second.close()
        }
        let fonts = DocumentFonts(preferences: first.environment.preferences)
        fonts.present = { _, _ in }
        let relayouts = Relayouts(first.document)
        fonts.blobFile = { $0 == String(repeating: "07", count: 32) ? url : nil }
        for world in [first, second] {
            await world.document.settle()
            await FontDocuments.text(world.document, [family])
            await FontDocuments.asset(world.document, byte: 7, mediaType: "font/ttf")
            await FontDocuments.asset(world.document, byte: 8, mediaType: "font/otf")
            #expect(await fonts.documentDidOpen(world.window) == nil, "the embedded font answers")
        }
        // Once with the document's own engine when it opens, once more when its font arrives.
        #expect(FontManager.shared.isAvailable(family) && relayouts.count == 2, "the first document's text is laid out again")
        #expect(fonts.index(for: first.document.id)?.manager.resolve(FaceName(family: family)).source == .embedded)
        fonts.documentDidClose(first.document)
        #expect(FontManager.shared.isAvailable(family), "the second document still embeds it")
        fonts.documentDidClose(second.document)
        #expect(!FontManager.shared.isAvailable(family))
        // A file that is not a font is skipped.
        let junk = FontFixture.directory().appending(path: "junk.ttf")
        try Data("junk".utf8).write(to: junk)
        fonts.blobFile = { _ in junk }
        fonts.activateEmbedded([EmbeddedFont(sha256: "aa", mediaType: "font/ttf")], for: "x")
        fonts.documentDidClose(DocumentHandle.memory(title: "x"))
        #expect(DocumentFonts(preferences: first.environment.preferences).blobFile(String(repeating: "ee", count: 32)) == nil)
    }

    @Test func teamLibraryFontsAreFetchedSilentlyAndOfflineOnesAreListed() async throws {
        let family = FontDocuments.missing("Library"), absent = FontDocuments.missing("Absent"), broken = FontDocuments.missing("Broken")
        let url = FontDocuments.fontFile(family)
        let junk = FontFixture.directory().appending(path: "junk.ttf")
        try Data("junk".utf8).write(to: junk)
        defer { FontManager.shared.deactivate(fontsAt: url) }
        let world = ImportWorld()
        defer { world.close() }
        let fonts = DocumentFonts(preferences: world.environment.preferences)
        fonts.present = { _, _ in }
        let relayouts = Relayouts(world.document)
        let team = FakeTeamFonts()
        team.teams = [world.document.id: "team-1"]
        team.catalog = [family, broken]
        fonts.team = team
        await world.document.settle()
        await FontDocuments.text(world.document, [family, absent, broken])
        // Offline and not cached: the library's face is listed beside the absent one, greyed.
        team.isOnline = false
        let offline = try #require(await fonts.documentDidOpen(world.window))
        #expect(Set(offline.rows.map(\.face.family)) == [family, absent, broken] && !offline.canFetch && offline.fetchHelp != nil)
        // Opening lays the text out with the document's own engine; no font changed.
        #expect(Set(offline.rows.filter(\.inTeamLibrary).map(\.face.family)) == [family, broken] && relayouts.count == 1)
        #expect(Set(team.fetched) == [family, broken])
        fonts.documentDidClose(world.document)
        // Online (or cached): the library's font is activated silently; the absent one asks.
        team.isOnline = true
        team.files = [family: [url], broken: [junk]]
        let online = try #require(await fonts.documentDidOpen(world.window))
        #expect(online.rows.map(\.face.family).sorted() == [absent, broken].sorted() && relayouts.count == 3 && FontManager.shared.isAvailable(family))
        #expect(try await online.team?.fetch(family) == [url])
        online.didActivate()
        #expect(relayouts.count == 3, "nothing resolves differently")
        await fonts.finish(world.window, open: true)
    }

    @Test func documentRowsAreKeptInTheLocalStoreAndAFailedOpenAsksNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WireTunerFonts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let open = DocumentOpener.localStore(undoLevels: { 7 }) { id in directory.appending(components: id, "store.sqlite") }
        let document = DocumentHandle(id: "stored-fonts", title: "Stored") { try await open("stored-fonts") }
        await document.settle()
        let row = FontSubstitution(missing: FaceName(family: "Gone"), substitute: FaceName(family: "Georgia"))
        await DocumentSubstitutionStore().setRows([row], for: document)
        #expect(await DocumentSubstitutionStore().rows(for: document) == [row], "read back from the store, not memory")
        document.close()

        // A document whose model cannot open.
        let environment = TestEnvironment()
        defer { environment.suite.remove() }
        var failing = environment.document
        failing.openModel = { _ in throw CocoaError(.fileReadCorruptFile) }
        let window = DocumentController(environment: failing).newDocument(show: false)
        let fonts = DocumentFonts(preferences: environment.preferences)
        #expect(await fonts.documentDidOpen(window) == nil && fonts.index(for: window.documentHandle.id) == nil)
        // The default blob lookup finds a cached file.
        let cache = BlobCache(directory: try BlobCache.defaultDirectory())
        let hash = String(repeating: "5a", count: 32)
        try FileManager.default.createDirectory(at: cache.url(for: hash).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.url(for: hash))
        defer { try? FileManager.default.removeItem(at: cache.url(for: hash)) }
        #expect(fonts.blobFile(hash) == cache.url(for: hash))
    }

    @Test func theConnectionReadsTheDocumentsTeamAndTheClient() async throws {
        let root = FontFixture.directory()
        let store = LibraryCacheStore(url: root.appending(path: "Library.json"))
        var file = LibraryCacheFile()
        file.teams = [LibrarySpace(id: "team-1", name: "Team", kind: .team)]
        file.documents = ["team-doc": LibraryDocument(id: "team-doc", spaceID: "team-1", name: "A"), "own": LibraryDocument(id: "own", spaceID: "me", name: "B")]
        try store.save(file)
        let library = LibraryModel(services: FakeLibraryServer().services(), store: store, thumbnails: ThumbnailCache(directory: nil))
        let suite = TestDefaults()
        defer { suite.remove() }
        let environment = LaunchEnvironment(arguments: [], environment: [:])
        let account = environment.makeAccountModel(infoDictionary: ["WTAPIURL": "http://localhost:9"], defaults: suite.defaults)
        let client = try #require(environment.makeFontLibraryClient(account: account, infoDictionary: ["WTAPIURL": "http://localhost:9"], defaults: suite.defaults))
        #expect(LaunchEnvironment(arguments: [LaunchEnvironment.uiTestingArgument], environment: [:])
            .makeFontLibraryClient(account: account, infoDictionary: nil, defaults: suite.defaults) == nil)
        let connection = TeamFontLibraryConnection(client: client, library: library, account: account)
        #expect(connection.team(of: "team-doc") == "team-1" && connection.team(of: "own") == nil && connection.team(of: "unknown") == nil)
        #expect(connection.isOnline == (library.isOnline && account.isSignedIn))
        // Nothing listens on port 9: the catalog is the (empty) cached one, and no family has files.
        #expect(await connection.families(team: "team-1").isEmpty)
        #expect(try await connection.files(forFamily: "Any", team: "team-1").isEmpty)
    }
}
