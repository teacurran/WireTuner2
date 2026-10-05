// IO-041 (D-083): a FreeHand path's even/odd fill.  libfreehand reads the flag (bit 1 of the
// path's flag byte) but its path copy dropped it, so every path came in non-zero -- a ring
// drawn as two overlapping contours filled solid (patch 0004 in tools/freehand/patches keeps
// it).  A composite path takes its first path's rule, as libfreehand draws it.  The files are
// written byte by byte; no corpus content.

import Foundation
import Testing
import WTGeometry
@testable import WTInterchange

@Suite("FreeHand even/odd fill")
struct FreeHandEvenOddTests {
    static let outer = [(1.0, 1.0), (5.0, 1.0), (5.0, 5.0), (1.0, 5.0)]
    static let inner = [(2.0, 2.0), (4.0, 2.0), (4.0, 4.0), (2.0, 4.0)]

    /// A FreeHand `version` file: a filled square path of each fill rule, and a composite path
    /// of two squares whose paths are even/odd when `compositeEvenOdd`.
    static func file(version: Int, compositeEvenOdd: Bool = true) -> (data: Data, nonZero: Int, evenOdd: Int, composite: Int) {
        var file = FreeHandFileFixture(version: version)
        let fill = file.mName("fill")
        let color = version >= 9 ? file.spotColor6(name: file.mString("Ink"), rgb: [0, 0, 0]) : file.processColor(name: file.mString("Ink"), cmyk: [0, 0, 0, 1])
        let style = file.propList([(fill, file.basicFill(color: color))])
        let nonZero = file.path(outer, style: style)
        let evenOdd = file.path(outer, style: style, evenOdd: true)
        let parts = [outer, inner].map { file.path($0, style: style, evenOdd: compositeEvenOdd) }
        let composite = file.compositePath(elements: file.list(parts), style: style)
        let layer = file.layer(elements: file.list([nonZero, evenOdd, composite]), name: file.mString("Foreground"))
        file.block(layerList: file.list([layer]))
        return (file.data(), nonZero, evenOdd, composite)
    }

    static func paths(_ data: Data) throws -> [ImportedPath] {
        let scene = try FreeHandImporter().convert(data, name: "Ring.fh", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        return FreeHandNoneAndClosingTests.layerChildren(scene).compactMap(FreeHandNoneAndClosingTests.path)
    }

    @Test("A path's even/odd flag survives libfreehand and imports as the even/odd rule", arguments: [8, 10])
    func pathFlag(version: Int) throws {
        let (data, nonZero, evenOdd, _) = Self.file(version: version)
        let records = try FreeHandImporter.records(data, name: "Ring.fh")
        #expect(records.paths[nonZero]?.evenOdd == false)
        #expect(records.paths[evenOdd]?.evenOdd == true)
        let paths = try Self.paths(data)
        #expect(paths.count == 3)
        #expect(paths[0].fillRule == .nonZero && paths[1].fillRule == .evenOdd)
    }

    @Test("A composite path fills by its paths' rule")
    func compositeRule() throws {
        let evenOdd = try Self.paths(Self.file(version: 10).data)[2]
        #expect(evenOdd.contours.count == 2 && evenOdd.fillRule == .evenOdd)
        let nonZero = try Self.paths(Self.file(version: 10, compositeEvenOdd: false).data)[2]
        #expect(nonZero.contours.count == 2 && nonZero.fillRule == .nonZero)
    }
}
