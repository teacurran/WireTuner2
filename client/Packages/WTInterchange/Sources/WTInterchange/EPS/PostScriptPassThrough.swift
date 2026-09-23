// Placed EPS files in EPS exports (import-formats.adoc, "EPS"; export-vector.adoc, "Client"; the
// IO-018 follow-up IMG-011 named): the placed file's PostScript is written verbatim, bracketed by
// `%%BeginDocument` / `%%EndDocument` and the usual inclusion protocol -- the graphics state and
// the dictionary and operand stacks saved and restored around it, `showpage` disabled, the
// default graphics state set -- under a matrix mapping its bounding box onto the placed bounds.
// The export's private operator dictionary is ended first so the placed program sees only
// `userdict` and `systemdict` as it would on its own.  A DOS EPS binary header's preview is
// dropped; only its PostScript section is written.

import Foundation
import WTGeometry

extension EPSBuild {
    /// The PostScript section of a placed file: the DOS binary header's PostScript range when
    /// the file has one, otherwise the whole file.
    static func postScriptSection(_ data: Data) -> Data {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count == 12, bytes[0..<4] == [0xC5, 0xD0, 0xD3, 0xC6] else {
            return data
        }
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        let start = word(4), length = word(8)
        guard start >= 0, length >= 0, start + length <= data.count else {
            return data
        }
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + length))
    }

    /// Writes `postScript` in place of its preview.
    func writePostScript(_ postScript: ExportPostScript, name: String) {
        let program = EPSBuild.postScriptSection(postScript.data)
        if program.contains(where: { $0 >= 0x80 || ($0 < 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09) }) {
            binaryData = true
        }
        let box = postScript.boundingBox
        let bounds = postScript.bounds
        let sx = box.width > 0 ? bounds.width / box.width : 1
        let sy = box.height > 0 ? bounds.height / box.height : 1
        // PostScript points (y up) → the placed bounds (local, y down) → pasteboard.
        let placement = AffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: bounds.minX - box.minX * sx, ty: bounds.maxY + box.minY * sy).concatenating(postScript.transform)
        content.op("q")
        content.transform(placement)
        content.op("end")
        content.op("/WTIncludeState save def /WTDictCount countdictstack def /WTOperandCount count 1 sub def")
        content.op("userdict begin /showpage {} def")
        content.op("0 setgray 0 setlinecap 1 setlinewidth 0 setlinejoin 10 setmiterlimit [] 0 setdash newpath")
        content.op("/languagelevel where {pop languagelevel 1 ne {false setstrokeadjust false setoverprint} if} if")
        content.op("%%BeginDocument: \(EPSBuild.dscText(name))")
        content.raw(program)
        content.op("%%EndDocument")
        content.op("count WTOperandCount sub {pop} repeat countdictstack WTDictCount sub {end} repeat WTIncludeState restore")
        content.op("WTDict begin")
        content.op("Q")
    }
}
