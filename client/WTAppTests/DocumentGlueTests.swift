import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The app half of commit cbda22a: the install, the *Profiles…* sheet and the reference scan
/// (CMS-010), the *Team libraries* sections (COLLAB-015), the Photo tracer (IMG-029) and new
/// documents through `CreateDocument` (DOC-019).
@Suite(.serialized) @MainActor struct DocumentGlueTests {
    // MARK: The app

    @Test func theFeaturesAreWiredIntoTheApp() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer { window.close() }
        let glue = delegate.documentGlue
        defer { glue.profileScan.stop() }
        for id in [StandardCommands.ID.customEdit, StandardCommands.ID.customPrevious, SelectSimilarCommands.id(.fill), ContextMenuCatalog.ID.union] {
            #expect(delegate.commands.command(id)?.validation().reason != WireTuner.Command.placeholderReason, "\(id)")
        }
        #expect(delegate.toolbars.extensions.descriptor(for: "union")?.isStub == false)
        #expect(window.toolManager.handleLayers.contains { $0 is ClipContentsHandle } && window.toolManager.handleLayers.contains { $0 is ImageResolutionHandles })
        #expect(glue.notices[ObjectIdentifier(window)] != nil && glue.masters.documents === delegate.documents)
        #expect(delegate.library.makeID().count == 36)
        // The panels carry the team libraries.
        for id in ["swatches", "styles", "library"] {
            let view = try #require(delegate.panels.descriptor(for: PanelID(id))?.makeView() as? NSStackView)
            #expect(view.arrangedSubviews.count == 2)
        }
        // A named view refreshes the Custom submenu (the menu bar is rebuilt).
        _ = await window.createNamedView("Detail", from: window.viewport).value
        await window.documentHandle.settle()
        #expect(delegate.commands.command(NamedViewFeatures.id(0))?.title == "Detail")
        // The Edit button opens the master's tab through the document controller.
        let page = window.documentHandle.activePage.id
        let master = try #require(await window.documentHandle.perform(NewMasterPage(from: page)).value?.createdObjects.first)
        _ = await window.documentHandle.perform(ApplyMasterPage(master, to: [page])).value
        await window.documentHandle.settle()
        DocumentPanelModel.editMaster(window, master)
        let tab = try #require(glue.masters.tabs.values.first)
        #expect(delegate.documents.windowControllers[tab.documentHandle.id] === tab && glue.masters.documentWindow(of: tab) === window)
        #expect(tab.session === window.session, "the tab shares the document's session")
        tab.window?.close()
        #expect(glue.masters.tabs.isEmpty)
        // The Color Settings sheet's Profiles… opens the sheet once.
        let sheets = SheetPresenter()
        sheets.present = { _ in }
        let local = DocumentGlueFeatures(preferences: delegate.preferences, sheets: sheets) { [weak window] in window }
        let profiles = local.showProfiles(window.documentHandle)
        #expect(local.showProfiles(window.documentHandle) === profiles && sheets.sheets[DocumentGlueFeatures.profilesSheet] != nil)
        profiles.close()
        #expect(local.profiles == nil)
        ColorSettingsSheet.showProfiles(window.documentHandle)
        #expect(glue.profiles != nil)
        glue.profiles?.close()
        // Closing the window forgets its notices.
        glue.profileScan.timer?.fire()
        glue.detach(window)
        #expect(glue.notices[ObjectIdentifier(window)] == nil)
    }

    @Test func newDocumentsStartWithTheCreatedChange() async throws {
        let model = WTModel.Document(memory: DocumentCore(state: EngineState(), replica: 0x51))
        await DocumentOpener.applyTemplate(to: model)
        #expect(model.lastChange?.label == "Created" && !model.canUndo)
        #expect(PageList(model.state).pages.map(\.rect) == [DocumentCreation.builtInPage])
        await DocumentOpener.applyTemplate(to: model)
        #expect(PageList(model.state).pages.count == 1, "once")
    }

    // MARK: Profiles

    /// A custom profile registered in this process (Adobe RGB's ICC data).
    static func customProfile() throws -> (ref: WTColor.ProfileRef, data: Data) {
        let data = try #require(CGColorSpace(name: CGColorSpace.adobeRGB1998)?.copyICCData() as Data?)
        let ref = try #require(WTColor.ProfileRegistry.shared.register(iccData: data))
        return (ref, data)
    }

    @Test func theProfilesSheetListsExportsAndNamesWhatUsesEachProfile() async throws {
        let document = DocumentHandle.memory(title: "Profiles")
        let (ref, data) = try Self.customProfile()
        let stored = ColorSettings.stored(ref)
        _ = await document.perform(AddProfileAssets([(stored, UInt64(data.count))])).value
        let closed = TestBox(false)
        let model = ProfilesModel(document: document) { closed.value = true }
        defer { model.stop() }
        let row = try #require(model.rows.first)
        #expect(model.rows.count == 1 && row.usedBy == ProfilesModel.unused && row.space == "RGB" && !row.size.isEmpty && row.name == stored.name)
        // An image embedding it uses it.
        let image = try await HandleWorld.place(in: document)
        var embedded = Wiretuner_Doc_V1_NodeProps()
        embedded.image.color.embeddedProfile = stored
        _ = await document.perform(OpsCommand("Embed", ops: [Ops.set(image, [RegisterPath([170, 11, 4])], values: embedded)])).value
        await document.settle()
        #expect(model.rows[0].usedBy == document.state.displayName(of: image))
        // The colour settings naming it: the working space.
        var draft = ColorSettings.draft(document.state)
        draft.rgbProfile = stored
        _ = await document.perform(ChangeColorSettings(draft, profileSizes: [stored.sha256: UInt64(data.count)])).value
        await document.settle()
        #expect(model.rows[0].usedBy.hasPrefix("Working space"))
        #expect(ProfilesModel.savePanel("Adobe.icc").nameFieldStringValue == "Adobe.icc")
        #expect(ProfilesModel.title(.cmyk) == "CMYK" && ProfilesModel.title(.gray) == "Gray" && ProfilesModel.title(.lab) == "Lab")
        Render.view(ProfilesSheet(model: model))
        // Export: nothing selected, no destination, the bytes written, bytes missing, a failed write.
        #expect(await model.export() == nil)
        model.selection = row.id
        model.chooseDestination = { _ in nil }
        #expect(await model.export() == nil)
        let url = FileManager.default.temporaryDirectory.appending(path: "profile-\(UUID().uuidString).icc")
        defer { try? FileManager.default.removeItem(at: url) }
        model.chooseDestination = { _ in url }
        #expect(await model.export() == url)
        #expect(try Data(contentsOf: url) == data)
        model.chooseDestination = { _ in URL(filePath: "/nonexistent-\(UUID().uuidString)/p.icc") }
        #expect(await model.export() == nil && model.message != nil)
        model.bytes = { _ in nil }
        #expect(await model.export() == nil && model.message == ProfilesModel.unavailable)
        Render.view(ProfilesSheet(model: model))
        ProfilesSheet.export(model)()
        model.close()
        #expect(closed.value)
        var unnamed = row.entry
        unnamed.name = ""
        #expect(ProfilesModel.Row(entry: unnamed, usedBy: "").name == "Untitled profile")
    }

    @Test func theScanRemovesProfilesUnreferencedForTheRetentionWindow() async throws {
        let document = DocumentHandle.memory(title: "Scan")
        let (ref, data) = try Self.customProfile()
        _ = await document.perform(AddProfileAssets([(ColorSettings.stored(ref), UInt64(data.count))])).value
        let timer = ProfileScanTimer()
        let now = TestBox<Int64>(1_000)
        timer.now = { now.value }
        #expect(timer.scan([document]).isEmpty, "first seen unreferenced")
        now.value += EngineState.deletedNodeRetentionMs + 1
        let removed = timer.scan([document])
        await document.settle()
        #expect(removed[document.id]?.count == 1 && ProfileAssets.list(document.state).isEmpty)
        let fired = TestBox(0)
        timer.start {
            fired.value += 1
            return []
        }
        timer.timer?.fire()
        #expect(fired.value == 1)
        timer.stop()
    }

    // MARK: Team libraries

    struct Opener: LibraryStoreOpening {
        let libraries: [LibrarySource]
        var fails = false
        func cachedLibraries() async throws -> [LibrarySource] {
            if fails { throw CocoaError(.fileReadNoPermission) }
            return libraries
        }
    }

    @Test func teamLibrarySectionsCopyItemsAndTheCopiesCanBeUpdatedOrDetached() async throws {
        let library = DocumentHandle.memory(title: "Marketing")
        _ = await library.perform(AddSwatch(Color(red: 0.8, green: 0.1, blue: 0.1), name: "Brand")).value
        _ = await library.perform(AddSwatch(Color(red: 0.1, green: 0.8, blue: 0.1))).value
        let source = LibrarySource(documentID: "0190a0d4-0000-7000-8000-00000000000a", name: "Marketing", headSeq: 5, state: library.state)
        let world = GlueWorld()
        defer { world.close() }
        let model = TeamLibraryCatalogModel()
        await model.reload()
        #expect(model.sections(.swatch).isEmpty)
        Render.view(TeamLibraryCatalogSection(model: model, kind: .swatch))
        model.opener = Opener(libraries: [source], fails: true)
        await model.reload()
        #expect(model.message?.hasPrefix("The team libraries could not be read") == true)
        model.opener = Opener(libraries: [source])
        await model.reload()
        let section = try #require(model.sections(.swatch).first)
        #expect(section.name == "Marketing" && section.items.map(\.name).first == "Brand" && model.message == nil)
        let item = section.items[0]
        #expect(model.copy(item) == nil && model.message == TeamLibraryCatalogModel.noDocument, "no window")
        model.window = { [weak window = world.window] in window }
        #expect(!model.isExpanded(source.documentID).wrappedValue)
        model.isExpanded(source.documentID).wrappedValue = true
        #expect(model.expanded == [source.documentID])
        Render.view(TeamLibraryCatalogSection(model: model, kind: .swatch))
        model.isExpanded(source.documentID).wrappedValue = false
        TeamLibraryCatalogSection.copy(item, model)()
        await world.document.settle()
        model.touch()
        let copied = try #require(model.copied(.swatch).first)
        #expect(copied.name == "Brand" && copied.badge.libraryName == "Marketing" && !copied.badge.updateAvailable)
        let art = try #require(await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)]).first)
        _ = await world.document.perform(ConvertToSymbol([art.opID], name: "Badge")).value
        await world.document.settle()
        #expect(model.copied(.style).isEmpty && model.copied(.symbol).isEmpty)
        Render.view(TeamLibraryCatalogSection(model: model, kind: .swatch))
        // The library moves on: an update is available and btn:[Update] takes it.
        _ = await library.perform(AddSwatch(Color(red: 0, green: 0, blue: 1), name: "Sky")).value
        model.opener = Opener(libraries: [LibrarySource(documentID: source.documentID, name: "Marketing", headSeq: 9, state: library.state)])
        await model.reload()
        #expect(model.copied(.swatch).first?.badge.updateAvailable == true)
        model.isExpanded(source.documentID).wrappedValue = true
        Render.view(TeamLibraryCatalogSection(model: model, kind: .swatch))
        TeamLibraryCatalogSection.update(copied, model)()
        await world.document.settle()
        model.touch()
        #expect(model.copied(.swatch).first?.badge.updateAvailable == false)
        TeamLibraryCatalogSection.detach(copied, model)()
        await world.document.settle()
        model.touch()
        #expect(model.copied(.swatch).isEmpty)
        // A library that is not cached any more: no copy, no update.
        model.opener = nil
        await model.reload()
        #expect(model.copy(item) == nil && model.update(copied) == nil)
        // Only changes to the swatches, styles or symbols re-read the copies.
        let revision = model.revision
        model.documentDidChange(nil, state: world.state)
        #expect(model.revision == revision + 1)
        let drawn = await world.document.perform(MasterTabTests.square(Rect(x: 0, y: 0, width: 4, height: 4))).value
        model.documentDidChange(drawn, state: world.state)
        #expect(model.revision == revision + 1)
        let swatch = await world.document.perform(AddSwatch(Color(red: 0, green: 0, blue: 0.5), name: "Navy")).value
        model.documentDidChange(swatch, state: world.state)
        #expect(model.revision == revision + 2)
        // The panel gets the section under its body.
        let descriptor = PanelDescriptor(id: "swatches", title: "Swatches", defaultGroup: "g") { Text("Body") }
        let stack = try #require(model.adding(.swatch, to: descriptor).makeView() as? NSStackView)
        #expect(stack.arrangedSubviews.count == 2)
    }

    // MARK: Photo tracer

    /// Left half one class, right half another.
    struct Halves: Trace.ClassMapping {
        func classMap(for image: CGImage) throws -> Trace.ClassMap? {
            Trace.ClassMap(width: 2, height: 1, labels: [1, 2], names: [1: "Sky", 2: "Grass"])
        }
    }

    static func halves() throws -> Trace.Bitmap {
        var pixels: [UInt8] = []
        for _ in 0..<20 {
            for x in 0..<40 { pixels += x < 20 ? [200, 30, 30, 255] : [30, 30, 200, 255] }
        }
        return try #require(Trace.Bitmap(width: 40, height: 20, pixels: pixels))
    }

    @Test func thePhotoTracerPlacesOneGroupPerRegion() async throws {
        #expect(PhotoTrace.title(.classic) == "Classic" && PhotoTrace.title(.photo) == "Photo")
        let bitmap = try Self.halves()
        let image = try #require(PhotoTrace.image(bitmap))
        #expect(image.width == 40 && Trace.Bitmap(cgImage: image) == bitmap)
        let segmenter = PhotoTrace.segmenter, mapper = PhotoTrace.mapper
        defer {
            PhotoTrace.segmenter = segmenter
            PhotoTrace.mapper = mapper
        }
        PhotoTrace.segmenter = nil
        PhotoTrace.mapper = Halves()
        let result = try await PhotoTrace.trace(bitmap, options: Trace.Options(colors: 2), transform: .identity) { _ in }
        #expect(result.regions.map(\.name).sorted() == ["Grass", "Sky"])
        let group = PhotoTrace.group(result, name: "Trace")
        #expect(group.name == "Trace" && group.children.compactMap(\.name).sorted() == ["Grass", "Sky"])
        PhotoTrace.mapper = nil
        let single = try await PhotoTrace.trace(bitmap, options: Trace.Options(colors: 2), transform: .identity) { _ in }
        let flat = PhotoTrace.group(single, name: "Trace")
        let clear = try #require(Trace.Bitmap(width: 4, height: 4, pixels: [UInt8](repeating: 0, count: 64)))
        let nothing = try await PhotoTrace.trace(clear, options: Trace.Options(colors: 2), transform: .identity) { _ in }
        #expect(PhotoTrace.group(nothing, name: "Trace").children.isEmpty)
        #expect(single.regions.count == 1 && flat.children.allSatisfy { if case .path = $0 { true } else { false } })
        // Through the tool: the *Photo* tracer places a group.
        PhotoTrace.mapper = Halves()
        let registry = ToolRegistry()
        let environment = TestEnvironment()
        let trace = TraceFeatures(preferences: environment.preferences)
        trace.install(tools: registry)
        trace.settings.resolution = 1
        trace.settings.tracer = .photo
        #expect(TraceSettings.load(environment.preferences.defaults).tracer == .photo)
        #expect(TraceSettings().tracer == .classic)
        trace.showProgress = { _, _ in }
        let setup = SetupWindow(tools: [try #require(registry.descriptor(for: TraceTool.id))])
        defer { setup.close() }
        let page = setup.page.rect
        await setup.document.addRectangles([Rect(x: page.minX + 20, y: page.minY + 20, width: 30, height: 30)])
        let host = RecordingHost(viewport: setup.window.viewport)
        defer { withExtendedLifetime(host) {} }
        let context = ToolContext(document: setup.document, host: host, selection: setup.window.selection)
        let before = setup.document.changeCount
        await trace.trace(Rect(x: page.minX, y: page.minY, width: 80, height: 80), in: context)?.value
        #expect(await eventually { setup.document.changeCount > before })
        #expect(setup.document.undoTitle == "Undo Trace")
        let drawing = try #require(LayerOrder(setup.document.state).drawingLayer)
        let source = try #require(setup.document.state.liveChildren(drawing).first)
        await trace.placePhoto(result, source: source, in: context).value
        await setup.document.settle()
        #expect(setup.document.undoTitle == "Undo Trace")
        let options = try #require(registry.descriptor(for: TraceTool.id)?.options?() as? NSHostingController<TraceOptionsSheet>)
        Render.view(options.rootView)
        // Without the class model the sheet says what *Photo* does instead.
        #expect(PhotoTrace.fallbackNote == nil)
        PhotoTrace.mapper = nil
        let note = try #require(PhotoTrace.fallbackNote)
        #expect(note.contains("subject and the background"))
        Render.view(options.rootView)
    }
}
