import Testing
@testable import WTModel

/// OBJ-001: every unit, the pica-point form, arithmetic, percent of the current value, whitespace,
/// negatives, rejection with the caret position, rounding to 1/1000 pt, and formatting back.
@Suite struct MeasureTests {
    @Test func everyUnitConvertsToPoints() throws {
        #expect(try Measure.parse("12pt") == 12)
        #expect(try Measure.parse("12 px") == 12)
        #expect(try Measure.parse("2p") == 24)
        #expect(try Measure.parse("2pc") == 24)
        #expect(try Measure.parse("0.5in") == 36)
        #expect(try Measure.parse("25.4mm") == 72)
        #expect(try Measure.parse("2.54cm") == 72)
        #expect(try Measure.parse("2p6") == 30)
        #expect(try Measure.parse("2p6.5") == 30.5)
        #expect(try Measure.parse("1IN") == 72)
    }

    @Test func bareNumbersAreInTheDocumentUnit() throws {
        #expect(try Measure.parse("1", unit: .inches) == 72)
        #expect(try Measure.parse("1", unit: .decimalInches) == 72)
        #expect(try Measure.parse("10", unit: .millimeters) == Measure.rounded(10 * 72 / 25.4))
        #expect(try Measure.parse("1", unit: .picas) == 12)
        #expect(try Measure.parse("1", unit: .centimeters) == Measure.rounded(72 / 2.54))
        #expect(try Measure.parse("3", unit: .pixels) == 3)
        // Arithmetic is in the document unit: 2 in × 3 = 6 in.
        #expect(try Measure.parse("2in*3", unit: .inches) == 432)
        #expect(try Measure.parse("12pt + 1", unit: .inches) == 84)
    }

    @Test func arithmeticAndPercent() throws {
        #expect(try Measure.parse("10+4") == 14)
        #expect(try Measure.parse("100/3") == 33.333)
        #expect(try Measure.parse("72*1.5") == 108)
        #expect(try Measure.parse("10 - 4 - 3") == 3)
        #expect(try Measure.parse("2*(3+4)") == 14)
        #expect(try Measure.parse("50%", current: 30) == 15)
        #expect(try Measure.parse("50% + 1", current: 30) == 16)
        #expect(try Measure.parse("  -12  ") == -12)
        #expect(try Measure.parse("+5") == 5)
        #expect(try Measure.parse("-(2+3)") == -5)
        #expect(try Measure.parse(".5") == 0.5)
    }

    @Test func malformedInputNamesTheCaret() {
        func failure(_ text: String) -> MeasureError? {
            do {
                _ = try Measure.parse(text)
                return nil
            } catch {
                return error
            }
        }
        #expect(failure("")?.position == 0)
        #expect(failure("12 qq")?.position == 3)
        #expect(failure("10+")?.position == 3)
        #expect(failure("(1+2")?.position == 4)
        #expect(failure("4/0")?.position == 1)
        #expect(failure("1 2")?.position == 2)
        #expect(failure(".")?.position == 0)
        #expect(failure("abc")?.position == 0)
        #expect(failure(String(repeating: "9", count: 400))?.message == "Not a number")
        #expect(failure("12 qq")?.message == "Unknown unit “qq”")
    }

    @Test func roundingAndFormatting() {
        #expect(Measure.rounded(1.23456) == 1.235)
        #expect(Measure.format(12, unit: .points) == "12 pt")
        #expect(Measure.format(36, unit: .inches) == "0.5 in")
        #expect(Measure.format(72, unit: .millimeters) == "25.4 mm")
        #expect(Measure.format(30, unit: .picas) == "2p6")
        #expect(Measure.format(-30, unit: .picas) == "-2p6")
        #expect(Measure.format(12, unit: .points, suffix: false) == "12")
        #expect(Measure.format(1.0 / 3.0, unit: .points, suffix: false) == "0.333")
        #expect(Measure.format(0.5, unit: .points, suffix: false) == "0.5")
        #expect(MeasureUnit.allCases.map(\.suffix) == ["pt", "p", "in", "in", "mm", "cm", "px"])
    }
}
