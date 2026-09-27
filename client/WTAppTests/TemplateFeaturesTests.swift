import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTRender
import WTSync
@testable import WireTuner

/// DOC-019 (gallery half), DOC-029 and DOC-030: the template gallery, the template flag, the
/// default template and Save as Template (templates.adoc).
@Suite @MainActor struct TemplateFeaturesTests {
    let server = FakeLibraryServer()
    let suite = TestDefaults()

    func library() -> LibraryModel {
        LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil), debounce: .milliseconds(1))
    }

    static func templateState() throws -> EngineState {
        var core = try DocumentCreation.newDocument(from: .builtIn, replica: 3)
        _ = try core.perform(AddPages(count: 2), recording: DocumentCore.Recording(limit: 1, now: Date()))
        return core.state
    }

    func template(_ id: String, _ name: String, space: String? = nil) -> LibraryDocument {
        var document = LibraryDocument(id: id, spaceID: space ?? server.accountID, name: name)
        document.isTemplate = true
        return document
    }

    @Test func theGalleryListsMyAndTeamTemplatesAndCreatesFromAStartingPoint() async throws {
        server.put(template("t1", "Letterhead"))
        server.put(template("t2", "Team deck", space: "team1"))
        server.put(LibraryDocument(id: "d1", spaceID: server.accountID, name: "Not a template"))
        server.setTeams([LibrarySpace(id: "team1", name: "Acme", kind: .team)])
        let library = library()
        await library.refresh()
        await library.refreshTemplates()
        let gallery = TemplateGalleryModel(library: library)
        #expect(gallery.groups.map(\.title) == [TemplateGalleryModel.myTemplates, "Acme"])
        #expect(gallery.groups.map { $0.templates.map(\.id) } == [["t1"], ["t2"]])

        gallery.choice = .startingPoint(.publication)
        #expect(gallery.options == StartingPoints.defaults(for: .publication))
        gallery.options.pageCount = 4
        gallery.presetName = "A4"
        #expect(gallery.options.size.width.rounded() == 595 && gallery.options.size.height.rounded() == 842)
        gallery.width = 900
        #expect(gallery.options.preset == "" && gallery.options.orientation == .landscape && gallery.width == 900 && gallery.height.rounded() == 842)
        gallery.height = 1000
        #expect(gallery.options.orientation == .portrait)
        let closed = TemplateTestBox(false)
        gallery.onClose = { closed.value = true }
        let document = try #require(await gallery.create())
        #expect(closed.value && document.isPendingUpload)
        guard case let .startingPoint(options)? = library.takeTemplate(for: document.id) else { Issue.record("starting point"); return }
        #expect(options.kind == .publication && options.pageCount == 4)
        #expect(library.takeTemplate(for: document.id) == nil, "taken once")
        gallery.options.pageCount = 0
        #expect(!gallery.canCreate)
        #expect(await gallery.create() == nil)
    }

    @Test func aLibraryTemplateIsCopiedAndAnUncachedOneIsDimmedOffline() async throws {
        server.put(template("t1", "Letterhead"))
        let library = library()
        await library.refresh()
        await library.refreshTemplates()
        let state = try Self.templateState()
        let cached = TemplateTestBox<Set<String>>([])
        let loads = TemplateTestBox(0)
        let gallery = TemplateGalleryModel(library: library, states: TemplateStates(
            open: { _ in nil }, isCached: { cached.value.contains($0) },
            load: { _ in
                loads.value += 1
                return state
            }
        ))
        gallery.choice = .template("t1")
        #expect(gallery.canCreate && gallery.unavailableReason(library.cache.documents["t1"]!) == nil)
        let document = try #require(await gallery.create())
        guard case let .document(copied, name)? = library.takeTemplate(for: document.id) else { Issue.record("template"); return }
        #expect(name == "Letterhead" && PageList(copied).pages.count == 3 && loads.value == 1)

        server.offline = true
        await library.refresh()
        #expect(!library.isOnline)
        #expect(gallery.unavailableReason(library.cache.documents["t1"]!) == TemplateGalleryModel.offlineUncached && !gallery.canCreate)
        cached.value.insert("t1")
        #expect(gallery.canCreate)
        gallery.choice = .template("missing")
        #expect(!gallery.canCreate)
    }

    @Test func aTemplateThatCannotBeReadSaysWhy() async throws {
        server.put(template("t1", "Letterhead"))
        let library = library()
        await library.refresh()
        await library.refreshTemplates()
        let gallery = TemplateGalleryModel(library: library, states: TemplateStates(load: { _ in throw TemplateDownload.Failure.notCached }))
        gallery.choice = .template("t1")
        #expect(await gallery.create() == nil)
        #expect(gallery.errorMessage == TemplateGalleryModel.offlineUncached)
        gallery.states = TemplateStates(load: { _ in throw CocoaError(.fileReadCorruptFile) })
        #expect(await gallery.create() == nil)
        #expect(gallery.errorMessage?.hasPrefix("The template could not be opened") == true)
        gallery.choice = .startingPoint(.screen)
        #expect(gallery.errorMessage == nil)
    }

    @Test func theFlagIsSetOnlineRefusedOfflineAndFollowsAPendingCreate() async throws {
        server.put(LibraryDocument(id: "d1", spaceID: server.accountID, name: "Doc"))
        let library = library()
        await library.refresh()
        await library.setTemplate("d1", true)
        #expect(library.cache.documents["d1"]?.isTemplate == true && server.calls.contains("setTemplate:true"))
        await library.show(.templates)
        #expect(library.documents.map(\.id) == ["d1"])
        #expect(LibraryToolbar(model: library).title == "Personal › Templates")
        await library.setTemplate("d1", true)
        #expect(server.calls.filter { $0.hasPrefix("setTemplate") }.count == 1, "no change, no call")

        server.offline = true
        await library.setTemplate("d1", false)
        #expect(library.cache.documents["d1"]?.isTemplate == true && library.errorMessage == LibraryModel.templateFlagOfflineMessage)

        // Recorded offline as a template: flagged after its Create.
        let copy = library.recordDocument(name: "Saved", isTemplate: true)
        await library.pendingUploads[copy.id]?.value
        await library.setTemplate(copy.id, false)
        await library.setTemplate(copy.id, true)
        #expect(library.cache.documents[copy.id]?.isTemplate == true && library.cache.documents[copy.id]?.isPendingUpload == true)
        server.offline = false
        await library.refresh()
        #expect(server.documents[copy.id]?.isTemplate == true && library.cache.documents[copy.id]?.isPendingUpload == false)
        #expect(server.calls.contains("create:Saved"))
    }

    @Test func fileNewUsesTheDefaultTemplateAndFallsBackOnce() async throws {
        server.put(template("t1", "Letterhead"))
        let library = library()
        await library.refresh()
        await library.refreshTemplates()
        let preferences = PreferenceStore(defaults: suite.defaults)
        let state = try Self.templateState()
        let available = TemplateTestBox(true)
        let features = TemplateFeatures(library: library, preferences: preferences, states: TemplateStates(load: { _ in
            guard available.value else { throw TemplateDownload.Failure.notCached }
            return state
        }))
        let notices = TemplateTestBox<[String]>([])
        features.notify = { notices.value.append($0) }
        let builtIn = await features.newDocument()
        #expect(library.takeTemplate(for: builtIn.id) == nil, "no default: built in")
        #expect(features.templateChoices.map(\.id) == ["", "t1"])
        #expect(TemplateChoices.choices(current: "gone").last?.id == "gone")

        _ = preferences.set("t1", for: PreferenceCatalog.Document.newTemplate)
        #expect(features.defaultTemplateID == "t1")
        let fromTemplate = await features.newDocument(name: "Memo")
        #expect(fromTemplate.name == "Memo")
        guard case .document(_, "Letterhead")? = library.takeTemplate(for: fromTemplate.id) else { Issue.record("template"); return }

        available.value = false
        let fallback = await features.newDocument()
        #expect(library.takeTemplate(for: fallback.id) == nil)
        #expect(notices.value == [TemplateFeatures.fallbackMessage("Letterhead")])
        _ = await features.newDocument()
        #expect(notices.value.count == 1, "told once")
        suite.remove()
    }

    @Test func saveAsTemplateStoresAFlaggedCopyAndLeavesTheDocument() async throws {
        let library = library()
        await library.refresh()
        let preferences = PreferenceStore(defaults: suite.defaults)
        let sheets = SheetPresenter()
        sheets.present = { _ in }
        let features = TemplateFeatures(library: library, preferences: preferences, sheets: sheets)
        let written = TemplateTestBox<[(String, DocumentCreation.Template)]>([])
        features.writeCopy = { id, template in written.value.append((id, template)) }
        let document = DocumentHandle.memory(title: "Brochure")
        let before = document.state.stateHash
        #expect(await features.saveAsTemplate(document, name: "  ", spaceID: server.accountID) == nil)
        let copy = try #require(await features.saveAsTemplate(document, name: "Brochure template", spaceID: server.accountID))
        #expect(copy.isTemplate && copy.folderID == nil && library.isOfflineAvailable(copy))
        #expect(document.state.stateHash == before, "the working document is unchanged")
        guard case let .document(state, name) = try #require(written.value.first).1 else { Issue.record("copy"); return }
        #expect(name == "Brochure" && state.stateHash == before)
        await library.pendingUploads[copy.id]?.value
        #expect(server.documents[copy.id]?.isTemplate == true)

        features.writeCopy = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(await features.saveAsTemplate(document, name: "Again", spaceID: server.accountID) == nil)
        #expect(library.errorMessage?.hasPrefix("The template could not be saved") == true)
        suite.remove()
    }

    @Test func theSheetAndCommandsDriveSaveAsTemplate() async throws {
        let library = library()
        let preferences = PreferenceStore(defaults: suite.defaults)
        let sheets = SheetPresenter()
        sheets.present = { _ in }
        let features = TemplateFeatures(library: library, preferences: preferences, sheets: sheets)
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        features.install(into: registry) { nil }
        #expect(registry.command(TemplateFeatures.ID.newFromTemplate)?.defaultKey == KeyEquivalent("n", [.command, .shift]))
        #expect(registry.validate(TemplateFeatures.ID.saveAsTemplate)?.reason == TemplateFeatures.needsWindow)
        #expect(TemplateChoices.choices(current: "").first?.title == "Built-in")

        let model = SaveAsTemplateModel(name: "Doc", spaces: library.spaces) { _ in }
        #expect(model.canSave && SaveAsTemplateModel.title(of: library.personalSpace) == TemplateGalleryModel.myTemplates)
        model.name = " "
        #expect(!model.canSave)
        let view = NSHostingView(rootView: SaveAsTemplateView(model: SaveAsTemplateModel(name: "Doc", spaces: library.spaces) { _ in }))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
        suite.remove()
    }

    @Test func theGalleryWindowRendersEveryChoice() async throws {
        server.put(template("t1", "Letterhead"))
        let library = library()
        let features = TemplateFeatures(library: library, preferences: PreferenceStore(defaults: suite.defaults))
        let controller = features.showGallery()
        await controller.show().value
        let content = try #require(controller.window?.contentView)
        for kind in StartingPoints.Kind.allCases {
            controller.model.choice = .startingPoint(kind)
            content.layoutSubtreeIfNeeded()
            #expect(!TemplateGalleryView.symbol(kind).isEmpty)
        }
        controller.model.choice = .template("t1")
        content.layoutSubtreeIfNeeded()
        #expect(features.showGallery() === controller)
        controller.model.onClose()
        #expect(controller.window?.isVisible == false)
        suite.remove()
    }
}

/// A mutable value the tests' main-actor closures share.
@MainActor
final class TemplateTestBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
