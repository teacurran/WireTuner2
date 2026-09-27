import Testing
@testable import WTText

/// The Text menu's and Text toolbar's font and size rules (type-specifications.adoc, "Font, size
/// and style").
@Suite struct FontChoicesTests {
    @Test func sizesStepParseAndFormat() {
        #expect(TypeSizes.presets == [9, 10, 12, 14, 18, 24, 36, 48, 72])
        #expect(TypeSizes.stepped(12, by: 1) == 13)
        #expect(TypeSizes.stepped(12, by: -1) == 11)
        #expect(TypeSizes.stepped(1.5, by: -1) == 1)
        #expect(TypeSizes.stepped(9_999.5, by: 1) == 10_000)
        #expect(TypeSizes.parse("12") == 12)
        #expect(TypeSizes.parse(" 12.5 pt ") == 12.5)
        #expect(TypeSizes.parse("9PT") == 9)
        #expect(TypeSizes.parse("0.5") == nil)
        #expect(TypeSizes.parse("10001") == nil)
        #expect(TypeSizes.parse("big") == nil)
        #expect(TypeSizes.parse("") == nil)
        #expect(TypeSizes.format(12) == "12")
        #expect(TypeSizes.format(12.5) == "12.5")
    }

    @Test func theFamilyListGroupsRecentMissingAndAll() {
        let installed = ["Avenir", "Helvetica", "Menlo"]
        let list = FontFamilyList(installed: installed, recents: ["Menlo", "Gone", "Futura PT"],
                                  documentFamilies: ["Helvetica", "Futura PT"], isAvailable: { installed.contains($0) })
        #expect(list.recent.map(\.family) == ["Menlo", "Futura PT"])
        #expect(list.recent[1].isMissing && list.recent[1].title == "[Futura PT]")
        #expect(list.missing == [FontFamilyChoice(family: "Futura PT", inDocument: true, isMissing: true)])
        #expect(list.all.map(\.family) == installed)
        #expect(list.all[1].inDocument && !list.all[1].isMissing && list.all[1].title == "Helvetica")
        #expect(!list.all[0].inDocument)
        #expect(list.flattened.map(\.family) == ["Menlo", "Futura PT", "Avenir", "Helvetica"])
    }

    @Test func recentsMoveToTheFrontAndStayShort() {
        #expect(FontRecents.adding("A", to: ["B", "A", "C"]) == ["A", "B", "C"])
        #expect(FontRecents.adding("", to: ["B"]) == ["B"])
        let long = (0..<12).map { "F\($0)" }
        #expect(FontRecents.adding("X", to: long).count == FontRecents.limit)
        #expect(FontRecents.adding("X", to: long, limit: 2) == ["X", "F0"])
    }

    @Test func theFilterPutsPrefixMatchesFirst() {
        let families = ["Arial", "Helvetica Neue", "Neue Haas", "Menlo"]
        #expect(FontFilter.filter(families, matching: "neue") == ["Neue Haas", "Helvetica Neue"])
        #expect(FontFilter.filter(families, matching: "  ") == families)
        #expect(FontFilter.filter(["Didot", "Dïdone"], matching: "did") == ["Didot", "Dïdone"])
        #expect(FontFilter.filter(families, matching: "zzz").isEmpty)
    }
}
