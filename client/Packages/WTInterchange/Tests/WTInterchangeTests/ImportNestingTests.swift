// Pathologically nested input (import-formats.adoc, "Client", *Nesting*): files nesting arrays,
// procedures, dictionaries, groups, clips, layers, elements, `use` chains, colour spaces,
// functions, Type 3 glyphs and Illustrator document data 100,000 levels deep are read without
// exhausting the stack -- on a thread with the 512 KB stack every open and import runs on (a
// Swift concurrency `Task.detached`) -- and what they produce stays within `ImportNesting.limit`
// levels, so converting, drawing and releasing the imported tree on the main thread's 8 MB stack
// cannot exhaust it either.

import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct ImportNestingTests {
    /// The levels of nesting the files are built with.
    static let levels = 100_000

    /// A secondary thread's stack: the cooperative pool's and `DispatchQueue`'s.
    static let stack = 512 * 1024
    /// The main thread's stack, where the app converts and draws an imported tree.
    static let mainStack = 8 * 1024 * 1024

    final class Outcome<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    /// `body` run on a thread with a 512 KB stack, waited for.
    static func onSmallStack<T>(_ body: @escaping () throws -> T) throws -> T {
        try onThread(stack: stack, body)
    }

    /// `body` run on a thread with `stack` bytes of stack, waited for.
    static func onThread<T>(stack: Int, _ body: @escaping () throws -> T) throws -> T {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let work = body
        let thread = Thread {
            outcome.value = Result { try work() }
            done.signal()
        }
        thread.stackSize = stack
        thread.start()
        done.wait()
        return try outcome.value!.get()
    }

    /// The depth of the deepest group (top-level nodes are depth 1), walked with a stack.
    static func depth(_ nodes: [ImportedNode]) -> Int {
        var deepest = 0
        var pending = nodes.map { ($0, 1) }
        while let (node, level) = pending.popLast() {
            deepest = max(deepest, level)
            if case .group(let group) = node {
                pending += group.children.map { ($0, level + 1) }
            }
        }
        return deepest
    }

    /// The imported scene used the way the app uses it -- walked, drawn, compared, its blobs
    /// and swatches collected -- on a main thread's stack, and its depth.
    static func exercised(_ scene: ImportedScene) throws -> Int {
        try onThread(stack: mainStack) {
            _ = scene.nodes.flatMap(\.descendants)
            _ = scene.exportScene()
            _ = scene.blobs
            _ = scene.swatches
            _ = scene.nodes.map { $0.controlBounds() }
            _ = scene == scene
            return depth(scene.nodes)
        }
    }

    // MARK: PostScript-syntax operands

    @Test func deeplyNestedOperandsReadWithinTheLimitAndTheStreamGoesOn() throws {
        for (open, close) in [("[", "]"), ("{", "}"), ("<<", ">>")] {
            let text = String(repeating: open + " ", count: Self.levels) + "7" + String(repeating: " " + close, count: Self.levels) + " 5 op"
            let items = try Self.onSmallStack {
                var parser = PDFImportParser(Data(text.utf8))
                var items: [PDFImportParser.Item] = []
                while let item = parser.next() { items.append(item) }
                return (items, parser.nestingTruncated)
            }
            #expect(items.1)
            #expect(items.0.count == 3)
            #expect(items.0.suffix(2) == [.operand(.number(5)), .op("op")])
            // The outermost container holds the limit's worth of levels, the deepest null.
            var levels = 0
            var value: PDFImportOperand?
            if case .operand(let operand) = items.0[0] { value = operand }
            while let current = value {
                switch current {
                case .array(let items), .proc(let items):
                    levels += 1
                    value = items.first
                case .dict:
                    levels += 1
                    value = nil
                default:
                    #expect(current == .null)
                    value = nil
                }
            }
            #expect(open == "<<" ? levels == 1 : levels == ImportNesting.limit)
        }
    }

    @Test func unterminatedNestingEndsAtTheEndOfTheData() throws {
        let text = String(repeating: "[ { ", count: Self.levels) + "1 ] } ) >>"
        let (items, truncated) = try Self.onSmallStack {
            var parser = PDFImportParser(Data(text.utf8))
            var items: [PDFImportParser.Item] = []
            while let item = parser.next() { items.append(item) }
            return (items, parser.nestingTruncated)
        }
        #expect(truncated)
        #expect(items.count == 1)
        guard case .operand(.array(let outer))? = items.first, case .proc(let inner)? = outer.first else {
            Issue.record("expected an array holding a procedure")
            return
        }
        #expect(inner.first != nil)
    }

    @Test func nestingWithinTheLimitReadsAsBefore() {
        var parser = PDFImportParser(Data("[1 [2 {3 add} <</K [4]>>] ) 5] (s)".utf8))
        #expect(parser.next() == .operand(.array([.number(1), .array([.number(2), .proc([.number(3), .keyword("add")]), .dict(["K": .array([.number(4)])])]), .keyword(")"), .number(5)])))
        #expect(parser.next() == .operand(.string(Data("s".utf8))))
        #expect(!parser.nestingTruncated)
        // A container just at the limit is kept; one level more reads as null.
        func nested(_ count: Int) -> PDFImportOperand? {
            var parser = PDFImportParser(Data((String(repeating: "[", count: count) + String(repeating: "]", count: count)).utf8))
            guard case .operand(let operand)? = parser.next() else { return nil }
            return operand
        }
        var kept = PDFImportOperand.array([])
        for _ in 1..<ImportNesting.limit { kept = .array([kept]) }
        #expect(nested(ImportNesting.limit) == kept)
        var cut = PDFImportOperand.array([.null])
        for _ in 1..<ImportNesting.limit { cut = .array([cut]) }
        #expect(nested(ImportNesting.limit + 1) == cut)
    }

    // MARK: Legacy Illustrator

    static func legacy(_ body: String) -> Data {
        Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator(R) 8.0\n%%BoundingBox: 0 0 200 150\n%%EndSetup\n\(body)\n%%PageTrailer\n".utf8)
    }

    @Test func legacyIllustratorGroupsNestedPastTheLimitAreFlattened() throws {
        let path = "0 0 m 10 0 l 10 10 l f\n"
        for (open, close) in [("u", "U"), ("q", "Q"), ("1 1 1 1 0 0 0 0 0 0 Lb", "LB")] {
            let body = String(repeating: open + "\n", count: Self.levels) + "0 0 m 5 0 l 5 5 l W n\n" + path + String(repeating: close + "\n", count: Self.levels) + path
            let data = Self.legacy(body)
            let scene = try Self.onSmallStack { try ImportRegistry.standard.convert(data, name: "deep.ai") }
            #expect(scene.kind == .vector)
            #expect(scene.notes.contains(ImportNesting.note))
            let depth = try Self.exercised(scene)
            #expect(depth <= ImportNesting.limit)
            #expect(PDFImportFixture.paths(scene.nodes).count == 2)
            let document = try Self.onSmallStack { try ImportRegistry.standard.document(data, name: "deep.ai") }
            #expect(Self.depth(document.pages.flatMap(\.nodes)) <= ImportNesting.limit)
        }
    }

    @Test func legacyIllustratorGroupsWithinTheLimitKeepTheirClips() throws {
        let body = String(repeating: "q\n", count: 3) + "0 0 m 5 0 l 5 5 l W n\n0 0 m 10 0 l 10 10 l f\n" + String(repeating: "Q\n", count: 3)
        let scene = try ImportRegistry.standard.convert(Self.legacy(body), name: "clip.ai")
        #expect(!scene.notes.contains(ImportNesting.note))
        #expect(Self.depth(scene.nodes) == 4)
        #expect(PDFImportFixture.groups(scene.nodes).filter { $0.clip != nil }.count == 1)
    }

    @Test func legacyIllustratorOperandsNestedPastTheLimitAreNoted() throws {
        let deep = String(repeating: "[", count: Self.levels) + String(repeating: "]", count: Self.levels)
        let body = "\(deep) 0 d\n0 0 m 10 0 l 10 10 l f\n"
        let scene = try Self.onSmallStack { try ImportRegistry.standard.convert(Self.legacy(body), name: "deep.ai") }
        #expect(scene.notes.contains(ImportNesting.note))
        #expect(PDFImportFixture.paths(scene.nodes).count == 1)
        // Nesting in the skipped prolog is not the artwork's: no note.
        let prolog = Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator(R) 8.0\n%%BeginProlog\n/x \(deep) def\n%%EndProlog\n%%BeginSetup\n%%EndSetup\n0 0 m 10 0 l 10 10 l f\n".utf8)
        let quiet = try Self.onSmallStack { try ImportRegistry.standard.convert(prolog, name: "prolog.ai") }
        #expect(!quiet.notes.contains(ImportNesting.note))
        #expect(PDFImportFixture.paths(quiet.nodes).count == 1)
    }

    @Test func illustratorDocumentDataNestedPastTheLimitIsRead() throws {
        let body = Data((String(repeating: "/Dictionary : ", count: Self.levels) + "(x) /String (Name) , " + String(repeating: "; ", count: Self.levels)
            + "/Array : /Dictionary : (Board) /String (Name) , ; , ; (ArtboardArray) ,").utf8)
        let names = try Self.onSmallStack { IllustratorPrivateData.artboards(IllustratorPrivateData.dictionary(body)).map { $0["Name"]?.text } }
        #expect(names == ["Board"])
        // An artboard array deep inside is found; one past the limit is skipped with its container.
        func nested(_ levels: Int) -> Data {
            Data((String(repeating: "/Dictionary : ", count: levels) + "/Array : /Dictionary : (Deep) /String (Name) , ; , ; (ArtboardArray) , "
                + String(repeating: "; (D) , ", count: levels) + "(z) /String (Name) ,").utf8)
        }
        #expect(IllustratorPrivateData.artboards(IllustratorPrivateData.dictionary(nested(10))).map { $0["Name"]?.text } == ["Deep"])
        let deep = try Self.onSmallStack { IllustratorPrivateData.artboards(IllustratorPrivateData.dictionary(nested(Self.levels))).count }
        #expect(deep == 0)
    }

    // MARK: PDF

    @Test func pdfClipsLayersAndArraysNestedPastTheLimit() throws {
        let fill = "0 0 10 10 re f\n"
        let streams = [
            String(repeating: "q 0 0 100 100 re W n\n", count: Self.levels) + fill + String(repeating: "Q\n", count: Self.levels),
            String(repeating: "0 0 100 100 re W n\n", count: Self.levels) + fill,
            String(repeating: "/OC /L BDC\n", count: Self.levels) + fill + String(repeating: "EMC\n", count: Self.levels),
            String(repeating: "[", count: Self.levels) + String(repeating: "]", count: Self.levels) + " 0 d\n" + fill,
            // Layers and clips each within the limit, together past it.
            String(repeating: "/OC /L BDC\n", count: 100) + String(repeating: "0 0 100 100 re W n\n", count: 100) + fill,
        ]
        for content in streams {
            let data = PDFImportFixture.page(content, resources: "<< /Properties << /L << /Type /OCG /Name (L) >> >> >>")
            let scene = try Self.onSmallStack { try PDFImportFixture.importPDF(data) }
            #expect(scene.notes.contains(ImportNesting.note))
            #expect(try Self.exercised(scene) <= ImportNesting.limit + 1)
            #expect(PDFImportFixture.paths(scene.nodes).count == 1)
            if content.hasPrefix("q") {
                // Clips within the limit stay clips.
                #expect(PDFImportFixture.groups(scene.nodes).filter { $0.clip != nil }.count == ImportNesting.limit)
            }
            let document = try Self.onSmallStack { try ImportRegistry.standard.document(data, name: "deep.pdf") }
            #expect(Self.depth(document.pages.flatMap(\.nodes)) <= ImportNesting.limit + 1)
        }
    }

    @Test func pdfSelfReferringColourSpacesFunctionsAndGlyphsStop() throws {
        var f = PDFImportFixture()
        let function = f.reserve()
        f.set(function, "<< /FunctionType 3 /Domain [0 1] /Functions [\(function) 0 R] /Bounds [] /Encode [0 1] >>")
        let separation = f.reserve()
        f.set(separation, "[/Separation /Ink \(separation) 0 R \(function) 0 R]")
        let tinted = f.add("[/Separation /Ink /DeviceGray \(function) 0 R]")
        let glyph = f.stream("", "BT /T3 1 Tf (A) Tj ET 0 0 1 1 re f")
        let font = f.add("<< /Type /Font /Subtype /Type3 /FontMatrix [1 0 0 1 0 0] /FontBBox [0 0 1 1] /CharProcs << /A \(glyph) 0 R >> /Encoding << /Differences [65 /A] >> /FirstChar 65 /LastChar 65 /Widths [1] /Resources << /Font << /T3 \(f.objects.count + 1) 0 R >> >> >>")
        // The font's resources name the font itself (object `font + 1` is this alias).
        f.add("<< /Type /Font /Subtype /Type3 /FontMatrix [1 0 0 1 0 0] /FontBBox [0 0 1 1] /CharProcs << /A \(glyph) 0 R >> /Encoding << /Differences [65 /A] >> /FirstChar 65 /LastChar 65 /Widths [1] /Resources << /Font << /T3 \(font) 0 R >> >> >>")
        let resources = "<< /ColorSpace << /Loop /Loop /Sep \(separation) 0 R /Tint \(tinted) 0 R /Ix [/Indexed /Ix 1 <00FF>] >> /Font << /T3 \(font) 0 R >> >>"
        let content = "/Tint cs 0.5 scn 0 0 1 1 re f /Loop cs 0.5 sc 0 0 1 1 re f /Sep cs 0.5 scn 0 0 1 1 re f /Ix cs 0 sc 0 0 1 1 re f BT /T3 10 Tf 3 Tr (A) Tj ET BT /T3 10 Tf 7 Tr (A) Tj ET"
        let data = f.document([PDFImportFixture.Page(content, resources: resources)])
        let scene = try Self.onSmallStack { try PDFImportFixture.importPDF(data) }
        #expect(PDFImportFixture.paths(scene.nodes).count >= 3)
        #expect(try Self.exercised(scene) <= ImportNesting.limit)
    }

    @Test func pdfFunctionsAndColourSpacesWithinTheLimitStillRead() throws {
        var f = PDFImportFixture()
        let inner = f.add("<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >>")
        let stitched = f.add("<< /FunctionType 3 /Domain [0 1] /Functions [\(inner) 0 R] /Bounds [] /Encode [0 1] >>")
        let resources = "<< /ColorSpace << /Ink [/Separation /Ink /DeviceGray \(stitched) 0 R] /Alias /Ink >> >>"
        let data = f.document([PDFImportFixture.Page("/Alias cs 1 sc 0 0 1 1 re f", resources: resources)])
        let path = try #require(PDFImportFixture.paths(try PDFImportFixture.importPDF(data).nodes).first)
        guard case .solid(let color) = path.fill else {
            Issue.record("expected a solid fill")
            return
        }
        #expect(abs(color.srgb.x - 1) < 0.01)
    }

    // MARK: SVG

    static func svg(_ body: String) -> Data {
        Data("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"100\" height=\"100\">\(body)</svg>".utf8)
    }

    @Test func svgElementsNestedPastTheLimitAreLeftOutOrRefused() throws {
        let data = Self.svg(String(repeating: "<g>", count: Self.levels) + "<rect width=\"5\" height=\"5\"/>" + String(repeating: "</g>", count: Self.levels) + "<rect width=\"9\" height=\"9\"/>")
        do {
            let scene = try Self.onSmallStack { try ImportRegistry.standard.convert(data, name: "deep.svg") }
            #expect(scene.notes.contains(ImportNesting.note))
            #expect(try Self.exercised(scene) <= SVGImportConverter.maximumDepth + 1)
        } catch let error as ImportError {
            #expect(error.description.contains("nested more than \(ImportNesting.limit) levels deep"))
        }
    }

    @Test func svgElementsJustPastTheLimitAreLeftOutWithANote() throws {
        let levels = SVGImportConverter.maximumDepth + 5
        let data = Self.svg(String(repeating: "<g>", count: levels) + "<rect width=\"5\" height=\"5\"/>text" + String(repeating: "</g>", count: levels) + "<rect width=\"9\" height=\"9\"/>")
        let scene = try Self.onSmallStack { try ImportRegistry.standard.convert(data, name: "deep.svg") }
        #expect(scene.notes.contains(ImportNesting.note))
        #expect(PDFImportFixture.paths(scene.nodes).count == 1)
        #expect(try Self.exercised(scene) <= SVGImportConverter.maximumDepth + 1)
        // Within the limit: the content is kept.
        let shallow = Self.svg(String(repeating: "<g>", count: 40) + "<rect width=\"5\" height=\"5\"/>" + String(repeating: "</g>", count: 40))
        let kept = try Self.onSmallStack { try ImportRegistry.standard.convert(shallow, name: "shallow.svg") }
        #expect(!kept.notes.contains(ImportNesting.note))
        #expect(PDFImportFixture.paths(kept.nodes).count == 1)
        // Past the parse limit: the deeper elements are dropped as they are read.
        let deeper = Self.svg(String(repeating: "<g>", count: ImportNesting.limit + 5) + "<rect width=\"5\" height=\"5\"/>text<![CDATA[x]]>" + String(repeating: "</g>", count: ImportNesting.limit + 5))
        let root = try Self.onSmallStack { try SVGImportTree.parse(deeper, name: "deeper.svg") }
        #expect(root.nestingTruncated)
        #expect(root.descendants.count == ImportNesting.limit)
        // Nesting in parts that are not converted (definitions) is noted from the parse.
        let defs = Self.svg("<defs>" + String(repeating: "<g>", count: ImportNesting.limit + 5) + String(repeating: "</g>", count: ImportNesting.limit + 5) + "</defs><rect width=\"9\" height=\"9\"/>")
        let noted = try Self.onSmallStack { try ImportRegistry.standard.convert(defs, name: "defs.svg") }
        #expect(noted.notes.contains(ImportNesting.note))
        #expect(PDFImportFixture.paths(noted.nodes).count == 1)
        // A file cut off deep inside is refused for its nesting.
        let cut = Self.svg(String(repeating: "<g>", count: ImportNesting.limit + 5)).dropLast(6)
        #expect(throws: ImportError.self) { try Self.onSmallStack { try SVGImportTree.parse(Data(cut), name: "cut.svg") } }
        do {
            _ = try SVGImportTree.parse(Data(cut), name: "cut.svg")
        } catch let error as ImportError {
            #expect(error.description.contains("nested more than \(ImportNesting.limit) levels deep"))
        }
    }

    @Test func svgUseChainsAreCutAtTheLimit() throws {
        var defs = ""
        for index in 0..<Self.levels {
            defs += "<g id=\"g\(index)\"><use xlink:href=\"#g\(index + 1)\"/></g>"
        }
        defs += "<rect id=\"g\(Self.levels)\" width=\"5\" height=\"5\"/>"
        let data = Self.svg("<defs>\(defs)</defs><use xlink:href=\"#g0\"/>")
        let scene = try Self.onSmallStack { try ImportRegistry.standard.convert(data, name: "chain.svg") }
        #expect(scene.notes.contains(ImportNesting.note))
        #expect(try Self.exercised(scene) <= SVGImportConverter.maximumDepth + 1)
    }

    @Test func svgSelectorsLongerThanTheLimitAreDropped() throws {
        let long = String(repeating: "g ", count: Self.levels) + "rect"
        #expect(SVGImportSelector(long) == nil)
        #expect(SVGImportSelector(String(repeating: "g ", count: ImportNesting.limit - 1) + "rect") != nil)
        let data = Self.svg("<style>\(long) { fill: red }</style><g><rect width=\"5\" height=\"5\"/></g>")
        let scene = try Self.onSmallStack { try ImportRegistry.standard.convert(data, name: "css.svg") }
        #expect(PDFImportFixture.paths(scene.nodes).count == 1)
    }

    // MARK: Trees

    @Test func theTreeWalksStayOffTheStack() throws {
        var node = ImportedNode.path(ImportedPath(contours: [], fill: .solid(.black)))
        for _ in 0..<ImportNesting.limit { node = .group(ImportedGroup(children: [node])) }
        let element = SVGImportElement(name: "svg", attributes: [:])
        var parent = element
        for _ in 0..<Self.levels {
            let child = SVGImportElement(name: "g", attributes: [:])
            parent.content.append(.element(child))
            parent = child
        }
        let count = try Self.onSmallStack { element.descendants.count }
        #expect(count == Self.levels + 1)
        #expect(try Self.exercised(ImportedScene(kind: .vector, name: "tree", bounds: Rect(x: 0, y: 0, width: 1, height: 1), nodes: [node])) == ImportNesting.limit + 1)
        // Release the element chain without recursion.
        while let next = element.children.first {
            element.content = next.content
            next.content = []
        }
    }
}
