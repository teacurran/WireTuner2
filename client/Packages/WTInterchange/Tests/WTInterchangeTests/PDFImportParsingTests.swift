// IMG-009 and IMG-010: the PostScript-syntax lexer and parser, PDF functions (sampled,
// exponential, stitching, calculator), object access and the scene tree's grouping rules.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct PDFImportParsingTests {
    static func tokens(_ text: String, comments: Bool = false) -> [PDFImportToken] {
        var lexer = PDFImportLexer(Data(text.utf8), keepComments: comments)
        var result: [PDFImportToken] = []
        while let token = lexer.next() {
            result.append(token)
        }
        return result
    }

    @Test func lexerReadsEveryTokenKind() {
        let text = "12 -3.5 .5 4. +7 1.2.3 - /Name /A#20B /#zz (a\\(b\\)\\n\\r\\t\\b\\f\\\\\\101\\7x\\\ny) (nest (inner)) <48 65 6> <<>> [ ] { } % comment\n)stray > word"
        let tokens = Self.tokens(text)
        #expect(tokens == [
            .number(12), .number(-3.5), .number(0.5), .number(4), .number(7), .keyword("1.2.3"), .keyword("-"),
            .name("Name"), .name("A B"), .name("#zz"),
            .string(Data("a(b)\n\r\t\u{8}\u{C}\\A\u{7}xy".utf8)), .string(Data("nest (inner)".utf8)), .string(Data([0x48, 0x65, 0x60])),
            .dictOpen, .dictClose, .arrayOpen, .arrayClose, .procOpen, .procClose, .keyword(")"), .keyword("stray"), .dictClose, .keyword("word"),
        ])
        #expect(Self.tokens("%a\r%b", comments: true) == [.comment("a"), .comment("b")])
        #expect(Self.tokens("(\\\r\nx) (\\") == [.string(Data("x".utf8)), .string(Data())])
        #expect(Self.tokens("(open") == [.string(Data("open".utf8))])
        #expect(Self.tokens("<4") == [.string(Data([0x40]))])
        #expect(PDFImportLexer.number("") == nil)
        #expect(PDFImportLexer.number("..") == nil)
        #expect(PDFImportLexer.number("1-") == nil)
    }

    @Test func parserBuildsOperands() {
        var parser = PDFImportParser(Data("true false null [1 /a (s) [2]] << /K 1 /L [3] 4 5 >> { 1 add } word".utf8), keepComments: true)
        var items: [PDFImportParser.Item] = []
        while let item = parser.next() {
            items.append(item)
        }
        #expect(items == [
            .operand(.bool(true)), .operand(.bool(false)), .operand(.null),
            .operand(.array([.number(1), .name("a"), .string(Data("s".utf8)), .array([.number(2)])])),
            .operand(.dict(["K": .number(1), "L": .array([.number(3)])])),
            .operand(.proc([.number(1), .keyword("add")])), .op("word"),
        ])
        var nested = PDFImportParser(Data("[true false null ] %c\n x] { } >> ]".utf8))
        #expect(nested.next() == .operand(.array([.bool(true), .bool(false), .null])))
        var inner = PDFImportParser(Data("[ %c\n 1 ]".utf8), keepComments: true)
        #expect(inner.next() == .operand(.array([.number(1)])))
        var closers = PDFImportParser(Data("[ ] ".utf8))
        #expect(closers.next() == .operand(.array([])))
        var stray = PDFImportParser(Data("{ ] >> } ".utf8))
        #expect(stray.next() == .operand(.proc([.null, .null])))
        let comment = PDFImportParser(Data("% x\n".utf8), keepComments: true)
        var copy = comment
        #expect(copy.next() == .comment(" x"))
        var operators: [String] = []
        var all = PDFImportParser(Data("1 2 m % c\n BI /W 1 ID xy EI".utf8))
        all.forEachOperator { op, operands in operators.append("\(op):\(operands.count)") }
        #expect(operators == ["m:2", "BI:0", "ID:3"])
        var unterminated = PDFImportParser(Data("BI ID abc".utf8))
        var data: Data?
        unterminated.forEachOperator { op, operands in if op == "ID" { data = operands.last?.string } }
        #expect(data == Data("abc".utf8))
        #expect(PDFImportOperand.text(Data([0xFE, 0xFF, 0, 0x41])) == "A")
        #expect(PDFImportOperand.text(Data([0xE9])) == "é")
        #expect(PDFImportOperand.number(1).name == nil && PDFImportOperand.name("a").number == nil)
        #expect(PDFImportOperand.null.string == nil && PDFImportOperand.null.array == nil && PDFImportOperand.null.dict == nil)
    }

    // MARK: Functions

    @Test func functionsEvaluate() {
        let exponential = PDFImportFunction.exponential(domain: [0, 1], c0: [0, 1], c1: [1, 0], exponent: 2)
        #expect(exponential.evaluate([0.5]) == [0.25, 0.75])
        #expect(exponential.evaluate([]) == [0, 1])
        let stitching = PDFImportFunction.stitching(domain: [0, 1], functions: [exponential, .exponential(domain: [0, 1], c0: [1], c1: [0], exponent: 1)], bounds: [0.5], encode: [0, 1])
        #expect(stitching.evaluate([0.25]) == [0.25, 0.75])
        #expect(stitching.evaluate([0.75]) == [0.5])
        #expect(stitching.evaluate([2]) == [0])
        let sampled8 = PDFImportFunction.sampled(domain: [0, 1], range: [0, 1], size: [3], bitsPerSample: 8, encode: [0, 2], decode: [0, 1], samples: [0, 255, 0])
        #expect(sampled8.evaluate([0.25]) == [0.5])
        #expect(sampled8.evaluate([1]) == [0])
        let sampled16 = PDFImportFunction.sampled(domain: [0, 1], range: [0, 1], size: [2], bitsPerSample: 16, encode: [0, 1], decode: [0, 1], samples: [0xFF, 0xFF, 0, 0])
        #expect(sampled16.evaluate([0]) == [1])
        let grid = PDFImportFunction.sampled(domain: [0, 1, 0, 1], range: [0, 1], size: [2, 2], bitsPerSample: 8, encode: [0, 1, 0, 1], decode: [0, 1], samples: [0, 51, 102, 255])
        #expect(grid.evaluate([1, 1]) == [1])
        #expect(grid.evaluate([1]) == [0.2])
        #expect(PDFImportBits.read([0xF0], index: 3, bits: 4) == 0)
        let array = PDFImportFunction.array([exponential, sampled8])
        #expect(array.evaluate([0.5]) == [0.25, 1])
        let calculator = PDFImportFunction.calculator(domain: [0, 1], range: [0, 1, 0, 10], program: [.keyword("dup"), .number(10), .keyword("mul")])
        #expect(calculator.evaluate([2]) == [1, 10])
    }

    static func run(_ program: String, _ inputs: [Double] = []) -> [PDFImportOperand] {
        var parser = PDFImportParser(Data("{ \(program) }".utf8))
        guard case .operand(.proc(let body))? = parser.next() else { return [] }
        var stack = inputs.map(PDFImportOperand.number)
        PDFImportCalculator.run(body, stack: &stack)
        return stack
    }

    @Test func calculatorOperators() {
        let cases: [(String, [Double])] = [
            ("1 2 add", [3]), ("5 2 sub", [3]), ("2 3 mul", [6]), ("6 3 div", [2]), ("1 0 div", [0]),
            ("7 2 idiv", [3]), ("7 0 idiv", [0]), ("7 3 mod", [1]), ("7 0 mod", [0]), ("2 neg", [-2]), ("-2 abs", [2]),
            ("16 sqrt", [4]), ("2 3 exp", [8]), ("1 ln", [0]), ("100 log", [2]), ("90 sin", [1]), ("0 cos", [1]),
            ("0 -1 atan", [180]), ("-1 0 atan", [270]), ("1.5 floor", [1]), ("1.5 ceiling", [2]), ("1.5 round", [2]), ("-1.5 truncate", [-1]),
            ("1.7 cvi", [1]), ("2 cvr", [2]), ("1 dup", [1, 1]), ("1 2 pop", [1]), ("1 2 exch", [2, 1]), ("1 2 2 copy", [1, 2, 1, 2]),
            ("1 2 1 index", [1, 2, 1]), ("1 2 3 3 1 roll", [3, 1, 2]), ("12 10 and", [8]), ("12 10 or", [14]), ("12 10 xor", [6]),
            ("0 not", [-1]), ("1 5 copy", [1]), ("1 9 index", [1]), ("1 2 5 1 roll", [1, 2]), ("frobnicate", []), ("1", [1]),
        ]
        for (program, expected) in cases {
            #expect(Self.run(program).map { $0.number ?? .nan } == expected, "\(program)")
        }
        let booleans: [(String, Bool)] = [
            ("1 1 eq", true), ("1 2 ne", true), ("2 1 gt", true), ("1 1 ge", true), ("1 2 lt", true), ("2 2 le", true),
            ("true false and", false), ("true false or", true), ("true true xor", false), ("true not", false), ("/a /a eq", true), ("/a /b ne", true),
        ]
        for (program, expected) in booleans {
            #expect(Self.run(program) == [.bool(expected)], "\(program)")
        }
        #expect(Self.run("true { 1 } if") == [.number(1)])
        #expect(Self.run("false { 1 } if") == [])
        #expect(Self.run("false { 1 } { 2 } ifelse") == [.number(2)])
        #expect(Self.run("true false") == [.bool(true), .bool(false)])
        #expect(Self.run("1 if") == [])
        #expect(Self.run("1 ifelse") == [])
        #expect(Self.run("add") == [.number(0)])
        #expect(Self.run("dup exch") == [])
    }

    @Test func functionDictionariesParse() throws {
        var f = PDFImportFixture()
        let sampled = f.stream("/FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2] /BitsPerSample 8", Data([0, 255]))
        let badSampled = f.stream("/FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2 2]", Data([0]))
        let noSize = f.stream("/FunctionType 0 /Range [0 1]", Data([0]))
        let calculator = f.stream("/FunctionType 4 /Domain [0 1] /Range [0 1]", "{ 1 exch sub }")
        let noProgram = f.stream("/FunctionType 4 /Domain [0 1] /Range [0 1]", "1 2")
        let noRange = f.stream("/FunctionType 4 /Domain [0 1]", "{ }")
        let resources = """
        << /A \(sampled) 0 R /B \(badSampled) 0 R /C \(noSize) 0 R /D \(calculator) 0 R /E \(noProgram) 0 R /F \(noRange) 0 R \
        /G << /FunctionType 3 /Functions [] >> /H << /FunctionType 3 /Domain [0] /Functions [<< /FunctionType 2 >>] >> /I << /FunctionType 7 >> \
        /J [] /K [<< /FunctionType 2 /C0 [0] /C1 [1] >>] /L 5 /M << /FunctionType 2 /Domain [0 1] >> >>
        """
        let data = f.document([.init("", resources: resources)])
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let dict = PDFImportDict(ref: document.page(at: 1)!.dictionary!).dict("Resources")!
        func parse(_ key: String) -> PDFImportFunction? { dict[key].flatMap(PDFImportFunction.parse) }
        #expect(parse("A")?.evaluate([0.5]) == [0.5])
        #expect(parse("B") == nil && parse("C") == nil)
        #expect(parse("D")?.evaluate([0.25]) == [0.75])
        #expect(parse("E") == nil && parse("F") == nil && parse("G") == nil && parse("I") == nil && parse("J") == nil && parse("L") == nil)
        #expect(parse("H")?.evaluate([0.5]) == [0.5])
        #expect(parse("K")?.evaluate([0.5]) == [0.5])
        #expect(parse("M")?.evaluate([1]) == [1])
        // Object access.
        #expect(dict.keys.first == "A")
        #expect(dict.bool("A") == nil)
        #expect(dict.string("A") == nil)
        #expect(dict.text("A") == nil)
        #expect(dict["Q"] == nil)
        let operand = PDFImportValue.dict(dict).operand
        #expect(operand.dict?["L"] == .number(5))
        #expect(operand.dict?["A"] == .null)
        #expect(PDFImportValue.bool(true).operand == .bool(true))
        #expect(PDFImportValue.string(Data([1])).operand == .string(Data([1])))
        #expect(PDFImportValue.null.name == nil && PDFImportValue.null.dict == nil && PDFImportValue.null.stream == nil && PDFImportValue.null.string == nil)
        #expect(dict.array("J")?[5] == nil)
    }

    @Test func colourSpaceEdges() {
        #expect(PDFImportColorSpace.named("Nope", resources: nil) == nil)
        #expect(PDFImportColorSpace.pattern.color([1]) == nil)
        #expect(PDFImportColorSpace.pattern.initial == [0])
        #expect(PDFImportColorSpace.cmyk.initial == [0, 0, 0, 1])
        #expect(PDFImportColorSpace.lab(range: [10, 20, -5, 5]).initial == [0, 10, 0])
        #expect(PDFImportColorSpace.deviceN(names: ["A", "B"], alternate: .rgb, tint: nil).initial == [1, 1])
        #expect(PDFImportColorSpace.indexed(base: .rgb, high: 3, lookup: []).color([2]) == Color(red: 0, green: 0, blue: 0))
        #expect(PDFImportColorSpace.separation(name: "S", alternate: .gray, tint: nil).color([0.25]) == Color(white: 0.75))
        #expect(PDFImportColorSpace.parse(.number(1), resources: nil) == nil)
    }

    // MARK: The scene tree

    @Test func treeJoinsRunsAndNestsScopes() {
        let session = PDFImportSession(name: "t", text: .editable, meshBlack: 0.1)
        let tree = PDFImportTree()
        let clip = session.scope(.clip(ImportedPath(contours: [])))
        let layer = session.scope(.layer("L"))
        let run = ImportedTextRun(text: "a", fontName: "Helvetica", fontSize: 10, origin: Point(x: 0, y: 10))
        var next = run
        next.origin.x = 20
        var below = run
        below.origin.y = 30
        tree.emitText(run, transform: .identity, scopes: [clip])
        tree.emitText(next, transform: .identity, scopes: [clip])
        tree.emitText(below, transform: .identity, scopes: [clip])
        tree.emitText(below, transform: .translation(x: 1, y: 0), scopes: [clip])
        tree.emitText(run, transform: .identity, scopes: [clip, layer])
        tree.emit(.path(ImportedPath(contours: [])), scopes: [])
        tree.flushText()
        let nodes = tree.finish()
        #expect(nodes.count == 2)
        guard case .group(let group) = nodes[0] else {
            Issue.record("clip group")
            return
        }
        #expect(PDFImportFixture.texts(group.children).map(\.runs.count) == [2, 1, 1, 1])
        session.note("x")
        session.note("x")
        #expect(session.notes == ["x"])
    }
}
