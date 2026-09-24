// FONT-025: reading CFF outlines (Adobe Technical Notes #5176 and #5177): the INDEXes, the Top and
// Private DICTs, the charset (formats 0-2 and ISOAdobe) and a Type 2 charstring interpreter with
// local and global subroutines, hint operators skipped.  CID-keyed fonts are refused.

import Foundation
import WTGeometry

struct CFFReader {
    var contours: [[Contour]]
    /// Glyph names from the charset, nil when the charset is predefined other than ISOAdobe.
    var names: [String]?

    /// The byte ranges of an INDEX at `offset` and the offset after it.
    static func index(_ data: FontReader, at offset: Int) throws -> (items: [Range<Int>], end: Int) {
        let count = try data.u16(offset)
        guard count > 0 else { return ([], offset + 2) }
        let size = try data.u8(offset + 2)
        guard (1...4).contains(size) else { throw FontReadError.malformed("CFF INDEX") }
        func read(_ index: Int) throws -> Int {
            let at = offset + 3 + index * size
            var value = 0
            for byte in 0..<size { value = value << 8 | (try data.u8(at + byte)) }
            return value
        }
        let base = offset + 2 + (count + 1) * size
        var items: [Range<Int>] = []
        for index in 0..<count {
            let start = base + (try read(index)), end = base + (try read(index + 1))
            guard start <= end else { throw FontReadError.malformed("CFF INDEX") }
            items.append(start..<end)
        }
        let end = base + (try read(count))
        try data.check(offset, end - offset)
        return (items, end)
    }

    /// A DICT: operator (12 x as 1200 + x) → operands.
    static func dict(_ bytes: [UInt8]) throws -> [Int: [Double]] {
        var result: [Int: [Double]] = [:]
        var operands: [Double] = []
        var index = 0
        while index < bytes.count {
            let b0 = Int(bytes[index])
            switch b0 {
            case 0...21:
                var op = b0
                if b0 == 12 {
                    guard index + 1 < bytes.count else { throw FontReadError.truncated("CFF DICT") }
                    op = 1_200 + Int(bytes[index + 1])
                    index += 1
                }
                result[op] = operands
                operands = []
                index += 1
            case 28, 29:
                let length = b0 == 28 ? 2 : 4
                guard index + length < bytes.count else { throw FontReadError.truncated("CFF DICT") }
                let value = bytes[(index + 1)...(index + length)].reduce(0) { $0 << 8 | Int($1) }
                operands.append(Double(length == 2 ? Int(Int16(truncatingIfNeeded: value)) : Int(Int32(truncatingIfNeeded: value))))
                index += 1 + length
            case 30:
                var text = ""
                index += 1
                parsing: while index < bytes.count {
                    for nibble in [bytes[index] >> 4, bytes[index] & 0x0F] {
                        switch nibble {
                        case 0...9: text += String(nibble)
                        case 0xA: text += "."
                        case 0xB: text += "E"
                        case 0xC: text += "E-"
                        case 0xE: text += "-"
                        case 0xF:
                            index += 1
                            break parsing
                        default: break
                        }
                    }
                    index += 1
                }
                operands.append(Double(text) ?? 0)
            case 32...246:
                operands.append(Double(b0 - 139))
                index += 1
            case 247...254:
                guard index + 1 < bytes.count else { throw FontReadError.truncated("CFF DICT") }
                let b1 = Int(bytes[index + 1])
                operands.append(Double(b0 <= 250 ? (b0 - 247) * 256 + b1 + 108 : -(b0 - 251) * 256 - b1 - 108))
                index += 2
            default:
                throw FontReadError.malformed("CFF DICT")
            }
        }
        return result
    }

    init(_ data: FontReader, glyphCount: Int) throws {
        let headerSize = try data.u8(2)
        let nameIndex = try Self.index(data, at: headerSize)
        let topIndex = try Self.index(data, at: nameIndex.end)
        guard let topRange = topIndex.items.first else { throw FontReadError.malformed("CFF Top DICT") }
        let top = try Self.dict(try data.slice(topRange.lowerBound, topRange.count))
        if top[1_230] != nil { throw FontReadError.unsupported("CID-keyed CFF") }
        let stringIndex = try Self.index(data, at: topIndex.end)
        let globalIndex = try Self.index(data, at: stringIndex.end)
        guard let charstringsOffset = top[17]?.first else { throw FontReadError.malformed("CFF CharStrings") }
        let charstrings = try Self.index(data, at: Int(charstringsOffset)).items
        var locals: [Range<Int>] = []
        if let privateEntry = top[18], privateEntry.count == 2 {
            let size = Int(privateEntry[0]), offset = Int(privateEntry[1])
            let privateDict = try Self.dict(try data.slice(offset, size))
            if let subrs = privateDict[19]?.first { locals = try Self.index(data, at: offset + Int(subrs)).items }
        }
        let strings = try stringIndex.items.map { String(decoding: try data.slice($0.lowerBound, $0.count), as: UTF8.self) }
        func name(_ sid: Int) -> String {
            sid < CFFWriter.standardStrings.count ? CFFWriter.standardStrings[sid] : (sid - CFFWriter.standardStrings.count < strings.count ? strings[sid - CFFWriter.standardStrings.count] : "glyph\(sid)")
        }
        // Charset.
        let charsetOffset = Int(top[15]?.first ?? 0)
        var sids: [Int]? = [0]
        switch charsetOffset {
        case 0:
            sids = Array(0..<glyphCount)
        case 1, 2:
            sids = nil
        default:
            let format = try data.u8(charsetOffset)
            var position = charsetOffset + 1
            while sids!.count < charstrings.count {
                switch format {
                case 0:
                    sids!.append(try data.u16(position))
                    position += 2
                case 1, 2:
                    let first = try data.u16(position)
                    let left = format == 1 ? try data.u8(position + 2) : try data.u16(position + 2)
                    position += format == 1 ? 3 : 4
                    sids! += (first...(first + left)).prefix(charstrings.count - sids!.count)
                default:
                    throw FontReadError.malformed("CFF charset")
                }
            }
        }
        names = sids.map { $0.map(name) }
        let interpreter = CharstringInterpreter(data: data, globals: globalIndex.items, locals: locals)
        contours = try charstrings.prefix(glyphCount).map { try interpreter.contours($0) }
        while contours.count < glyphCount { contours.append([]) }
    }
}

/// Runs Type 2 charstrings into contours (y up).
struct CharstringInterpreter {
    let data: FontReader
    let globals: [Range<Int>]
    let locals: [Range<Int>]

    static func bias(_ count: Int) -> Int {
        count < 1_240 ? 107 : count < 33_900 ? 1_131 : 32_768
    }

    private final class State {
        var stack: [Double] = []
        var x = 0.0
        var y = 0.0
        var stems = 0
        var widthDone = false
        var contours: [Contour] = []
        var segments: [CubicBezier] = []
        var start: Point?
        var ended = false

        func close() {
            if start != nil, !segments.isEmpty {
                contours.append(Contour(segments: segments, closed: true))
            }
            segments = []
            start = nil
        }

        func move(_ dx: Double, _ dy: Double) {
            close()
            x += dx
            y += dy
            start = Point(x: x, y: y)
        }

        func line(_ dx: Double, _ dy: Double) {
            let from = Point(x: x, y: y)
            x += dx
            y += dy
            segments.append(CubicBezier(line: Line(from, Point(x: x, y: y))))
        }

        func curve(_ d: [Double]) {
            let p0 = Point(x: x, y: y)
            let p1 = Point(x: p0.x + d[0], y: p0.y + d[1])
            let p2 = Point(x: p1.x + d[2], y: p1.y + d[3])
            let p3 = Point(x: p2.x + d[4], y: p2.y + d[5])
            segments.append(CubicBezier(p0, p1, p2, p3))
            x = p3.x
            y = p3.y
        }

        /// Drops the width operand the first stack-clearing operator may carry.
        func width(ifMoreThan count: Int) {
            if !widthDone, stack.count > count { stack.removeFirst() }
            widthDone = true
        }
    }

    /// The contours of the charstring at `range`.
    func contours(_ range: Range<Int>) throws -> [Contour] {
        let state = State()
        try run(range, state: state, depth: 0)
        state.close()
        return state.contours
    }

    private func run(_ range: Range<Int>, state s: State, depth: Int) throws {
        guard depth <= 10 else { throw FontReadError.malformed("charstring subroutine depth") }
        var index = range.lowerBound
        while index < range.upperBound, !s.ended {
            let b0 = try data.u8(index)
            index += 1
            switch b0 {
            case 32...246:
                s.stack.append(Double(b0 - 139))
            case 247...250:
                s.stack.append(Double((b0 - 247) * 256 + (try data.u8(index)) + 108))
                index += 1
            case 251...254:
                s.stack.append(Double(-(b0 - 251) * 256 - (try data.u8(index)) - 108))
                index += 1
            case 28:
                s.stack.append(Double(try data.i16(index)))
                index += 2
            case 255:
                s.stack.append(try data.fixed(index))
                index += 4
            case 1, 3, 18, 23:                                 // hstem, vstem, hstemhm, vstemhm
                s.width(ifMoreThan: s.stack.count - s.stack.count % 2)
                s.stems += s.stack.count / 2
                s.stack = []
            case 19, 20:                                       // hintmask, cntrmask
                s.width(ifMoreThan: s.stack.count - s.stack.count % 2)
                s.stems += s.stack.count / 2
                s.stack = []
                index += (s.stems + 7) / 8
            case 21:                                           // rmoveto
                s.width(ifMoreThan: 2)
                try need(s, 2)
                s.move(s.stack[0], s.stack[1])
                s.stack = []
            case 22:                                           // hmoveto
                s.width(ifMoreThan: 1)
                try need(s, 1)
                s.move(s.stack[0], 0)
                s.stack = []
            case 4:                                            // vmoveto
                s.width(ifMoreThan: 1)
                try need(s, 1)
                s.move(0, s.stack[0])
                s.stack = []
            case 5:                                            // rlineto
                for pair in stride(from: 0, to: s.stack.count - 1, by: 2) { s.line(s.stack[pair], s.stack[pair + 1]) }
                s.stack = []
            case 6, 7:                                         // hlineto, vlineto
                var horizontal = b0 == 6
                for value in s.stack {
                    horizontal ? s.line(value, 0) : s.line(0, value)
                    horizontal.toggle()
                }
                s.stack = []
            case 8:                                            // rrcurveto
                for set in stride(from: 0, to: s.stack.count - 5, by: 6) { s.curve(Array(s.stack[set..<(set + 6)])) }
                s.stack = []
            case 24:                                           // rcurveline
                var at = 0
                while s.stack.count - at >= 8 {
                    s.curve(Array(s.stack[at..<(at + 6)]))
                    at += 6
                }
                if s.stack.count - at >= 2 { s.line(s.stack[at], s.stack[at + 1]) }
                s.stack = []
            case 25:                                           // rlinecurve
                var at = 0
                while s.stack.count - at >= 8 {
                    s.line(s.stack[at], s.stack[at + 1])
                    at += 2
                }
                if s.stack.count - at >= 6 { s.curve(Array(s.stack[at..<(at + 6)])) }
                s.stack = []
            case 26, 27:                                       // vvcurveto, hhcurveto
                var values = s.stack
                var first = values.count % 4 == 1 ? values.removeFirst() : 0
                for set in stride(from: 0, to: values.count - 3, by: 4) {
                    let v = values[set..<(set + 4)].map { $0 }
                    if b0 == 26 {
                        s.curve([first, v[0], v[1], v[2], 0, v[3]])
                    } else {
                        s.curve([v[0], first, v[1], v[2], v[3], 0])
                    }
                    first = 0
                }
                s.stack = []
            case 30, 31:                                       // vhcurveto, hvcurveto
                var horizontal = b0 == 31
                let values = s.stack
                var at = 0
                while values.count - at >= 4 {
                    let last = values.count - at == 5
                    let v = values[at..<(at + 4)].map { $0 }
                    let extra = last ? values[at + 4] : 0
                    if horizontal {
                        s.curve([v[0], 0, v[1], v[2], extra, v[3]])
                    } else {
                        s.curve([0, v[0], v[1], v[2], v[3], extra])
                    }
                    horizontal.toggle()
                    at += last ? 5 : 4
                }
                s.stack = []
            case 10, 29:                                       // callsubr, callgsubr
                guard let raw = s.stack.popLast() else { throw FontReadError.malformed("charstring stack") }
                let subrs = b0 == 10 ? locals : globals
                let number = Int(raw) + Self.bias(subrs.count)
                guard subrs.indices.contains(number) else { throw FontReadError.malformed("charstring subroutine") }
                try run(subrs[number], state: s, depth: depth + 1)
            case 11:                                           // return
                return
            case 14:                                           // endchar
                s.width(ifMoreThan: s.stack.count >= 4 ? 4 : 0)
                s.stack = []
                s.ended = true
            case 12:
                let op = try data.u8(index)
                index += 1
                try escape(op, s)
            default:
                s.stack = []
            }
        }
    }

    private func need(_ s: State, _ count: Int) throws {
        guard s.stack.count >= count else { throw FontReadError.malformed("charstring stack") }
    }

    /// The flex operators; the arithmetic ones clear the stack (not used by outlines worth reading).
    private func escape(_ op: Int, _ s: State) throws {
        let v = s.stack
        switch op {
        case 35:                                                // flex
            try need(s, 12)
            s.curve(Array(v[0..<6]))
            s.curve(Array(v[6..<12]))
        case 34:                                                // hflex
            try need(s, 7)
            s.curve([v[0], 0, v[1], v[2], v[3], 0])
            s.curve([v[4], 0, v[5], -v[2], v[6], 0])
        case 36:                                                // hflex1
            try need(s, 9)
            s.curve([v[0], v[1], v[2], v[3], v[4], 0])
            s.curve([v[5], 0, v[6], v[7], v[8], -(v[1] + v[3] + v[7])])
        case 37:                                                // flex1
            try need(s, 11)
            let dx = v[0] + v[2] + v[4] + v[6] + v[8], dy = v[1] + v[3] + v[5] + v[7] + v[9]
            s.curve(Array(v[0..<6]))
            if abs(dx) > abs(dy) {
                s.curve([v[6], v[7], v[8], v[9], v[10], -dy])
            } else {
                s.curve([v[6], v[7], v[8], v[9], -dx, v[10]])
            }
        default:
            break
        }
        s.stack = []
    }
}
