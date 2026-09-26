import Foundation
@testable import WTRender

/// Writes small ICC v2 CMYK output profiles for the colour-management tests: macOS ships one
/// CMYK profile (Generic CMYK), and "changing Working CMYK changes the pixels" needs a second
/// press.  The press is the naive CMYK model with a dot-gain curve (`ink^gain`) on every ink,
/// characterized into Lab by `lut16Type` A2B0 and B2A0 tables.
enum ICCProfileBuilder {
    /// A press whose paper is slightly yellow (its media white point), which only absolute
    /// colorimetric -- paper-white simulation -- shows.
    static let paper = SIMD3(0.93, 0.97, 0.72)

    static func cmykProfile(name: String, dotGain: Double) -> Data {
        var tags: [(String, Data)] = []
        tags.append(("desc", textDescription(name)))
        tags.append(("cprt", text("No copyright, test data")))
        tags.append(("wtpt", xyz(paper)))
        tags.append(("A2B0", a2b(dotGain: dotGain)))
        tags.append(("B2A0", b2a(dotGain: dotGain)))
        var body = Data()
        var table = Data()
        table.append(u32(UInt32(tags.count)))
        let headerAndTable = 128 + 4 + 12 * tags.count
        for (signature, data) in tags {
            let offset = headerAndTable + body.count
            table.append(signature.data(using: .ascii)!)
            table.append(u32(UInt32(offset)))
            table.append(u32(UInt32(data.count)))
            body.append(data)
            while body.count % 4 != 0 { body.append(0) }
        }
        let size = headerAndTable + body.count
        var header = Data()
        header.append(u32(UInt32(size)))
        header.append(u32(0))
        header.append(u32(0x0210_0000))
        header.append("prtrCMYKLab ".data(using: .ascii)!)
        header.append(contentsOf: [0x07, 0xEA, 0, 9, 0, 23, 0, 0, 0, 0, 0, 0].map(UInt8.init))
        header.append("acspAPPL".data(using: .ascii)!)
        header.append(Data(count: 4 + 4 + 4 + 8 + 4))
        header.append(s15(WTColor.Math.d50White.x))
        header.append(s15(WTColor.Math.d50White.y))
        header.append(s15(WTColor.Math.d50White.z))
        header.append(Data(count: 128 - header.count))
        return header + table + body
    }

    static func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func s15(_ value: Double) -> Data { u32(UInt32(bitPattern: Int32((value * 65_536).rounded()))) }

    static func textDescription(_ text: String) -> Data {
        var data = "desc".data(using: .ascii)! + Data(count: 4)
        let ascii = text.data(using: .ascii)! + Data([0])
        data.append(u32(UInt32(ascii.count)))
        data.append(ascii)
        data.append(Data(count: 4 + 4 + 2 + 1 + 67))
        return data
    }

    static func text(_ text: String) -> Data {
        "text".data(using: .ascii)! + Data(count: 4) + text.data(using: .ascii)! + Data([0])
    }

    static func xyz(_ value: SIMD3<Double>) -> Data {
        "XYZ ".data(using: .ascii)! + Data(count: 4) + s15(value.x) + s15(value.y) + s15(value.z)
    }

    static func lut16(inputs: Int, outputs: Int, grid: Int, clut: [Double]) -> Data {
        var data = "mft2".data(using: .ascii)! + Data(count: 4)
        data.append(contentsOf: [UInt8(inputs), UInt8(outputs), UInt8(grid), 0])
        for row in 0..<3 {
            for column in 0..<3 { data.append(s15(row == column ? 1 : 0)) }
        }
        data.append(u16(2))
        data.append(u16(2))
        for _ in 0..<inputs { data.append(u16(0)); data.append(u16(0xFFFF)) }
        for value in clut { data.append(u16(UInt16(min(max(value, 0), 1) * 65_535 + 0.5))) }
        for _ in 0..<outputs { data.append(u16(0)); data.append(u16(0xFFFF)) }
        return data
    }

    /// Lab in the v2 16-bit encoding, as fractions of 65535.
    static func encodeLab(_ lab: SIMD3<Double>) -> [Double] {
        [lab.x / 100 * 65_280 / 65_535, (lab.y + 128) * 256 / 65_535, (lab.z + 128) * 256 / 65_535]
    }

    static func a2b(dotGain: Double) -> Data {
        let grid = 9
        var clut: [Double] = []
        for c in 0..<grid { for m in 0..<grid { for y in 0..<grid { for k in 0..<grid {
            let inks = SIMD4(Double(c), Double(m), Double(y), Double(k)) / Double(grid - 1)
            let gained = SIMD4(pow(inks.x, dotGain), pow(inks.y, dotGain), pow(inks.z, dotGain), pow(inks.w, dotGain))
            let lab = Color(space: .cmyk, components: gained).converted(to: .lab)
            clut += encodeLab(SIMD3(lab.components.x, lab.components.y, lab.components.z))
        } } } }
        return lut16(inputs: 4, outputs: 3, grid: grid, clut: clut)
    }

    static func b2a(dotGain: Double) -> Data {
        let grid = 17
        var clut: [Double] = []
        for l in 0..<grid { for a in 0..<grid { for b in 0..<grid {
            let lab = SIMD3(Double(l) / Double(grid - 1) * 100 * 65_535 / 65_280, Double(a) / Double(grid - 1) * 65_535 / 256 - 128, Double(b) / Double(grid - 1) * 65_535 / 256 - 128)
            let rgb = WTColor.Math.clipped(Color(labL: lab.x, a: lab.y, b: lab.z).converted(to: .sRGB).srgb)
            let inks = WTColor.Math.naiveCMYK(fromSRGB: rgb)
            clut += [pow(inks.x, 1 / dotGain), pow(inks.y, 1 / dotGain), pow(inks.z, 1 / dotGain), pow(inks.w, 1 / dotGain)]
        } } }
        return lut16(inputs: 3, outputs: 4, grid: grid, clut: clut)
    }
}
