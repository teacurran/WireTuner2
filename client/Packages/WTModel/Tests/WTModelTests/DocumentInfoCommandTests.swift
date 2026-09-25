import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// IO-011: the Document Info sheet's writes (file-info.adoc, "Merge semantics").
@Suite struct DocumentInfoCommandTests {
    @Test func everyTextFieldIsOneLabelledRegisterWriteAndReadsTrimmed() throws {
        var a = Replica(0xA)
        for field in DocumentInfoField.allCases where field.isText {
            let value = field == .webStatement ? " https://example.com/rights " : (field == .category ? "ART" : " \(field.title) ")
            let change = try #require(try a.perform(SetDocumentInfo(field, .text(value))))
            #expect(change.label == "Change Document Info" && change.ops.count == 1)
        }
        let values = DocumentInfoValues(a.state)
        #expect(values[.title] == "Title" && values[.headline] == "Headline" && values[.description] == "Description")
        #expect(values[.webStatement] == "https://example.com/rights" && values[.category] == "ART" && values[.language] == "Language")
        #expect(values[.creatorJobTitle] == "Creator's job title" && values[.city] == "City" && values[.state] == "State/Province")
        // The lists and the status are not text: the subscript reads nothing for them.
        #expect(values[.creators] == "Title")
        try a.perform(SetDocumentInfo(.creators, .list([" Ana ", "", "Ben"])))
        try a.perform(SetDocumentInfo(.supplementalCategories, .list(["SPO"])))
        try a.perform(SetDocumentInfo(.copyrightStatus, .copyrightStatus(.copyrighted)))
        let lists = DocumentInfoValues(a.state)
        #expect(lists.info.creators == ["Ana", "Ben"] && lists.info.supplementalCategories == ["SPO"] && lists.info.copyrightStatus == .copyrighted)
        // Three field commits are three undo steps.
        a.undo()
        a.undo()
        #expect(DocumentInfoValues(a.state).info.creators == ["Ana", "Ben"] && DocumentInfoValues(a.state).info.supplementalCategories.isEmpty)
    }

    @Test func limitsShapesAndURLsAreChecked() throws {
        var a = Replica(0xA)
        #expect(throws: DocumentInfoError.tooLong(.headline)) { try a.perform(SetDocumentInfo(.headline, .text(String(repeating: "h", count: 257)))) }
        #expect(throws: DocumentInfoError.invalidURL) { try a.perform(SetDocumentInfo(.webStatement, .text("not a url"))) }
        #expect(throws: DocumentInfoError.mismatch(.title)) { try a.perform(SetDocumentInfo(.title, .list(["x"]))) }
        #expect(throws: DocumentInfoError.tooMany(.supplementalCategories)) { try a.perform(SetDocumentInfo(.supplementalCategories, .list(["a", "b", "c", "d"]))) }
        #expect(throws: DocumentInfoError.tooLong(.creators)) { try a.perform(SetDocumentInfo(.creators, .list([String(repeating: "c", count: 257)]))) }
        #expect(try a.perform(SetDocumentInfo(.webStatement, .text(""))) != nil)
        let limits = DocumentInfoField.allCases.map(\.limit)
        #expect(limits.contains(3) && limits.contains(2000) && limits.contains(1024) && limits.contains(32) && limits.contains(35) && limits.contains(256))
        #expect(DocumentInfoField.allCases.map(\.title).count == Set(DocumentInfoField.allCases.map(\.title)).count)
    }

    @Test func keywordsAreAnAddWinsSetReadSortedAndCollapsed() throws {
        var pair = Pair()
        let added = try #require(try pair.a.perform(SetDocumentKeywords(adding: ["poster", " Blue ", ""])))
        #expect(added.label == "Change Document Info" && added.ops.count == 1)
        pair.sync()
        #expect(DocumentInfoValues(pair.b.state).keywords == ["Blue", "poster"])
        // A concurrent add and remove of one keyword keeps it.
        try pair.a.perform(SetDocumentKeywords(removing: ["POSTER"]))
        try pair.b.perform(SetDocumentKeywords(adding: ["poster", "blue"]))
        pair.sync()
        #expect(DocumentInfoValues(pair.a.state).keywords == ["Blue", "poster"])
        #expect(DocumentInfoValues(pair.a.state).keywords == DocumentInfoValues(pair.b.state).keywords)
        #expect(try pair.a.perform(SetDocumentKeywords(removing: ["missing"])) == nil)
        #expect(throws: DocumentInfoError.keywords) { try pair.a.perform(SetDocumentKeywords(adding: [String(repeating: "k", count: 65)])) }
        #expect(throws: DocumentInfoError.keywords) { try pair.a.perform(SetDocumentKeywords(adding: (0..<501).map { "k\($0)" })) }
        #expect(DocumentInfoValues.keywords(["b", "A", "a", " "]) == ["A", "b"])
    }
}
