import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// IO-035's package half: what the Spotlight importer reads from a package on disk
/// (saving.adoc, "Quick Look and Spotlight").
@Suite struct PackageSpotlightTests {
    static func package(text: String, title: String) throws -> Data {
        var a = Replica(0xA)
        try a.perform(SetBleed([PageList.synthesizedID], to: 0))
        try a.perform(AddPages(count: 2, after: PageList(a.state).pages[0].id))
        try a.perform(CreateTextBlock(.point(Point(x: 10, y: 10)), text: text))
        try a.perform(SetDocumentInfo(.description, .text("A poster about marsupials")))
        try a.perform(SetDocumentKeywords(adding: ["wildlife", "quokka"]))
        let info = DocumentPackage.Info(documentID: "0190a1b2-0000-7000-8000-000000000001", title: title, exportedBy: "user", exportedByName: "Me",
                                        appVersion: "0.1.0/1", headServerSeq: 1, unsyncedChanges: 0, exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let contents = DocumentPackage.contents(of: a.state, info: info, page: Rect(x: 0, y: 0, width: 612, height: 792)) { _ in nil }
        return try PackageWriter().data(contents).data
    }

    @Test func titleKeywordsDescriptionTextAndPageCount() throws {
        let data = try Self.package(text: "The quokka smiles", title: "Rottnest")
        let attributes = try PackageSpotlightAttributes.read(data)
        #expect(attributes.title == "Rottnest" && !attributes.isTitleOnly)
        #expect(attributes.content.text.contains("quokka") && attributes.content.description == "A poster about marsupials")
        #expect(attributes.content.keywords == ["quokka", "wildlife"])
        #expect(attributes.pageCount == 3)
        let url = FileManager.default.temporaryDirectory.appending(component: "spotlight-\(UUID().uuidString).wtpkg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try PackageSpotlightAttributes.read(contentsOf: url) == attributes)
    }

    @Test func aPackageOverTheLimitIsIndexedByTitleOnly() throws {
        let data = try Self.package(text: "quokka", title: "Big")
        let started = ContinuousClock.now
        let attributes = try PackageSpotlightAttributes.read(data, limit: 16)
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(attributes == PackageSpotlightAttributes(title: "Big") && attributes.isTitleOnly)
        #expect(PackageSpotlightAttributes.decodeLimit == 64 << 20)
    }

    @Test func somethingElseIsRefused() {
        #expect(throws: (any Error).self) { try PackageSpotlightAttributes.read(Data("not a zip".utf8)) }
    }
}
