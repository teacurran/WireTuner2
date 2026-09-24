import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// DOC-003: field entry and display in document units (document-panel.adoc, "Typing values in
/// another unit", "Arithmetic in fields"; "Client" for the display precisions).
@Suite struct UnitsTests {
    static let agate = CustomUnit(id: OpID(counter: 7, replica: 1), name: "agate", amount: 5.25, base: .points)

    static func close(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        a.map { abs($0 - b) <= tolerance } ?? false
    }

    static let parseCases: [(String, LengthUnit, Double)] = [
        ("7p", LengthUnit.points, 84.0),
        ("7p6", .points, 90.0),
        ("p6", .points, 6.0),
        ("2i + 3p", .points, 180.0),
        ("2in+3p", .points, 180.0),
        ("4*50-49", .points, 151.0),
        ("4*50-49", .inches, 151.0 * 72),
        ("125m", .points, 125 * 72 / 25.4),
        ("125 mm", .points, 125 * 72 / 25.4),
        ("1c", .points, 720 / 25.4),
        ("2cm", .points, 1440 / 25.4),
        ("4q", .points, 72 / 25.4),
        ("10x", .points, 10),
        ("10px", .points, 10),
        ("12pt", .inches, 12),
        ("12", .picas, 144),
        ("-3", .points, -3),
        ("-(2 + 1)", .points, -3),
        ("(1 + 2) * 3", .points, 9),
        ("2i * 3", .points, 432),
        ("3 * 2i", .points, 432),
        ("6i / 2", .points, 216),
        ("6i / 2i", .points, 3),
        ("10 / 4", .points, 2.5),
        ("1 - 1i", .points, 1 - 72),
        ("1.5", .millimeters, 1.5 * 72 / 25.4),
        (".5i", .points, 36),
        ("1PT", .points, 1),
        ("+2", .points, 2),
    ]

    @Test(arguments: parseCases)
    func parses(text: String, unit: LengthUnit, points: Double) {
        let units = Units(documentUnit: unit, customUnits: [Self.agate])
        #expect(Self.close(units.parse(text), points), "\(text) in \(unit)")
    }

    @Test func customUnitsByNameAndDuplicates() {
        let later = CustomUnit(id: OpID(counter: 9, replica: 1), name: "Agate", amount: 100, base: .points)
        let units = Units(documentUnit: .points, customUnits: [later, Self.agate])
        #expect(Self.close(units.parse("2 agate"), 10.5))
        #expect(Self.close(units.parse("2AGATE"), 10.5))
        #expect(units.custom(named: "agate")?.id == Self.agate.id)
        // A custom unit longer than a built-in suffix wins; a shorter one does not shadow it.
        let pica = CustomUnit(id: OpID(counter: 3, replica: 2), name: "pica2", amount: 2, base: .picas)
        let short = CustomUnit(id: OpID(counter: 4, replica: 2), name: "i", amount: 2, base: .points)
        let mixed = Units(documentUnit: .points, customUnits: [pica, short])
        #expect(Self.close(mixed.parse("1pica2"), 24))
        #expect(Self.close(mixed.parse("1i"), 72))
        // A custom unit in a custom unit's base reads as points; a bad amount as one point.
        #expect(CustomUnit(id: .zero, name: "x", amount: 2, base: .custom(Self.agate.id)).base == .points)
        #expect(CustomUnit(id: .zero, name: "x", amount: -1, base: .inches).pointsPerUnit == 1)
        // The document unit may be a custom one.
        let inAgates = Units(documentUnit: .custom(Self.agate.id), customUnits: [Self.agate])
        #expect(Self.close(inAgates.parse("2"), 10.5))
        #expect(inAgates.format(10.5, suffix: true) == "2 agate")
        #expect(inAgates.name(of: .custom(Self.agate.id)) == "agate")
        #expect(Units().name(of: .custom(Self.agate.id)) == "Custom")
        #expect(Units().suffix(of: .custom(Self.agate.id)) == "pt")
        #expect(Units().pointsPerUnit(.custom(Self.agate.id)) == 1)
    }

    @Test(arguments: ["", "abc", "3pts", "1 +", "2i * 3i", "1 / 0", "(1", "1)", "--", "1..2", "p", "7p6p", "*2", "2 2"])
    func rejects(text: String) {
        #expect(Units(customUnits: [Self.agate]).parse(text) == nil, "\(text)")
    }

    @Test func formatsAtDisplayPrecision() {
        let units = Units()
        #expect(units.format(12.345) == "12.35")
        #expect(units.format(12, suffix: true) == "12 pt")
        #expect(units.format(90, in: .picas) == "7p6")
        #expect(units.format(-90, in: .picas) == "-7p6")
        #expect(units.format(11.999, in: .picas) == "1p0")
        #expect(units.format(0.001, in: .picas) == "0p0")
        #expect(units.format(72, in: .inches, suffix: true) == "1 in")
        #expect(units.format(100, in: .inches) == "1.3889")
        #expect(units.format(100, in: .decimalInches) == "1.389")
        #expect(units.format(100, in: .millimeters) == "35.28")
        #expect(units.format(100, in: .centimeters) == "3.528")
        #expect(units.format(100, in: .kyus) == "141.1")
        #expect(units.format(-0.001) == "0")
        #expect(units.format(.nan) == "0")
        #expect(units.format(3, in: .pixels, suffix: true) == "3 px")
    }

    @Test func formatThenParseIsIdentityAtDisplayPrecision() {
        let units = Units(documentUnit: .points, customUnits: [Self.agate])
        let values: [Double] = [0, 0.004, 1, 12.345, 90.5, 100, 612, 791.99, 1234.5678, -45.67]
        for unit in LengthUnit.standard + [.custom(Self.agate.id)] {
            var inUnit = units
            inUnit.documentUnit = unit
            for value in values {
                let shown = inUnit.format(value)
                let parsed = inUnit.parse(shown)
                #expect(Self.close(parsed, inUnit.rounded(value), 1e-6), "\(value) in \(unit): \(shown)")
                // Formatting the parsed value shows the same text.
                #expect(parsed.map { inUnit.format($0) } == shown)
            }
        }
    }

    @Test func conversionTableAndStoredValues() {
        let units = Units(customUnits: [Self.agate])
        #expect(Self.close(units.convert(1, from: .inches, to: .millimeters), 25.4))
        #expect(Self.close(units.convert(1, from: .centimeters, to: .kyus), 40))
        #expect(Self.close(units.convert(1, from: .picas, to: .points), 12))
        #expect(Self.close(units.convert(2, from: .custom(Self.agate.id), to: .points), 10.5))
        for unit in LengthUnit.standard {
            #expect(LengthUnit(builtIn: unit.stored) == unit)
            #expect(!unit.name.isEmpty && !unit.abbreviation.isEmpty)
            #expect(unit.choice.unit == unit.stored)
        }
        #expect(LengthUnit(builtIn: .unspecified) == .points)
        #expect(LengthUnit(builtIn: .custom) == .points)
        #expect(LengthUnit.custom(Self.agate.id).name == "Custom")
        #expect(LengthUnit.custom(Self.agate.id).abbreviation.isEmpty)
        #expect(LengthUnit.custom(Self.agate.id).pointsPerUnit == nil)
        #expect(LengthUnit.custom(Self.agate.id).stored == .custom)
        #expect(OpID(element: LengthUnit.custom(Self.agate.id).choice.custom) == Self.agate.id)
    }
}
