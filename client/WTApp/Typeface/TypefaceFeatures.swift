import AppKit
import Foundation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto

/// The typeface features (the FONT epic's client-ui tasks; typeface-documents.adoc and the pages
/// it links): menu:File[New Typeface…], menu:File[Open Font…], menu:File[Convert Document To],
/// menu:File[Generate Fonts…], menu:File[Export UFO…], menu:File[Import UFO into Typeface…], the Font and Glyph
/// menus, menu:Window[Features] (the Features editor) and menu:Edit[Insert Class from Suffix…], the typeface window
/// layout on every document window (`TypefaceWindowMode`) and the glyph tabs.  One object per app; the commands
/// act on the front window.
@MainActor
final class TypefaceFeatures {
    enum ID {
        static let newTypeface: CommandID = "file.newTypeface"
        static let openFont: CommandID = "file.openFont"
        static let convertSingle: CommandID = "file.convertTo.singlePage"
        static let convertMulti: CommandID = "file.convertTo.multiPage"
        static let convertTypeface: CommandID = "file.convertTo.typeface"
        static let generateFonts: CommandID = "file.generateFonts"
        static let installForTesting: CommandID = "file.installForTesting"
        static let exportUFO: CommandID = "file.exportUFO"
        static let importUFO: CommandID = "file.importUFO"
        static let featuresWindow: CommandID = "window.features"
        static let insertClassFromSuffix: CommandID = "edit.insertClassFromSuffix"
        static let renameGlyph: CommandID = "glyph.rename"
        static let fontInfo: CommandID = "font.info"
        static let metricsWindow: CommandID = "font.metrics"
        static let openGlyph: CommandID = "glyph.open"
        static let addGlyph: CommandID = "glyph.add"
        static let removeGlyphs: CommandID = "glyph.remove"
        static let previousGlyph: CommandID = "glyph.previous"
        static let nextGlyph: CommandID = "glyph.next"
        static let convertPageToGlyph: CommandID = "glyph.convertPage"
        static let copyGlyphToPage: CommandID = "glyph.copyToPage"
        static let glyphParts: CommandID = "glyph.parts"
        static let fitGlyph: CommandID = "view.fitGlyph"
    }

    enum Menu {
        static let font = "Font"
        static let glyph = "Glyph"
        static let convert = "Convert Document To"
    }

    static let noDocument = "No document is open"
    static let notTypeface = "The document is not a typeface"
    static let noGlyph = "Select a glyph"
    static let noGlyphCanvas = "Open a glyph first"
    static let noFeaturesEditor = "Open the Features editor first"
    static let notUFO = "The folder is not a UFO package this version can read."

    let preferences: PreferenceStore
    /// The front document window.
    private(set) var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The open documents (glyph tabs open through it).
    private(set) weak var documents: DocumentController?
    /// A new, empty document titled with the argument (the library's *New*).
    var createDocument: @MainActor (String) -> DocumentHandle? = { _ in nil }
    /// Where *Install for Testing* keeps its fonts.
    var installer = TestFontInstaller(directory: TypefaceFeatures.testFontsDirectory())
    /// The fonts *Install for Testing* registered, by document id.
    private(set) var installed: [String: [URL]] = [:]
    /// menu:View[Show Mark Attachment] (FONT-013): on for every glyph tab.
    var showsMarkAttachment = false
    /// Where menu:Edit[Copy] in the grid puts glyphs, and Paste reads them (replaced in tests).
    var glyphPasteboard: NSPasteboard = .general
    /// menu:View[Encoding] (FONT-010): the character sets every grid shows the empty slots of.
    var encodings: Set<GlyphEncoding> = [] {
        didSet { applyEncodings() }
    }
    /// What the Object panel's glyph sections follow besides the document.
    let glyphPanelState = GlyphPanelState()
    /// Every window's typeface layout.
    private(set) var modes: [ObjectIdentifier: TypefaceWindowMode] = [:]
    /// Each document's glyph cell images.
    private var thumbnails: [String: GlyphThumbnailSource] = [:]
    /// The Metrics windows by document id.
    private(set) var metrics: [String: MetricsWindowController] = [:]
    /// The Features editors by document id.
    private(set) var featureEditors: [String: FeaturesEditorController] = [:]
    /// The Features editor in the key window (replaced in tests).
    var frontEditor: @MainActor () -> FeaturesEditorController? = { NSApp.keyWindow?.windowController as? FeaturesEditorController }
    /// Runs an open panel for font files and UFO packages (replaced in tests).
    var chooseFontFile: @MainActor (NSWindow?) async -> URL? = { window in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FontImportController.contentTypes + [FontImportController.ufoType]
        panel.canChooseDirectories = true
        return await ModalUI.urls(panel, on: window).first
    }
    /// Runs an open panel for a UFO package (replaced in tests).
    var chooseUFO: @MainActor (NSWindow?) async -> URL? = { window in
        let panel = NSOpenPanel()
        panel.title = "Import UFO into Typeface"
        panel.allowedContentTypes = [FontImportController.ufoType]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return await ModalUI.urls(panel, on: window).first
    }
    /// Shows a message (replaced in tests).
    var alert: @MainActor (String, String, NSWindow?) -> Void = { message, detail, window in ModalUI.alert(message, detail, on: window) }

    init(preferences: PreferenceStore) {
        self.preferences = preferences
    }

    /// `~/Library/Application Support/WireTuner/TestFonts` (font-export.adoc, "Install for testing").
    static func testFontsDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "WireTuner/TestFonts")
    }

    func install(commands: CommandRegistry, documents: DocumentController?, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        self.documents = documents
        for command in self.commands() + glyphMenuCommands() + glyphClipboardCommands() + glyphPanelCommands() { commands.replace(command) }
        registerGlyphPanel()
    }

    // MARK: Windows

    /// Gives `controller` the typeface layout (every document window gets one; it shows only for
    /// a typeface document or a glyph tab).
    @discardableResult
    func attach(_ controller: DocumentWindowController) -> TypefaceWindowMode {
        let key = ObjectIdentifier(controller)
        if let existing = modes[key] { return existing }
        let mode = TypefaceWindowMode(controller: controller, features: self)
        modes[key] = mode
        return mode
    }

    /// Forgets `controller`'s layout (its window closed).
    func detach(_ controller: DocumentWindowController) {
        modes[ObjectIdentifier(controller)] = nil
    }

    func mode(of controller: DocumentWindowController?) -> TypefaceWindowMode? {
        controller.flatMap { modes[ObjectIdentifier($0)] }
    }

    /// The window showing the handle `id` (a document's grid window, or a glyph tab).
    func gridWindow(of id: String) -> DocumentWindowController? {
        documents?.windowControllers[id] ?? modes.values.map(\.controller).first { $0.documentHandle.id == id }
    }

    /// The glyph cell images of `document`, shared by its windows.
    func thumbnails(for document: DocumentHandle) -> GlyphThumbnailSource {
        let id = GlyphCanvas.documentID(ofTab: document.id)
        if let existing = thumbnails[id] { return existing }
        let source = GlyphThumbnailSource()
        thumbnails[id] = source
        return source
    }

    /// Opens `glyph` of the document `source` shows in a tab of `source`'s window (or brings its
    /// tab forward); nil when the glyph is not live.
    @discardableResult
    func openGlyph(_ glyph: OpID, from source: DocumentWindowController) -> DocumentWindowController? {
        let parent = gridWindow(of: GlyphCanvas.documentID(ofTab: source.documentHandle.id)) ?? source
        let document = parent.documentHandle
        guard let read = GlyphIndex(document.state)[glyph] else { return nil }
        if let existing = gridWindow(of: GlyphCanvas.tabID(document: document.id, glyph: glyph)) {
            existing.showWindow(nil)
            return existing
        }
        let handle = GlyphCanvas.handle(for: read, of: document)
        let controller: DocumentWindowController
        if let documents {
            controller = documents.open(handle, placement: .with(source.window!))
        } else {
            controller = DocumentWindowController(document: handle, environment: glyphEnvironment(parent.environment, parent: parent))
            attach(controller)
            source.window!.addTabbedWindow(controller.window!, ordered: .above)
        }
        controller.isPrimaryView = false
        mode(of: controller)?.fitGlyph()
        return controller
    }

    /// The environment a glyph tab of `parent`'s document is made with: the document's sync
    /// session and presence, no close hook of its own.
    func glyphEnvironment(_ environment: DocumentEnvironment, parent: DocumentWindowController?) -> DocumentEnvironment {
        var environment = environment
        guard let parent else { return environment }
        let session = parent.session
        let presence = parent.presence
        let status = parent.syncStatus
        environment.session = { _ in session }
        environment.makePresence = { _ in presence }
        environment.makeSyncStatus = { _ in status }
        environment.documentDidClose = Self.keepOpen
        return environment
    }

    /// A glyph tab's close hook: the model stays with its document.
    static func keepOpen(_ document: DocumentHandle) {}

    /// The document window factory with the typeface layout added: glyph tabs share their
    /// document's session.
    func windowFactory(base: @escaping @MainActor (DocumentHandle, DocumentEnvironment, ToolID, DocumentWindowState?) -> DocumentWindowController)
        -> @MainActor (DocumentHandle, DocumentEnvironment, ToolID, DocumentWindowState?) -> DocumentWindowController {
        { [unowned self] document, environment, tool, state in
            var environment = environment
            if document.canvasNode != nil {
                environment = glyphEnvironment(environment, parent: gridWindow(of: GlyphCanvas.documentID(ofTab: document.id)))
            }
            let controller = base(document, environment, tool, state)
            attach(controller)
            return controller
        }
    }

    // MARK: Commands

    func commands() -> [Command] {
        let file = StandardCommands.Menu.file
        let window = self.window
        let needsTypeface: @MainActor @Sendable () -> CommandValidation = {
            guard let controller = window() else { return .disabled(Self.noDocument) }
            return DocumentKind(controller.documentHandle.state) == .typeface ? .enabled : .disabled(Self.notTypeface)
        }
        let needsGlyphs: @MainActor @Sendable () -> CommandValidation = { [unowned self] in
            guard let controller = window() else { return .disabled(Self.noDocument) }
            guard DocumentKind(controller.documentHandle.state) == .typeface else { return .disabled(Self.notTypeface) }
            return targetGlyphs(in: controller).isEmpty ? .disabled(Self.noGlyph) : .enabled
        }
        let needsGlyphCanvas: @MainActor @Sendable () -> CommandValidation = {
            window()?.documentHandle.glyphCanvasNode == nil ? .disabled(Self.noGlyphCanvas) : .enabled
        }
        func convert(_ kind: DocumentKind) -> @MainActor @Sendable () -> CommandValidation {
            {
                guard let controller = window() else { return .disabled(Self.noDocument) }
                return .checked(DocumentKind(controller.documentHandle.state) == kind)
            }
        }
        let fontMenu = Menu.font, glyphMenu = Menu.glyph
        return [
            Command(id: ID.newTypeface, title: "New Typeface…", key: KeyEquivalent("n", [.command, .option]), menu: MenuPath(file),
                    keywords: ["font", "typeface", "glyphs"], action: .perform { [unowned self] in presentNewTypeface() }),
            Command(id: ID.openFont, title: "Open Font…", menu: MenuPath(file), keywords: ["otf", "ttf", "woff", "import font"],
                    action: .perform { [unowned self] in openFontFile() }),
            Command(id: ID.convertSingle, title: DocumentKind.singlePage.title, menu: MenuPath(file, Menu.convert, section: 1), keywords: ["convert", "kind"],
                    validation: convert(.singlePage), action: .perform { [unowned self] in presentConvert(to: .singlePage) }),
            Command(id: ID.convertMulti, title: DocumentKind.multiPage.title, menu: MenuPath(file, Menu.convert, section: 1), keywords: ["convert", "kind"],
                    validation: convert(.multiPage), action: .perform { [unowned self] in presentConvert(to: .multiPage) }),
            Command(id: ID.convertTypeface, title: DocumentKind.typeface.title, menu: MenuPath(file, Menu.convert, section: 1), keywords: ["convert", "kind", "font"],
                    validation: convert(.typeface), action: .perform { [unowned self] in presentConvert(to: .typeface) }),
            Command(id: ID.generateFonts, title: "Generate Fonts…", menu: MenuPath(file, section: 2), keywords: ["otf", "ttf", "woff2", "export font"],
                    validation: needsTypeface, action: .perform { [unowned self] in presentGenerate() }),
            Command(id: ID.installForTesting, title: "Install for Testing", menu: MenuPath(file, section: 2), keywords: ["font", "test", "install"],
                    validation: needsTypeface, action: .perform { [unowned self] in installForTesting() }),
            Command(id: ID.exportUFO, title: "Export UFO…", menu: MenuPath(file, section: 2), keywords: ["ufo", "export font", "font source"],
                    validation: needsTypeface, action: .perform { [unowned self] in presentExportUFO() }),
            Command(id: ID.importUFO, title: "Import UFO into Typeface…", menu: MenuPath(file, section: 2), keywords: ["ufo", "import font", "font source"],
                    validation: needsTypeface, action: .perform { [unowned self] in importUFOIntoTypeface() }),
            Command(id: ID.featuresWindow, title: "Features", menu: MenuPath(StandardCommands.Menu.window), keywords: ["opentype", "fea", "feature file", "liga"],
                    validation: needsTypeface, action: .perform { [unowned self] in showFeatures() }),
            Command(id: ID.insertClassFromSuffix, title: "Insert Class from Suffix…", menu: MenuPath(StandardCommands.Menu.edit), keywords: ["feature", "class", "suffix"],
                    validation: { [unowned self] in frontEditor() == nil ? .disabled(Self.noFeaturesEditor) : .enabled },
                    action: .perform { [unowned self] in if let editor = frontEditor() { presentClassFromSuffix(on: editor) } }),
            Command(id: ID.fontInfo, title: "Font Info…", menu: MenuPath(fontMenu), keywords: ["names", "metrics", "units per em", "os/2"],
                    validation: needsTypeface, action: .perform { [unowned self] in presentFontInfo() }),
            Command(id: ID.metricsWindow, title: "Metrics Window", key: KeyEquivalent("m", [.command, .option]), menu: MenuPath(fontMenu),
                    keywords: ["kerning", "spacing"], validation: needsTypeface, action: .perform { [unowned self] in showMetrics() }),
            Command(id: ID.openGlyph, title: "Open Glyph", menu: MenuPath(glyphMenu), keywords: ["edit glyph"],
                    validation: needsGlyphs, action: .perform { [unowned self] in openSelectedGlyphs() }),
            Command(id: ID.addGlyph, title: "Add Glyph…", menu: MenuPath(glyphMenu), keywords: ["new glyph", "character"],
                    validation: needsTypeface, action: .perform { [unowned self] in presentAddGlyph() }),
            Command(id: ID.removeGlyphs, title: "Remove Glyph", menu: MenuPath(glyphMenu), keywords: ["delete glyph"],
                    validation: needsGlyphs, action: .perform { [unowned self] in removeSelectedGlyphs() }),
            Command(id: ID.renameGlyph, title: "Rename Glyph…", menu: MenuPath(glyphMenu), keywords: ["glyph name", "feature file"],
                    validation: needsGlyphs, action: .perform { [unowned self] in presentRenameGlyph() }),
            Command(id: ID.previousGlyph, title: "Previous Glyph", key: KeyEquivalent("left", [.command, .option]), menu: MenuPath(glyphMenu, section: 1),
                    validation: needsGlyphCanvas, action: .perform { [unowned self] in stepGlyph(by: -1) }),
            Command(id: ID.nextGlyph, title: "Next Glyph", key: KeyEquivalent("right", [.command, .option]), menu: MenuPath(glyphMenu, section: 1),
                    validation: needsGlyphCanvas, action: .perform { [unowned self] in stepGlyph(by: 1) }),
            Command(id: ID.glyphParts, title: "Components and Anchors…", menu: MenuPath(glyphMenu, section: 1), keywords: ["component", "anchor", "decompose"],
                    validation: needsGlyphCanvas, action: .perform { [unowned self] in presentGlyphParts() }),
            Command(id: ID.convertPageToGlyph, title: "Convert Page to Glyph…", menu: MenuPath(glyphMenu, section: 2), keywords: ["sketch", "page"],
                    validation: needsTypeface, action: .perform { [unowned self] in presentConvertPage() }),
            Command(id: ID.copyGlyphToPage, title: "Copy Glyph to Page", menu: MenuPath(glyphMenu, section: 2), keywords: ["sketch", "page"],
                    validation: needsGlyphs, action: .perform { [unowned self] in copySelectedGlyphsToPages() }),
            Command(id: ID.fitGlyph, title: "Fit Glyph", menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewZoom),
                    keywords: ["zoom", "glyph"], validation: needsGlyphCanvas, action: .perform { [unowned self] in mode(of: window())?.fitGlyph() }),
        ]
    }

    /// The glyphs a Glyph menu command acts on: a glyph tab's glyph, else the grid's selection.
    func targetGlyphs(in controller: DocumentWindowController) -> [OpID] {
        if let glyph = controller.documentHandle.glyphCanvasNode { return [glyph] }
        return mode(of: controller)?.grid?.model.selection ?? []
    }

    // MARK: Actions

    /// menu:File[New Typeface…]: the sheet on the front window, or a window of its own when no
    /// document is open.
    @discardableResult
    func presentNewTypeface() -> NSWindow {
        let model = NewTypefaceModel(create: createTypefaceFromSheet)
        return present("sheet.newTypeface", on: window()?.window) { close in NewTypefaceSheet(model: model, close: close) }
    }

    /// The New Typeface sheet's btn:[Create].
    func createTypefaceFromSheet(_ choice: NewTypefaceModel.Choice) {
        createTypeface(choice)
    }

    /// Creates the document the New Typeface sheet described.  *From a font file…* asks for the
    /// file and imports it into the new document.
    @discardableResult
    func createTypeface(_ choice: NewTypefaceModel.Choice) -> Task<DocumentHandle?, Never> {
        let title = choice.family.isEmpty ? "Untitled Typeface" : "\(choice.family) \(choice.style)".trimmingCharacters(in: .whitespaces)
        guard let document = createDocument(title) else { return Task { nil } }
        let fromFile = choice.set == .fromFile
        let command = NewTypeface(family: choice.family, style: choice.style, upm: choice.upm, set: choice.set.glyphSet)
        let perform = document.perform(command)
        return Task { [weak self] in
            _ = await perform.value
            if fromFile, let self, let url = await chooseFontFile(gridWindow(of: document.id)?.window) {
                _ = await FontImportController(document: document).importFile(url, newDocument: true)?.value
            }
            return document
        }
    }

    /// menu:File[Open Font…]: an OTF, TTF or WOFF2 file, imported into the front typeface
    /// document, or into a new typeface document when the front one is not a typeface; a UFO
    /// package always opens as a new typeface document.  The import's report is shown when it has
    /// anything to say.
    @discardableResult
    func openFontFile() -> Task<[String]?, Never> {
        let front = window()
        return Task { [weak self] in
            guard let self, let url = await chooseFontFile(front?.window) else { return nil }
            if FontImportController.isUFO(url) { return await openUFO(url).value }
            let target: DocumentHandle
            let newDocument: Bool
            if let front, DocumentKind(front.documentHandle.state) == .typeface {
                target = gridDocument(of: front)
                newDocument = false
            } else {
                guard let created = createDocument(url.deletingPathExtension().lastPathComponent) else { return nil }
                target = created
                newDocument = true
            }
            guard let task = FontImportController(document: target).importFile(url, newDocument: newDocument) else {
                alert("“\(url.lastPathComponent)” could not be opened", FontImportController.unreadable, front?.window)
                return nil
            }
            let report = await task.value
            if !report.isEmpty { alert("Imported “\(url.lastPathComponent)”", report.joined(separator: "\n"), front?.window) }
            return report
        }
    }

    /// A UFO package opened (menu:File[Open Font…], or handed to the app by the Finder): a new
    /// typeface document named after the package, with everything the package holds; the report
    /// is shown when it has anything to say.  Nil when no document can be made or the package
    /// cannot be read (which an alert says).
    @discardableResult
    func openUFO(_ url: URL) -> Task<[String]?, Never> {
        let front = window()
        return Task { [weak self] in
            guard let self, let created = createDocument(url.deletingPathExtension().lastPathComponent) else { return nil }
            return await importUFO(url, into: created, newDocument: true, alertOn: front?.window)
        }
    }

    /// menu:File[Import UFO into Typeface…]: the package's glyphs added to the front typeface,
    /// colliding names and characters handled as the grid handles them and listed in the report.
    @discardableResult
    func importUFOIntoTypeface() -> Task<[String]?, Never> {
        guard let front = window(), DocumentKind(front.documentHandle.state) == .typeface else { return Task { nil } }
        let target = gridDocument(of: front)
        return Task { [weak self] in
            guard let self, let url = await chooseUFO(front.window) else { return nil }
            return await importUFO(url, into: target, newDocument: false, alertOn: front.window)
        }
    }

    private func importUFO(_ url: URL, into document: DocumentHandle, newDocument: Bool, alertOn window: NSWindow?) async -> [String]? {
        switch await FontImportController(document: document).importUFO(url, newDocument: newDocument) {
        case .failure(let error):
            alert("“\(url.lastPathComponent)” could not be opened", (error as? UFOReader.Failure)?.description ?? Self.notUFO, window)
            return nil
        case .success(let report):
            if !report.isEmpty { alert("Imported “\(url.lastPathComponent)”", report.joined(separator: "\n"), window) }
            return report
        }
    }

    /// Whether `url` is a UFO package, which then opens as a new typeface document (the app's
    /// open-file hook).
    func opens(_ url: URL) -> Bool {
        guard FontImportController.isUFO(url) else { return false }
        openUFO(url)
        return true
    }

    /// menu:Window[Features]: one Features editor per document, with the document window's
    /// collaborators and caret publishing.
    @discardableResult
    func showFeatures() -> FeaturesEditorController? {
        guard let controller = window() else { return nil }
        let document = gridDocument(of: controller)
        if let existing = featureEditors[document.id] {
            existing.show()
            return existing
        }
        let grid = gridWindow(of: document.id) ?? controller
        let editor = FeaturesEditorController(model: FeaturesEditorModel(document: document),
                                              showGenerated: preferences[PreferenceCatalog.Typeface.showGeneratedFeatures],
                                              presence: grid.presence) { [weak grid] caret in grid?.collaboration.publisher?.caret(caret) }
        editor.presentSuffixSheet = { [unowned self, unowned editor] in presentClassFromSuffix(on: editor) }
        editor.onClose = { [unowned self] in featureEditors[document.id] = nil }
        featureEditors[document.id] = editor
        editor.show()
        return editor
    }

    /// menu:Edit[Insert Class from Suffix…] in a Features editor.
    @discardableResult
    func presentClassFromSuffix(on editor: FeaturesEditorController) -> NSWindow {
        let model = ClassFromSuffixModel { [weak editor] suffix in editor?.model.insertClasses(suffix: suffix) ?? false }
        return present("sheet.classFromSuffix", on: editor.window) { close in ClassFromSuffixSheet(model: model, close: close) }
    }

    /// menu:Glyph[Rename Glyph…]: the first targeted glyph.
    @discardableResult
    func presentRenameGlyph() -> NSWindow? {
        guard let controller = window(), let glyph = targetGlyphs(in: controller).first else { return nil }
        let model = RenameGlyphModel(document: gridDocument(of: controller), glyph: glyph, perform: controller.typefacePerform)
        return present("sheet.renameGlyph", on: controller.window) { close in RenameGlyphSheet(model: model, close: close) }
    }

    /// menu:File[Convert Document To]: the sheet saying what happens.
    @discardableResult
    func presentConvert(to kind: DocumentKind) -> NSWindow? {
        guard let controller = window() else { return nil }
        let model = ConvertDocumentModel(document: gridDocument(of: controller), kind: kind, perform: controller.typefacePerform)
        return present("sheet.convertDocument", on: controller.window) { close in ConvertDocumentSheet(model: model, close: close) }
    }

    /// menu:Font[Font Info…].
    @discardableResult
    func presentFontInfo() -> NSWindow? {
        guard let controller = window() else { return nil }
        let model = FontInfoModel(document: gridDocument(of: controller))
        model.showProgress = { [weak self, weak controller] text in self?.presentProgress(text, on: controller?.window) ?? {} }
        return present("sheet.fontInfo", on: controller.window) { close in FontInfoSheet(model: model, close: close) }
    }

    /// The Generate Fonts sheet's model for `controller`'s document: a problem row opens its
    /// glyph in `controller`, installs are remembered for *Remove Test Fonts*.
    func generateModel(for controller: DocumentWindowController) -> GenerateFontsModel {
        let document = gridDocument(of: controller)
        let model = GenerateFontsModel(document: document, installer: installer)
        // Weak: the sheet (and so the model) can outlive the window and the features.
        model.openGlyph = { [weak self, weak controller] glyph in
            if let self, let controller { openGlyph(glyph, from: controller) }
        }
        model.didInstall = { [weak self] urls in self?.installed[document.id, default: []] += urls }
        model.attachSync(controller.syncStatus)
        model.removeInstalled = { [weak self] in
            guard let self else { return }
            installer.remove(installed[document.id] ?? [])
            installed[document.id] = nil
        }
        return model
    }

    /// menu:File[Generate Fonts…].
    @discardableResult
    func presentGenerate() -> NSWindow? {
        guard let controller = window() else { return nil }
        let model = generateModel(for: controller)
        return present("sheet.generateFonts", on: controller.window) { close in GenerateFontsSheet(model: model, close: model.closing(close)) }
    }

    /// menu:File[Export UFO…].
    @discardableResult
    func presentExportUFO() -> NSWindow? {
        guard let controller = window() else { return nil }
        let model = ExportUFOModel(document: gridDocument(of: controller))
        return present("sheet.exportUFO", on: controller.window) { close in ExportUFOSheet(model: model, close: close) }
    }

    /// menu:File[Install for Testing]: an OTF of the front typeface with the *Test* suffix,
    /// registered for this user; a failure says why.
    @discardableResult
    func installForTesting() -> Task<URL?, Never> {
        guard let controller = window() else { return Task { nil } }
        let model = generateModel(for: controller)
        // Weak: the features may go while the install runs (a test's features, the app quitting).
        return Task { [weak self] in
            let url = await model.installForTesting().value
            if url == nil, let self { alert("Install for Testing failed", model.message ?? "", controller.window) }
            return url
        }
    }

    /// menu:Font[Metrics Window]: one window per document.
    @discardableResult
    func showMetrics() -> MetricsWindowController? {
        guard let controller = window() else { return nil }
        let document = gridDocument(of: controller)
        let metricsWindow = metrics[document.id] ?? MetricsWindowController(document: document)
        metrics[document.id] = metricsWindow
        metricsWindow.onClose = { [weak self] in self?.metrics[document.id] = nil }
        metricsWindow.showWindow(nil)
        return metricsWindow
    }

    /// menu:Glyph[Open Glyph]: each selected glyph in its own tab.
    func openSelectedGlyphs() {
        guard let controller = window() else { return }
        for glyph in targetGlyphs(in: controller) { openGlyph(glyph, from: controller) }
    }

    /// menu:Glyph[Add Glyph…].
    @discardableResult
    func presentAddGlyph() -> NSWindow? {
        guard let controller = window() else { return nil }
        let model = AddGlyphModel(document: gridDocument(of: controller), after: targetGlyphs(in: controller).last, perform: controller.typefacePerform)
        model.openGlyph = { [weak self, weak controller] glyph in
            if let self, let controller { openGlyph(glyph, from: controller) }
        }
        return present("sheet.addGlyph", on: controller.window) { close in AddGlyphSheet(model: model, close: close) }
    }

    /// menu:Glyph[Remove Glyph]: confirmed when any of the glyphs has artwork.
    @discardableResult
    func removeSelectedGlyphs() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let controller = window() else { return nil }
        let document = gridDocument(of: controller)
        let glyphs = targetGlyphs(in: controller)
        guard !glyphs.isEmpty else { return nil }
        let state = document.state
        let drawn = glyphs.contains { !GlyphArtwork.objectIDs(on: $0, in: state).isEmpty }
        if drawn, !controller.confirm("Remove \(glyphs.count == 1 ? "this glyph" : "\(glyphs.count) glyphs") and its artwork?",
                                        "The artwork drawn on it is removed too.  You can undo this.") {
            return nil
        }
        if controller.documentHandle.glyphCanvasNode != nil { controller.window?.close() }
        return document.perform(RemoveGlyphs(glyphs, in: state))
    }

    /// Cmd+Option+Left / Right in a glyph tab: the previous or next glyph in grid order opens in
    /// place of this tab.
    @discardableResult
    func stepGlyph(by offset: Int) -> DocumentWindowController? {
        guard let controller = window(), let glyph = controller.documentHandle.glyphCanvasNode else { return nil }
        let index = GlyphIndex(controller.documentHandle.state)
        guard let position = index.glyphs.firstIndex(where: { $0.id == glyph }) else { return nil }
        let next = index.glyphs[(position + offset + index.glyphs.count) % index.glyphs.count]
        guard next.id != glyph else { return controller }
        let opened = openGlyph(next.id, from: controller)
        controller.window?.close()
        return opened
    }

    /// menu:Glyph[Components and Anchors…] in a glyph tab.
    @discardableResult
    func presentGlyphParts() -> NSWindow? {
        guard let controller = window(), let glyph = controller.documentHandle.glyphCanvasNode else { return nil }
        let model = GlyphPartsModel(document: controller.documentHandle, glyph: glyph, perform: controller.typefacePerform)
        return present("sheet.glyphParts", on: controller.window) { close in GlyphPartsSheet(model: model, close: close) }
    }

    /// menu:Glyph[Convert Page to Glyph…]: the active (Sketches) page; the glyph opens.
    @discardableResult
    func presentConvertPage() -> NSWindow? {
        guard let controller = window(), controller.documentHandle.canvasNode == nil else { return nil }
        let document = controller.documentHandle
        let model = ConvertPageModel(document: document, page: document.activePage.id) { [weak self, weak controller] command in
            if let self, let controller { convertPage(command, in: controller) }
        }
        return present("sheet.convertPage", on: controller.window) { close in ConvertPageSheet(model: model, close: close) }
    }

    /// Performs Convert Page to Glyph in `controller` and opens the glyph it made.
    @discardableResult
    func convertPage(_ command: ConvertPageToGlyph, in controller: DocumentWindowController) -> Task<Bool, Never> {
        let task = controller.objectEditing.perform(command)
        return Task { [weak self] in
            _ = await task.value
            guard let self else { return false }
            return GlyphIndex(controller.documentHandle.state).glyph(named: command.name).flatMap { openGlyph($0.id, from: controller) } != nil
        }
    }

    /// menu:Glyph[Copy Glyph to Page]: one Sketches page per glyph, one change each.
    @discardableResult
    func copySelectedGlyphsToPages() -> [Task<Wiretuner_Doc_V1_Change?, Never>] {
        guard let controller = window() else { return [] }
        let document = gridDocument(of: controller)
        return targetGlyphs(in: controller).map { document.perform(CopyGlyphToPage($0)) }
    }

    // MARK: Helpers

    /// The handle of the document `controller` shows (a glyph tab's document, not the tab's).
    func gridDocument(of controller: DocumentWindowController) -> DocumentHandle {
        gridWindow(of: GlyphCanvas.documentID(ofTab: controller.documentHandle.id))?.documentHandle ?? controller.documentHandle
    }

    /// A SwiftUI sheet on `window`, or in a window of its own when there is none.
    func present<Content: View>(_ identifier: String, on window: NSWindow?, @ViewBuilder content: (@escaping @MainActor () -> Void) -> Content) -> NSWindow {
        TypefaceSheets.present(identifier, on: window, content: content)
    }
}

extension DocumentWindowController {
    /// How the typeface sheets and the glyph bar perform: the window's object commands.  Weak: the
    /// glyph bar lives in the window's title bar, and the method reference it was (`controller.typefacePerform`)
    /// held the controller from its own window, so every closed glyph tab leaked.
    var typefacePerform: TypefacePerform {
        { [weak self] command in self?.objectEditing.perform(command) }
    }
}

extension AppDelegate {
    /// The FONT epic's commands and the typeface layout on every document window.
    func installTypeface() {
        let documents = documents!
        let library = library
        typeface.createDocument = { title in documents.document(id: library.createDocument(name: title).id) }
        typeface.install(commands: commands, documents: documents) { documents.activeWindowController }
        documents.makeWindowController = typeface.windowFactory(base: documents.makeWindowController)
    }
}
