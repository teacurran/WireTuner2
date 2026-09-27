import CoreSpotlight
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
@testable import WireTuner

/// The `WireTunerSpotlightImporter` extension's mapping (saving.adoc, "Client": Spotlight,
/// packages; IO-035): a package on disk onto the Spotlight attributes.
@Suite @MainActor struct SpotlightImporterTests {
    /// A three-page package whose text holds "quokka", with a description and keywords.
    static func package(title: String) throws -> URL {
        var core = DocumentCore(state: EngineState(), replica: 0x35)
        let recording = DocumentCore.Recording(limit: 1, now: Date())
        _ = try core.perform(AddPages(count: 2, after: PageList(core.state).pages[0].id), recording: recording)
        _ = try core.perform(CreateTextBlock(.point(Point(x: 10, y: 10)), text: "The quokka smiles"), recording: recording)
        _ = try core.perform(SetDocumentInfo(.description, .text("A poster about marsupials")), recording: recording)
        _ = try core.perform(SetDocumentKeywords(adding: ["wildlife", "quokka"]), recording: recording)
        let contents = DocumentPackage.contents(of: core.state, info: DocumentPackage.Info(documentID: "spotlight", title: title),
                                                page: Rect(x: 0, y: 0, width: 612, height: 792)) { _ in nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "SpotlightImporter-\(UUID().uuidString).wiretuner")
        try PackageWriter().data(contents).data.write(to: url)
        return url
    }

    @Test func aPackageFillsTheAttributes() throws {
        let url = try Self.package(title: "Rottnest")
        defer { try? FileManager.default.removeItem(at: url) }
        let set = CSSearchableItemAttributeSet(contentType: PackageController.contentType)
        try SpotlightImport.update(set, forFileAt: url)
        #expect(set.title == "Rottnest" && set.displayName == "Rottnest")
        #expect(set.contentDescription == "A poster about marsupials")
        #expect(set.keywords == ["quokka", "wildlife"])
        #expect(set.textContent?.contains("quokka") == true)
        #expect(set.pageCount == 3)
        // Over the decode limit: the title alone, nothing else set.
        let small = CSSearchableItemAttributeSet(contentType: PackageController.contentType)
        try SpotlightImport.update(small, forFileAt: url, limit: 16)
        #expect(small.title == "Rottnest" && small.pageCount == nil && small.textContent == nil && small.keywords == nil && small.contentDescription == nil)
    }

    @Test func somethingElseThrows() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "SpotlightImporter-\(UUID().uuidString).wiretuner")
        try Data("not a package".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try SpotlightImport.update(CSSearchableItemAttributeSet(contentType: .data), forFileAt: url) }
    }
}
