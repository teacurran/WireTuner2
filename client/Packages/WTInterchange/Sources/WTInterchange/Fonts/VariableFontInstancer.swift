// Static instances of variable TrueType fonts (TYPE-048; type-specifications.adoc, "Export"): PDF
// has no variable fonts, so for each (font, axis tuple) on the exported pages the PDF writer embeds
// a static TrueType subset made here from the font's own tables, with no third-party code.
//
// The tuple (user-space axis values, `GlyphFont.variations`) is normalized through `fvar` and
// mapped through `avar`; every `gvar` tuple variation whose region contains it is scaled and its
// deltas -- inferred for untouched points by IUP -- added to the glyph's points (a composite's
// component offsets); coordinates are rounded once all deltas are summed.  Advances come from Core
// Text's instance of the same tuple (which applies `HVAR`), so the embedded widths, the PDF's `/W`
// array and the text layout agree.  `fvar`, `gvar`, `avar`, `HVAR`, `MVAR`, `STAT`, `cvar` and
// `VVAR` are dropped (a subset keeps only `FontProgram.keptTables`).  CFF2-flavoured variable
// fonts have no `glyf` table and are refused, as is anything whose tables do not parse; the writer
// then draws those runs as outlines and reports the font.

import CoreGraphics
import CoreText
import Foundation

enum VariableFontInstancer {
    enum Failure: Error, Hashable {
        /// No `glyf` outlines (a CFF2 variable font, or not a TrueType font).
        case notTrueType
        /// A table is missing or does not parse.
        case malformed(String)
    }

    /// One `fvar` axis in user units.
    struct Axis: Hashable {
        var tag: UInt32
        var minimum: Double
        var defaultValue: Double
        var maximum: Double
    }

    /// Whether `font`'s tables look instanceable: `glyf`, `loca`, `fvar` and `gvar` present and
    /// their headers readable.  Cheap; the glyph data is only read when instancing.
    static func canInstance(_ font: CTFont) -> Bool {
        guard let fvar = FontProgram.table("fvar", of: font), let gvar = FontProgram.table("gvar", of: font),
              FontProgram.table("glyf", of: font) != nil, FontProgram.table("loca", of: font) != nil
        else {
            return false
        }
        return (try? axes(fvar)) != nil && gvar.count >= 20
    }

    // MARK: Coordinates

    static func axes(_ fvar: Data) throws -> [Axis] {
        let bytes = [UInt8](fvar)
        guard bytes.count >= 16 else { throw Failure.malformed("fvar") }
        let offset = Int(word(bytes, 4)), count = Int(word(bytes, 8)), size = Int(word(bytes, 10))
        guard size >= 20, offset + count * size <= bytes.count else { throw Failure.malformed("fvar") }
        return (0..<count).map { index in
            let base = offset + index * size
            return Axis(tag: long(bytes, base), minimum: fixed(bytes, base + 4), defaultValue: fixed(bytes, base + 8), maximum: fixed(bytes, base + 12))
        }
    }

    /// The normalized coordinate of `value` on `axis`: -1 ... 0 ... 1.
    static func normalize(_ value: Double, axis: Axis) -> Double {
        let clamped = min(max(value, axis.minimum), axis.maximum)
        if clamped < axis.defaultValue {
            return axis.defaultValue > axis.minimum ? (clamped - axis.defaultValue) / (axis.defaultValue - axis.minimum) : 0
        }
        if clamped > axis.defaultValue {
            return axis.maximum > axis.defaultValue ? (clamped - axis.defaultValue) / (axis.maximum - axis.defaultValue) : 0
        }
        return 0
    }

    /// `avar`'s segment maps: per axis, (from, to) pairs in normalized units.
    static func segmentMaps(_ avar: Data?, axisCount: Int) -> [[(Double, Double)]] {
        guard let avar else { return [] }
        let bytes = [UInt8](avar)
        guard bytes.count >= 8, Int(word(bytes, 6)) == axisCount else { return [] }
        var maps: [[(Double, Double)]] = []
        var position = 8
        for _ in 0..<axisCount {
            guard position + 2 <= bytes.count else { return [] }
            let count = Int(word(bytes, position))
            position += 2
            guard position + count * 4 <= bytes.count else { return [] }
            maps.append((0..<count).map { (f2dot14(bytes, position + $0 * 4), f2dot14(bytes, position + $0 * 4 + 2)) })
            position += count * 4
        }
        return maps
    }

    /// `value` through one axis's segment map (piecewise linear; identity without one).
    static func map(_ value: Double, through segments: [(Double, Double)]) -> Double {
        guard segments.count >= 2 else { return value }
        if value <= segments[0].0 { return segments[0].1 }
        for index in 1..<segments.count where value <= segments[index].0 {
            let (x0, y0) = segments[index - 1], (x1, y1) = segments[index]
            return x1 > x0 ? y0 + (value - x0) / (x1 - x0) * (y1 - y0) : y1
        }
        return segments[segments.count - 1].1
    }

    /// The normalized coordinates of `variations` (axis tag → user value; missing axes default).
    static func coordinates(_ variations: [UInt32: Double], axes: [Axis], avar: Data?) -> [Double] {
        let maps = segmentMaps(avar, axisCount: axes.count)
        return axes.enumerated().map { index, axis in
            let normalized = normalize(variations[axis.tag] ?? axis.defaultValue, axis: axis)
            return index < maps.count ? map(normalized, through: maps[index]) : normalized
        }
    }

    /// A tuple variation's scalar at `coordinates` (the OpenType "Algorithm for calculating a
    /// tuple scalar"): per axis with a non-zero peak, 0 outside the region, the linear ramp to the
    /// peak inside it; an intermediate region that is invalid or spans zero ignores the axis.
    static func scalar(peak: [Double], start: [Double]?, end: [Double]?, coordinates: [Double]) -> Double {
        var result = 1.0
        for index in peak.indices {
            let p = peak[index]
            let v = index < coordinates.count ? coordinates[index] : 0
            if p == 0 || v == p {
                continue
            }
            if let start, let end {
                let s = start[index], e = end[index]
                if s > p || p > e || (s < 0 && e > 0) {
                    continue
                }
                if v < s || v > e {
                    return 0
                }
                result *= v < p ? (v - s) / (p - s) : (e - v) / (e - p)
            } else {
                if v < min(p, 0) || v > max(p, 0) {
                    return 0
                }
                result *= v / p
            }
        }
        return result
    }

    // MARK: Packed data

    /// Packed point numbers from `position`: nil means every point.
    static func points(_ bytes: [UInt8], _ position: inout Int) throws -> [Int]? {
        guard position < bytes.count else { throw Failure.malformed("gvar points") }
        var count = Int(bytes[position])
        position += 1
        if count == 0 { return nil }
        if count & 0x80 != 0 {
            guard position < bytes.count else { throw Failure.malformed("gvar points") }
            count = (count & 0x7F) << 8 | Int(bytes[position])
            position += 1
        }
        var result: [Int] = []
        var last = 0
        while result.count < count {
            guard position < bytes.count else { throw Failure.malformed("gvar points") }
            let control = Int(bytes[position])
            position += 1
            let words = control & 0x80 != 0
            for _ in 0...(control & 0x7F) where result.count < count {
                guard position + (words ? 2 : 1) <= bytes.count else { throw Failure.malformed("gvar points") }
                last += words ? Int(word(bytes, position)) : Int(bytes[position])
                position += words ? 2 : 1
                result.append(last)
            }
        }
        return result
    }

    /// `count` packed deltas from `position`.
    static func deltas(_ bytes: [UInt8], _ position: inout Int, count: Int) throws -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(count)
        while result.count < count {
            guard position < bytes.count else { throw Failure.malformed("gvar deltas") }
            let control = Int(bytes[position])
            position += 1
            let run = (control & 0x3F) + 1
            for _ in 0..<run where result.count < count {
                if control & 0x80 != 0 {
                    result.append(0)
                } else if control & 0x40 != 0 {
                    guard position + 2 <= bytes.count else { throw Failure.malformed("gvar deltas") }
                    result.append(Double(Int16(bitPattern: word(bytes, position))))
                    position += 2
                } else {
                    guard position < bytes.count else { throw Failure.malformed("gvar deltas") }
                    result.append(Double(Int8(bitPattern: bytes[position])))
                    position += 1
                }
            }
        }
        return result
    }

    /// Interpolates untouched points' deltas within each contour (IUP): between two touched
    /// neighbours, proportional to the original coordinate when it lies between theirs, else the
    /// nearer one's delta; a contour with one touched point moves whole.
    static func interpolate(_ deltas: inout [Double], touched: [Bool], coordinates: [Double], ends: [Int]) {
        var start = 0
        for end in ends {
            guard end >= start, end < coordinates.count else { break }
            let indices = Array(start...end)
            let marked = indices.filter { touched[$0] }
            if marked.count == 1 {
                for index in indices where !touched[index] { deltas[index] = deltas[marked[0]] }
            } else if marked.count > 1 {
                for (position, reference) in marked.enumerated() {
                    let next = marked[(position + 1) % marked.count]
                    var index = reference == end ? start : reference + 1
                    while index != next {
                        let (c1, c2) = (coordinates[reference], coordinates[next])
                        let (d1, d2) = (deltas[reference], deltas[next])
                        let c = coordinates[index]
                        if c1 == c2 {
                            deltas[index] = d1 == d2 ? d1 : 0
                        } else if c <= min(c1, c2) {
                            deltas[index] = c1 < c2 ? d1 : d2
                        } else if c >= max(c1, c2) {
                            deltas[index] = c1 > c2 ? d1 : d2
                        } else {
                            deltas[index] = d1 + (c - c1) / (c2 - c1) * (d2 - d1)
                        }
                        index = index == end ? start : index + 1
                    }
                }
            }
            start = end + 1
        }
    }

    // MARK: Glyphs

    /// A simple glyph's contours and instructions, or a composite's components.
    enum Glyph {
        case empty
        case simple(ends: [Int], instructions: ArraySlice<UInt8>, flags: [UInt8], x: [Double], y: [Double])
        case composite(components: [Component], instructions: ArraySlice<UInt8>)
    }

    struct Component {
        var flags: UInt16
        var glyph: Int
        /// The offset when the arguments are x and y values (`ARGS_ARE_XY_VALUES`).
        var dx: Double
        var dy: Double
        /// The arguments as written (point numbers are kept as they are).
        var arguments: ArraySlice<UInt8>
        /// The transform words (none, one scale, two scales or a 2 × 2) as written.
        var transform: ArraySlice<UInt8>

        var hasOffset: Bool { flags & 0x0002 != 0 }
    }

    static func parse(_ data: ArraySlice<UInt8>) throws -> Glyph {
        let bytes = Array(data)
        guard bytes.count >= 10 else { return .empty }
        let contours = Int(Int16(bitPattern: word(bytes, 0)))
        if contours >= 0 {
            var position = 10
            guard position + contours * 2 + 2 <= bytes.count else { throw Failure.malformed("glyf") }
            let ends = (0..<contours).map { Int(word(bytes, position + $0 * 2)) }
            position += contours * 2
            let instructionCount = Int(word(bytes, position))
            position += 2
            guard position + instructionCount <= bytes.count else { throw Failure.malformed("glyf") }
            let instructions = data[(data.startIndex + position)..<(data.startIndex + position + instructionCount)]
            position += instructionCount
            let count = (ends.last ?? -1) + 1
            var flags: [UInt8] = []
            while flags.count < count {
                guard position < bytes.count else { throw Failure.malformed("glyf flags") }
                let flag = bytes[position]
                position += 1
                flags.append(flag)
                if flag & 0x08 != 0 {
                    guard position < bytes.count else { throw Failure.malformed("glyf flags") }
                    flags += [UInt8](repeating: flag, count: Int(bytes[position]))
                    position += 1
                }
            }
            flags = Array(flags.prefix(count))
            func coordinates(short: UInt8, same: UInt8) throws -> [Double] {
                var value = 0
                var result: [Double] = []
                for flag in flags {
                    if flag & short != 0 {
                        guard position < bytes.count else { throw Failure.malformed("glyf coordinates") }
                        value += flag & same != 0 ? Int(bytes[position]) : -Int(bytes[position])
                        position += 1
                    } else if flag & same == 0 {
                        guard position + 2 <= bytes.count else { throw Failure.malformed("glyf coordinates") }
                        value += Int(Int16(bitPattern: word(bytes, position)))
                        position += 2
                    }
                    result.append(Double(value))
                }
                return result
            }
            let x = try coordinates(short: 0x02, same: 0x10)
            let y = try coordinates(short: 0x04, same: 0x20)
            return .simple(ends: ends, instructions: instructions, flags: flags.map { $0 & 0x01 | $0 & 0x40 }, x: x, y: y)
        }
        var components: [Component] = []
        var position = 10
        var more = true
        var hasInstructions = false
        while more {
            guard position + 4 <= bytes.count else { throw Failure.malformed("glyf components") }
            let flags = word(bytes, position)
            let glyph = Int(word(bytes, position + 2))
            position += 4
            let words = flags & 0x0001 != 0
            guard position + (words ? 4 : 2) <= bytes.count else { throw Failure.malformed("glyf components") }
            let (a, b): (Double, Double)
            if words {
                (a, b) = (Double(Int16(bitPattern: word(bytes, position))), Double(Int16(bitPattern: word(bytes, position + 2))))
            } else {
                (a, b) = (Double(Int8(bitPattern: bytes[position])), Double(Int8(bitPattern: bytes[position + 1])))
            }
            let arguments = data[(data.startIndex + position)..<(data.startIndex + position + (words ? 4 : 2))]
            position += words ? 4 : 2
            let transformLength = flags & 0x0008 != 0 ? 2 : (flags & 0x0040 != 0 ? 4 : (flags & 0x0080 != 0 ? 8 : 0))
            guard position + transformLength <= bytes.count else { throw Failure.malformed("glyf components") }
            let transform = data[(data.startIndex + position)..<(data.startIndex + position + transformLength)]
            position += transformLength
            components.append(Component(flags: flags, glyph: glyph, dx: a, dy: b, arguments: arguments, transform: transform))
            more = flags & 0x0020 != 0
            hasInstructions = hasInstructions || flags & 0x0100 != 0
        }
        var instructions: ArraySlice<UInt8> = []
        if hasInstructions, position + 2 <= bytes.count {
            let count = Int(word(bytes, position))
            let start = data.startIndex + position + 2
            instructions = data[start..<min(start + count, data.endIndex)]
        }
        return .composite(components: components, instructions: instructions)
    }

    /// The glyph's point count as `gvar` numbers them (components for a composite), before the
    /// four phantom points.
    static func pointCount(_ glyph: Glyph) -> Int {
        switch glyph {
        case .empty: return 0
        case .simple(_, _, _, let x, _): return x.count
        case .composite(let components, _): return components.count
        }
    }

    /// The summed deltas of glyph `index` at `coordinates` (points then phantom points).
    static func glyphDeltas(_ gvar: [UInt8], header: GvarHeader, glyph index: Int, parsed: Glyph, coordinates: [Double]) throws -> (x: [Double], y: [Double]) {
        let count = pointCount(parsed) + 4
        var dx = [Double](repeating: 0, count: count)
        var dy = [Double](repeating: 0, count: count)
        guard index < header.glyphCount else { return (dx, dy) }
        let start = header.dataOffset + header.offsets[index], end = header.dataOffset + header.offsets[index + 1]
        guard end > start else { return (dx, dy) }
        guard end <= gvar.count, start + 4 <= end else { throw Failure.malformed("gvar glyph data") }
        let tupleCount = Int(word(gvar, start)) & 0x0FFF
        let sharedPoints = word(gvar, start) & 0x8000 != 0
        var serialized = start + Int(word(gvar, start + 2))
        var headerPosition = start + 4
        let shared = sharedPoints ? try points(gvar, &serialized) : nil
        let axisCount = header.axisCount
        func tuple(_ at: Int) -> [Double] { (0..<axisCount).map { f2dot14(gvar, at + $0 * 2) } }
        for _ in 0..<tupleCount {
            guard headerPosition + 4 <= end else { throw Failure.malformed("gvar tuple header") }
            let size = Int(word(gvar, headerPosition))
            let tupleIndex = word(gvar, headerPosition + 2)
            headerPosition += 4
            let peak: [Double]
            if tupleIndex & 0x8000 != 0 {
                guard headerPosition + axisCount * 2 <= end else { throw Failure.malformed("gvar peak") }
                peak = tuple(headerPosition)
                headerPosition += axisCount * 2
            } else {
                let shared = Int(tupleIndex & 0x0FFF)
                guard shared < header.sharedTuples.count else { throw Failure.malformed("gvar shared tuple") }
                peak = header.sharedTuples[shared]
            }
            var startTuple: [Double]?
            var endTuple: [Double]?
            if tupleIndex & 0x4000 != 0 {
                guard headerPosition + axisCount * 4 <= end else { throw Failure.malformed("gvar region") }
                startTuple = tuple(headerPosition)
                endTuple = tuple(headerPosition + axisCount * 2)
                headerPosition += axisCount * 4
            }
            let dataStart = serialized
            serialized += size
            let factor = scalar(peak: peak, start: startTuple, end: endTuple, coordinates: coordinates)
            guard factor != 0 else { continue }
            var position = dataStart
            let numbers = tupleIndex & 0x2000 != 0 ? try points(gvar, &position) : shared
            let targets = numbers ?? Array(0..<count)
            let xs = try deltas(gvar, &position, count: targets.count)
            let ys = try deltas(gvar, &position, count: targets.count)
            var tx = [Double](repeating: 0, count: count), ty = tx
            var touched = [Bool](repeating: numbers == nil, count: count)
            for (offset, point) in targets.enumerated() where point < count {
                tx[point] = xs[offset]
                ty[point] = ys[offset]
                touched[point] = true
            }
            if numbers != nil, case .simple(let ends, _, _, let x, let y) = parsed {
                interpolate(&tx, touched: touched, coordinates: x + [0, 0, 0, 0], ends: ends)
                interpolate(&ty, touched: touched, coordinates: y + [0, 0, 0, 0], ends: ends)
            }
            for point in 0..<count {
                dx[point] += tx[point] * factor
                dy[point] += ty[point] * factor
            }
        }
        return (dx, dy)
    }

    struct GvarHeader {
        var axisCount: Int
        var sharedTuples: [[Double]]
        var glyphCount: Int
        var dataOffset: Int
        var offsets: [Int]
    }

    static func gvarHeader(_ gvar: [UInt8]) throws -> GvarHeader {
        guard gvar.count >= 20 else { throw Failure.malformed("gvar") }
        let axisCount = Int(word(gvar, 4))
        let sharedCount = Int(word(gvar, 6))
        let sharedOffset = Int(long(gvar, 8))
        let glyphCount = Int(word(gvar, 12))
        let longOffsets = word(gvar, 14) & 1 != 0
        let dataOffset = Int(long(gvar, 16))
        guard 20 + (glyphCount + 1) * (longOffsets ? 4 : 2) <= gvar.count, sharedOffset + sharedCount * axisCount * 2 <= gvar.count else {
            throw Failure.malformed("gvar")
        }
        let offsets = (0...glyphCount).map { longOffsets ? Int(long(gvar, 20 + $0 * 4)) : Int(word(gvar, 20 + $0 * 2)) * 2 }
        let shared = (0..<sharedCount).map { index in (0..<axisCount).map { f2dot14(gvar, sharedOffset + (index * axisCount + $0) * 2) } }
        return GvarHeader(axisCount: axisCount, sharedTuples: shared, glyphCount: glyphCount, dataOffset: dataOffset, offsets: offsets)
    }

    /// A simple glyph written with new coordinates (flags recomputed, no repeats).
    static func encodeSimple(ends: [Int], instructions: ArraySlice<UInt8>, flags: [UInt8], x: [Int], y: [Int]) -> [UInt8] {
        var out: [UInt8] = []
        func put16(_ value: Int) { out += [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
        put16(ends.count)
        put16(x.min() ?? 0)
        put16(y.min() ?? 0)
        put16(x.max() ?? 0)
        put16(y.max() ?? 0)
        ends.forEach(put16)
        put16(instructions.count)
        out += instructions
        var xs: [UInt8] = [], ys: [UInt8] = []
        var flagBytes: [UInt8] = []
        var (px, py) = (0, 0)
        for index in x.indices {
            var flag = flags[index] & 0x41
            let (dx, dy) = (x[index] - px, y[index] - py)
            if dx == 0 {
                flag |= 0x10
            } else if abs(dx) < 256 {
                flag |= 0x02 | (dx > 0 ? 0x10 : 0)
                xs.append(UInt8(abs(dx)))
            } else {
                xs += [UInt8((dx >> 8) & 0xFF), UInt8(dx & 0xFF)]
            }
            if dy == 0 {
                flag |= 0x20
            } else if abs(dy) < 256 {
                flag |= 0x04 | (dy > 0 ? 0x20 : 0)
                ys.append(UInt8(abs(dy)))
            } else {
                ys += [UInt8((dy >> 8) & 0xFF), UInt8(dy & 0xFF)]
            }
            flagBytes.append(flag)
            (px, py) = (x[index], y[index])
        }
        return out + flagBytes + xs + ys
    }

    /// A composite glyph with moved component offsets (written as words) and `bounds`.
    static func encodeComposite(_ components: [Component], instructions: ArraySlice<UInt8>, bounds: (Int, Int, Int, Int)) -> [UInt8] {
        var out: [UInt8] = []
        func put16(_ value: Int) { out += [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
        put16(-1)
        put16(bounds.0)
        put16(bounds.1)
        put16(bounds.2)
        put16(bounds.3)
        var hasInstructions = false
        for component in components {
            hasInstructions = hasInstructions || component.flags & 0x0100 != 0
            if component.hasOffset {
                put16(Int(component.flags | 0x0001))
                put16(component.glyph)
                put16(Int(component.dx.rounded()))
                put16(Int(component.dy.rounded()))
            } else {
                put16(Int(component.flags))
                put16(component.glyph)
                out += component.arguments
            }
            out += component.transform
        }
        if hasInstructions {
            put16(instructions.count)
            out += instructions
        }
        return out
    }

    // MARK: Instancing

    /// A static TrueType program of `font` (Core Text's instance at `variations`, any size) at
    /// that tuple, holding `glyphs` -- and `.notdef` and every component they use -- with every
    /// other glyph empty; nil `glyphs` keeps them all (*Embed fonts: Complete*).
    static func instance(of font: CTFont, variations: [UInt32: Double], glyphs requested: Set<CGGlyph>?) throws -> Data {
        guard let glyf = FontProgram.table("glyf", of: font), let loca = FontProgram.table("loca", of: font) else {
            throw Failure.notTrueType
        }
        guard let head = FontProgram.table("head", of: font), let maxp = FontProgram.table("maxp", of: font), let hhea = FontProgram.table("hhea", of: font),
              let fvar = FontProgram.table("fvar", of: font), let gvarData = FontProgram.table("gvar", of: font), head.count >= 54, maxp.count >= 6, hhea.count >= 36
        else {
            throw Failure.malformed("required tables")
        }
        let axes = try self.axes(fvar)
        let coordinates = self.coordinates(variations, axes: axes, avar: FontProgram.table("avar", of: font))
        let gvar = [UInt8](gvarData)
        let header = try gvarHeader(gvar)
        guard header.axisCount == axes.count else { throw Failure.malformed("gvar axes") }
        let bytes = [UInt8](glyf)
        let longOffsets = FontProgram.int16(head, 50) != 0
        let count = Int(FontProgram.uint16(maxp, 4))
        let offsets = (0...count).map { longOffsets ? Int(FontProgram.uint32(loca, $0 * 4)) : Int(FontProgram.uint16(loca, $0 * 2)) * 2 }
        guard offsets.last.map({ $0 <= bytes.count }) == true else { throw Failure.malformed("loca") }
        func data(_ glyph: Int) -> ArraySlice<UInt8> {
            offsets[glyph + 1] > offsets[glyph] ? bytes[offsets[glyph]..<offsets[glyph + 1]] : []
        }
        var kept = Set<Int>()
        var pending = [0] + (requested.map { $0.map(Int.init) } ?? Array(0..<count)).filter { $0 < count }
        while let glyph = pending.popLast() {
            guard kept.insert(glyph).inserted else { continue }
            pending += FontProgram.components(of: data(glyph)).filter { $0 < count && !kept.contains($0) }
        }
        var instanced: [Int: [UInt8]] = [:]
        var bounds: [Int: (Int, Int, Int, Int)] = [:]
        var composites: [Int: (components: [Component], instructions: ArraySlice<UInt8>)] = [:]
        for glyph in kept.sorted() {
            let parsed = try parse(data(glyph))
            let (dx, dy) = try glyphDeltas(gvar, header: header, glyph: glyph, parsed: parsed, coordinates: coordinates)
            switch parsed {
            case .empty:
                break
            case .simple(let ends, let instructions, let flags, let x, let y):
                let nx = x.indices.map { Int((x[$0] + dx[$0]).rounded()) }
                let ny = y.indices.map { Int((y[$0] + dy[$0]).rounded()) }
                instanced[glyph] = encodeSimple(ends: ends, instructions: instructions, flags: flags, x: nx, y: ny)
                bounds[glyph] = (nx.min() ?? 0, ny.min() ?? 0, nx.max() ?? 0, ny.max() ?? 0)
            case .composite(var components, let instructions):
                for index in components.indices where components[index].hasOffset {
                    components[index].dx += dx[index]
                    components[index].dy += dy[index]
                }
                composites[glyph] = (components, instructions)
            }
        }
        // A composite's bounds: its components' bounds moved by their offsets (a component's
        // scale is not applied: the box is a hint readers recompute).
        func compositeBounds(_ glyph: Int, depth: Int) throws -> (Int, Int, Int, Int) {
            if let box = bounds[glyph] {
                return box
            }
            guard let composite = composites[glyph] else {
                return (0, 0, 0, 0)
            }
            guard depth < 16 else { throw Failure.malformed("composite nesting") }
            var boxes: [(Int, Int, Int, Int)] = []
            for component in composite.components {
                let box = try compositeBounds(component.glyph, depth: depth + 1)
                let (ox, oy) = component.hasOffset ? (Int(component.dx.rounded()), Int(component.dy.rounded())) : (0, 0)
                boxes.append((box.0 + ox, box.1 + oy, box.2 + ox, box.3 + oy))
            }
            let box = (boxes.map(\.0).min() ?? 0, boxes.map(\.1).min() ?? 0, boxes.map(\.2).max() ?? 0, boxes.map(\.3).max() ?? 0)
            bounds[glyph] = box
            return box
        }
        for (glyph, composite) in composites {
            instanced[glyph] = encodeComposite(composite.components, instructions: composite.instructions, bounds: try compositeBounds(glyph, depth: 0))
        }
        var subsetGlyf: [UInt8] = []
        var subsetLoca: [UInt8] = []
        for glyph in 0..<count {
            FontProgram.append(UInt32(subsetGlyf.count), to: &subsetLoca)
            if let encoded = instanced[glyph] {
                subsetGlyf += encoded
                while subsetGlyf.count % 4 != 0 { subsetGlyf.append(0) }
            }
        }
        FontProgram.append(UInt32(subsetGlyf.count), to: &subsetLoca)
        // Advances at the tuple, from Core Text's instance at one unit per em unit.
        let unitsPerEm = Double(FontProgram.uint16(head, 18))
        let sized = CTFontCreateCopyWithAttributes(font, CGFloat(unitsPerEm), nil, nil)
        var advances = [CGSize](repeating: .zero, count: count)
        let allGlyphs = (0..<count).map { CGGlyph($0) }
        CTFontGetAdvancesForGlyphs(sized, .horizontal, allGlyphs, &advances, count)
        var hmtx: [UInt8] = []
        var widest = 0
        for glyph in 0..<count {
            let advance = Int(Double(advances[glyph].width).rounded())
            widest = max(widest, advance)
            FontProgram.append(UInt16(clamping: max(advance, 0)), to: &hmtx)
            FontProgram.append(UInt16(bitPattern: Int16(clamping: bounds[glyph]?.0 ?? 0)), to: &hmtx)
        }
        var newHead = [UInt8](head)
        newHead[8..<12] = [0, 0, 0, 0]
        newHead[50] = 0
        newHead[51] = 1
        var newHhea = [UInt8](hhea)
        newHhea[10] = UInt8((widest >> 8) & 0xFF)
        newHhea[11] = UInt8(widest & 0xFF)
        newHhea[34] = UInt8((count >> 8) & 0xFF)
        newHhea[35] = UInt8(count & 0xFF)
        var tables: [String: Data] = ["glyf": Data(subsetGlyf), "loca": Data(subsetLoca), "head": Data(newHead), "hhea": Data(newHhea), "hmtx": Data(hmtx)]
        for tag in FontProgram.keptTables where tables[tag] == nil {
            if let table = FontProgram.table(tag, of: font) {
                tables[tag] = table
            }
        }
        return FontProgram.sfnt(tables)
    }

    // MARK: Bytes

    static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func long(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(word(bytes, offset)) << 16 | UInt32(word(bytes, offset + 2))
    }

    static func fixed(_ bytes: [UInt8], _ offset: Int) -> Double {
        Double(Int32(bitPattern: long(bytes, offset))) / 65536
    }

    static func f2dot14(_ bytes: [UInt8], _ offset: Int) -> Double {
        Double(Int16(bitPattern: word(bytes, offset))) / 16384
    }
}
