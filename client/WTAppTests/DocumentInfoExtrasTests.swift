import AppKit
import Foundation
import SwiftUI
import Testing
import WTModel
@testable import WireTuner

/// IO-011's remainder: the hosted `NSTokenField` for keywords and the offline library search over
/// them.
@Suite(.serialized) @MainActor struct DocumentInfoExtrasTests {
    @Test func theTokenFieldAddsAndRemovesByDifference() async throws {
        #expect(KeywordTokenField.Coordinator.difference(tokens: ["Blue", " poster ", ""], keywords: ["blue", "red"]) == (["poster"], ["red"]))
        let setup = SetupWindow()
        defer { setup.close() }
        let model = DocumentInfoModel(document: setup.document) { [weak window = setup.window] command in window?.objectEditing.perform(command) }
        var field = KeywordTokenField(keywords: model.keywords, add: model.addKeywords, remove: model.removeKeyword)
        let coordinator = field.makeCoordinator()
        coordinator.apply(["blue", "poster"])
        await setup.document.settle()
        #expect(model.keywords == ["blue", "poster"])
        field = KeywordTokenField(keywords: model.keywords, add: model.addKeywords, remove: model.removeKeyword)
        coordinator.parent = field
        coordinator.apply(["poster"])
        await setup.document.settle()
        #expect(model.keywords == ["poster"])
        // The field's own events.
        let token = NSTokenField()
        token.objectValue = ["poster", "sale"]
        coordinator.parent = KeywordTokenField(keywords: model.keywords, add: model.addKeywords, remove: model.removeKeyword)
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: token))
        await setup.document.settle()
        #expect(model.keywords == ["poster", "sale"])
        coordinator.parent = KeywordTokenField(keywords: model.keywords, add: model.addKeywords, remove: model.removeKeyword)
        #expect(coordinator.tokenField(token, shouldAdd: ["summer"], at: 2).count == 1)
        await setup.document.settle()
        #expect(model.keywords.contains("summer"))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: nil))
        // Hosted, it shows the keywords and follows them.
        PanelRendering.host(KeywordTokenField(keywords: model.keywords, add: { _ in }, remove: { _ in }), size: NSSize(width: 300, height: 40))
        PanelRendering.host(DocumentInfoSheet(model: model), size: NSSize(width: 520, height: 640))
    }

    @Test func theOfflineSearchMatchesRecordedKeywords() async throws {
        let server = FakeLibraryServer()
        server.put(LibraryDocument(id: "d1", spaceID: server.accountID, name: "Flyer"))
        server.put(LibraryDocument(id: "d2", spaceID: server.accountID, name: "Poster"))
        let model = LibraryModel(services: server.services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        await model.refresh()
        #expect(model.nameMatches("summer").isEmpty)
        model.recordKeywords("d1", ["Summer", "sale"])
        model.recordKeywords("d1", ["Summer", "sale"])
        model.recordKeywords("missing", ["summer"])
        #expect(model.nameMatches("summer").map(\.id) == ["d1"] && model.nameMatches("post").map(\.id) == ["d2"])
        // An open document's keywords are recorded as they change.
        let setup = SetupWindow()
        defer { setup.close() }
        var recorded: [(String, [String])] = []
        let index = DocumentKeywordIndex.attach(setup.window) { recorded.append(($0, $1)) }
        #expect(index.last == [] && recorded.count == 1)
        _ = await setup.document.perform(SetDocumentKeywords(adding: ["blue"])).value
        await setup.document.settle()
        #expect(recorded.last?.1 == ["blue"] && recorded.last?.0 == setup.document.id)
        _ = await setup.document.perform(SetDocumentInfo(.title, .text("T"))).value
        await setup.document.settle()
        #expect(recorded.count == 2, "a change that leaves the keywords alone records nothing")
    }
}
