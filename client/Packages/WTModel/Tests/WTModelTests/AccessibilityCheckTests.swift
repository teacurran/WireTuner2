import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// IO-033: the accessibility check.
@Suite @MainActor struct AccessibilityCheckTests {
    static func group(_ replica: inout Replica, _ members: [OpID]) throws -> OpID {
        let change = try #require(try replica.perform(GroupObjects(members)))
        return try #require(change.createdNodes.first { replica.state.nodeKind($0) == .group })
    }

    @Test func missingDescriptionsListImagesTracingAndOutlinedTextOnly() throws {
        var a = Replica(1)
        let undescribed = try ImageCommandsTests.place(&a)
        let decorative = try ImageCommandsTests.place(&a)
        _ = try a.perform(SetDecorative([decorative], decorative: true))
        let layer = try NavigationFixture.layer(&a)
        let traced = try Self.group(&a, [try NavigationFixture.rect(&a, on: layer), try NavigationFixture.rect(&a, on: layer, x: 20)])
        _ = try a.perform(SetNameOrNote([traced], .name, "Trace of photo.png"))
        let outlined = try Self.group(&a, [try NavigationFixture.rect(&a, on: layer, x: 40), try NavigationFixture.rect(&a, on: layer, x: 60)])
        _ = try a.perform(AppendNote([outlined], line: AccessibilityCheck.outlinedTextNote))
        let covered = try ImageCommandsTests.place(&a)
        let described = try Self.group(&a, [covered, try NavigationFixture.rect(&a, on: layer, x: 80)])
        _ = try a.perform(SetAlt([described], alt: "A photograph with a caption"))
        let plain = try Self.group(&a, [try NavigationFixture.rect(&a, on: layer, x: 100), try NavigationFixture.rect(&a, on: layer, x: 120)])
        let missing = AccessibilityCheck.missingDescriptions(in: a.state, pages: PageList(a.state))
        #expect(Set(missing.map(\.node)) == [undescribed, traced, outlined], "exactly the first, third and fourth")
        #expect(missing.first { $0.node == traced }?.reason == .tracing && missing.first { $0.node == outlined }?.reason == .outlinedText)
        #expect(missing.first { $0.node == undescribed }?.reason == .image && missing.first { $0.node == undescribed }?.page == 1)
        #expect(AccessibilityCheck.reason(plain, in: a.state) == nil && AccessibilityCheck.reason(layer, in: a.state) == nil)
        #expect(missing.map(\.id) == missing.map(\.node))
    }

    @Test func convertingTextToPathsMarksTheGroup() throws {
        var a = Replica(1)
        let text = try TextFixture.block(&a, "Hi")
        let conversion = try TextToPaths.conversion(text, in: a.state, engine: TextLayoutEngine(fonts: .shared))
        let change = try #require(try a.perform(ConvertTextToPaths([conversion])))
        let group = try #require(change.createdNodes.first { a.state.nodeKind($0) == .group })
        #expect(AccessibilityCheck.reason(group, in: a.state) == .outlinedText)
    }

    @Test func theContrastRuleFollowsWCAG() {
        #expect(AccessibilityCheck.luminance(red: 1, green: 1, blue: 1) == 1 && AccessibilityCheck.luminance(red: 0, green: 0, blue: 0) == 0)
        #expect(abs(AccessibilityCheck.luminance(Color(white: 0.5)) - 0.214) < 0.001)
        #expect(AccessibilityCheck.ratio(1, 0) == 21 && AccessibilityCheck.ratio(0, 1) == 21)
        #expect(AccessibilityCheck.isLarge(size: 18, weight: 400) && AccessibilityCheck.isLarge(size: 14, weight: 700))
        #expect(!AccessibilityCheck.isLarge(size: 14, weight: 400) && !AccessibilityCheck.isLarge(size: 12, weight: 700))
        #expect(AccessibilityCheck.required(large: true) == 3 && AccessibilityCheck.required(large: false) == 4.5)
        #expect(AccessibilityCheck.weight(ofStyle: "Bold Italic") == 700 && AccessibilityCheck.weight(ofStyle: "Black") == 700)
        #expect(AccessibilityCheck.weight(ofStyle: "Regular") == 400 && AccessibilityCheck.weight(ofStyle: nil) == 400)
        #expect(AccessibilityCheck.worstRatio(text: 0, backdrop: []) == nil)
    }

    /// A backdrop luminance giving `ratio` against black text.
    static func backdrop(_ ratio: Double) -> Double { ratio * 0.05 - 0.05 }

    @Test func contrastFixturesAreClassifiedForNormalAndLargeText() throws {
        for (ratio, normal, large) in [(3.0, false, true), (4.4, false, true), (4.6, true, true), (7.0, true, true)] {
            // Flat backdrop.
            let flat = try #require(AccessibilityCheck.worstRatio(text: 0, backdrop: Array(repeating: Self.backdrop(ratio), count: 100)))
            #expect(abs(flat - ratio) < 1e-9)
            #expect((flat >= AccessibilityCheck.required(large: false)) == normal && (flat >= AccessibilityCheck.required(large: true)) == large)
            // A gradient from the fixture's value up to white: the worse (darker) end is reported.
            let gradient = (0..<100).map { Self.backdrop(ratio) + (1 - Self.backdrop(ratio)) * Double($0) / 99 }
            let measured = try #require(AccessibilityCheck.worstRatio(text: 0, backdrop: gradient))
            #expect(measured < AccessibilityCheck.ratio(0, 1) && measured <= AccessibilityCheck.ratio(0, gradient[50]))
            #expect(abs(measured - AccessibilityCheck.ratio(0, gradient[10])) < 1e-9)
        }
    }

    @Test func textOverADarkRectangleIsReportedAndOverThePageIsNot() throws {
        var a = Replica(1)
        _ = try a.perform(AddPages(count: 1))
        let page = PageList(a.state).pages[0]
        let layer = try NavigationFixture.layer(&a)
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        // sRGB 0.349 grey: luminance 0.1, 3:1 against black.
        appearance.fills.append(Appearances.basicFill(red: 0.349, green: 0.349, blue: 0.349))
        let box = try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 300, height: 100),
                                            transform: .translation(x: page.origin.x + 40, y: page.origin.y + 40), appearance: appearance, layer: layer))!.createdObjects[0]
        let dark = try a.perform(CreateTextBlock(.area(Rect(x: page.origin.x + 50, y: page.origin.y + 50, width: 200, height: 40)), text: "Low contrast", layer: layer))!.createdObjects[0]
        let light = try a.perform(CreateTextBlock(.area(Rect(x: page.origin.x + 50, y: page.origin.y + 300, width: 200, height: 40)), text: "Fine", layer: layer))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.textLayout = TextSceneLayout(engine: TextLayoutEngine(fonts: .shared))
        let scene = builder.rebuild(a.state)
        let report = AccessibilityCheck.run(a.state, displayList: scene.displayList)
        let low = try #require(report.lowContrast.first)
        #expect(report.lowContrast.map(\.node) == [dark] && !report.lowContrast.contains { $0.node == light })
        #expect(abs(low.ratio - 3) < 0.2 && low.required == 4.5 && !low.isLarge && low.page == 1 && low.line == 0 && low.id == "\(dark)-0")
        #expect(report.missingLanguage && !report.isClean)
        let pages = PageList(a.state).pages
        #expect(report.readingOrder.map(\.id) == pages.map(\.id) && report.readingOrder.map(\.name) == pages.map { "Page \($0.number)" })
        #expect(report.readingOrder.first { $0.number == low.page }?.order.contains(box) == true)
        // A language set: that row goes.
        _ = try a.perform(SetDocumentInfo(.language, .text("en")))
        #expect(!AccessibilityCheck.run(a.state, displayList: scene.displayList).missingLanguage)
        // Nothing drawn under a rectangle reads as white.
        #expect(AccessibilityCheck.luminances(DisplayList(canvas: "c", items: []), in: Rect(x: 0, y: 0, width: 4, height: 4)).allSatisfy { $0 == 1 })
    }

    @Test func aRowFixIsOneChangeLabelledDescribe() throws {
        var a = Replica(1)
        let image = try ImageCommandsTests.place(&a)
        let change = try #require(try a.perform(DescribeObject(image, .alt("A red kite"), name: "photo.png")))
        #expect(change.label == "Describe \"photo.png\"" && change.ops.count == 1)
        #expect(a.state.accessibleDescription(of: image) == "A red kite")
        _ = try a.perform(DescribeObject(image, .decorative(true), name: "photo.png"))
        #expect(!a.state.isReadable(image))
        a.undo()
        #expect(a.state.isReadable(image))
        a.undo()
        #expect(a.state.accessibleDescription(of: image) == nil)
        #expect(AccessibilityCheck.missingDescriptions(in: a.state, pages: PageList(a.state)).map(\.node) == [image])
    }

    @Test func anEmptyDocumentIsCleanAndGroupedTextIsMeasured() throws {
        #expect(AccessibilityReport().isClean && Rect(enclosing: []) == nil)
        var a = Replica(1)
        let layer = try NavigationFixture.layer(&a)
        let text = try a.perform(CreateTextBlock(.area(Rect(x: 10, y: 10, width: 100, height: 30)), text: "Grouped", layer: layer))!.createdObjects[0]
        let box = try NavigationFixture.rect(&a, on: layer, x: 200)
        let group = try Self.group(&a, [text, box])
        #expect(AccessibilityCheck.textNodes(in: a.state).map(\.node) == [text] && AccessibilityCheck.textNodes(in: a.state).map(\.top) == [group])
        #expect(!AccessibilityCheck.isDescribed(OpID(counter: 999, replica: 9), in: a.state))
    }
}
