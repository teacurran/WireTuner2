// PDF functions and colour spaces for import (IMG-009): every colour a content stream selects is
// turned into WTRender's tagged `Color` -- device and calibrated spaces directly, ICC-based spaces
// by component count (Display P3 recognised by its profile), Lab as CIELAB D50, Indexed through
// its lookup, Separation and DeviceN through their tint transforms into the alternate space.

import CoreGraphics
import Foundation
import WTRender

/// A PDF function (types 0, 2, 3 and 4), or an array of one-output functions.
indirect enum PDFImportFunction {
    case sampled(domain: [Double], range: [Double], size: [Int], bitsPerSample: Int, encode: [Double], decode: [Double], samples: [UInt8])
    case exponential(domain: [Double], c0: [Double], c1: [Double], exponent: Double)
    case stitching(domain: [Double], functions: [PDFImportFunction], bounds: [Double], encode: [Double])
    case calculator(domain: [Double], range: [Double], program: [PDFImportOperand])
    case array([PDFImportFunction])

    /// The function a `/Function` (or tint transform) entry describes.
    static func parse(_ value: PDFImportValue) -> PDFImportFunction? {
        if let array = value.array {
            let functions = array.values.compactMap(parse)
            return functions.isEmpty ? nil : .array(functions)
        }
        guard let dict = value.dict else {
            return nil
        }
        let domain = dict.numbers("Domain").flatMap { $0.count >= 2 ? $0 : nil } ?? [0, 1]
        switch Int(dict.number("FunctionType") ?? -1) {
        case 0:
            guard let stream = value.stream, let size = dict.numbers("Size")?.map({ Int($0) }), let range = dict.numbers("Range") else {
                return nil
            }
            let encode = dict.numbers("Encode") ?? size.flatMap { (count: Int) -> [Double] in [0, Double(count - 1)] }
            let decode = dict.numbers("Decode") ?? range
            guard !size.isEmpty, size.allSatisfy({ $0 > 0 }), range.count >= 2, domain.count >= 2 * size.count, encode.count >= 2 * size.count, decode.count >= range.count else {
                return nil
            }
            return .sampled(domain: domain, range: range, size: size, bitsPerSample: Int(dict.number("BitsPerSample") ?? 8), encode: encode, decode: decode, samples: [UInt8](stream.data))
        case 2:
            return .exponential(domain: domain, c0: dict.numbers("C0") ?? [0], c1: dict.numbers("C1") ?? [1], exponent: dict.number("N") ?? 1)
        case 3:
            let functions = dict.array("Functions")?.values.compactMap(parse) ?? []
            guard !functions.isEmpty else {
                return nil
            }
            return .stitching(domain: domain, functions: functions, bounds: dict.numbers("Bounds") ?? [], encode: dict.numbers("Encode") ?? functions.flatMap { _ in [0.0, 1.0] })
        case 4:
            guard let stream = value.stream, let range = dict.numbers("Range"), range.count >= 2 else {
                return nil
            }
            var parser = PDFImportParser(stream.data)
            guard case .operand(.proc(let program))? = parser.next() else {
                return nil
            }
            return .calculator(domain: domain, range: range, program: program)
        default:
            return nil
        }
    }

    static func clip(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    static func interpolate(_ x: Double, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
        x1 == x0 ? y0 : y0 + (x - x0) * (y1 - y0) / (x1 - x0)
    }

    /// The outputs for `inputs`.
    func evaluate(_ inputs: [Double]) -> [Double] {
        switch self {
        case .array(let functions):
            return functions.map { $0.evaluate(inputs).first ?? 0 }
        case .exponential(let domain, let c0, let c1, let exponent):
            let x = PDFImportFunction.clip(inputs.first ?? 0, domain[0], domain[1])
            let power = pow(x, exponent)
            return zip(c0, c1).map { $0 + power * ($1 - $0) }
        case .stitching(let domain, let functions, let bounds, let encode):
            let low = domain[0]
            let high = domain[1]
            let x = PDFImportFunction.clip(inputs.first ?? 0, low, high)
            var index = 0
            while index < bounds.count, x >= bounds[index] {
                index += 1
            }
            index = min(index, functions.count - 1)
            let from = index == 0 ? low : bounds[index - 1]
            let to = index < bounds.count ? bounds[index] : high
            let e0 = encode.count > 2 * index ? encode[2 * index] : 0
            let e1 = encode.count > 2 * index + 1 ? encode[2 * index + 1] : 1
            return functions[index].evaluate([PDFImportFunction.interpolate(x, from, to, e0, e1)])
        case .sampled(let domain, let range, let size, let bits, let encode, let decode, let samples):
            return PDFImportFunction.sample(inputs, domain: domain, range: range, size: size, bits: bits, encode: encode, decode: decode, samples: samples)
        case .calculator(let domain, let range, let program):
            let clipped = inputs.enumerated().map { index, value in
                PDFImportFunction.clip(value, 2 * index < domain.count ? domain[2 * index] : 0, 2 * index + 1 < domain.count ? domain[2 * index + 1] : 1)
            }
            var stack = clipped.map(PDFImportOperand.number)
            PDFImportCalculator.run(program, stack: &stack)
            let outputs = range.count / 2
            let values = stack.suffix(outputs).map { $0.number ?? 0 }
            return values.enumerated().map { PDFImportFunction.clip($1, range[2 * $0], range[2 * $0 + 1]) }
        }
    }

    /// A sampled function: linear interpolation for one input, the nearest sample otherwise.
    static func sample(_ inputs: [Double], domain: [Double], range: [Double], size: [Int], bits: Int, encode: [Double], decode: [Double], samples: [UInt8]) -> [Double] {
        let outputs = range.count / 2
        let maximum = Double((1 << min(bits, 32)) - 1)
        func read(_ index: Int) -> [Double] {
            (0..<outputs).map { output in
                let raw = PDFImportBits.read(samples, index: index * outputs + output, bits: bits)
                return interpolate(raw, 0, maximum, decode[2 * output], decode[2 * output + 1])
            }
        }
        var positions: [Double] = []
        for (dimension, count) in size.enumerated() {
            let x = clip(dimension < inputs.count ? inputs[dimension] : 0, domain[2 * dimension], domain[2 * dimension + 1])
            let e = interpolate(x, domain[2 * dimension], domain[2 * dimension + 1], encode[2 * dimension], encode[2 * dimension + 1])
            positions.append(clip(e, 0, Double(count - 1)))
        }
        if size.count == 1 {
            let e = positions[0]
            let lower = Int(e.rounded(.down))
            let upper = min(lower + 1, size[0] - 1)
            let a = read(lower)
            let b = read(upper)
            let t = e - Double(lower)
            return zip(a, b).map { $0 + t * ($1 - $0) }
        }
        var index = 0
        var stride = 1
        for (dimension, count) in size.enumerated() {
            index += Int(positions[dimension].rounded()) * stride
            stride *= count
        }
        return read(index)
    }
}

/// Reads packed big-endian samples of 1 to 32 bits.
enum PDFImportBits {
    static func read(_ bytes: [UInt8], index: Int, bits: Int) -> Double {
        var value: UInt64 = 0
        var bit = index * bits
        for _ in 0..<bits {
            let byte = bit / 8
            guard byte < bytes.count else {
                return 0
            }
            value = value << 1 | UInt64((bytes[byte] >> (7 - UInt8(bit % 8))) & 1)
            bit += 1
        }
        return Double(value)
    }
}

/// The PostScript calculator of type 4 functions.
enum PDFImportCalculator {
    static func run(_ program: [PDFImportOperand], stack: inout [PDFImportOperand]) {
        for item in program {
            switch item {
            case .keyword(let op):
                execute(op, stack: &stack)
            default:
                stack.append(item)
            }
        }
    }

    static func execute(_ op: String, stack: inout [PDFImportOperand]) {
        func pop() -> Double { stack.popLast()?.number ?? 0 }
        func popBool() -> Bool {
            if case .bool(let value)? = stack.popLast() { return value }
            return false
        }
        func push(_ value: Double) { stack.append(.number(value)) }
        switch op {
        case "add": push(pop() + pop())
        case "sub": let b = pop(); push(pop() - b)
        case "mul": push(pop() * pop())
        case "div": let b = pop(); let a = pop(); push(b == 0 ? 0 : a / b)
        case "idiv": let b = pop(); let a = pop(); push(b == 0 ? 0 : (a / b).rounded(.towardZero))
        case "mod": let b = pop(); let a = pop(); push(b == 0 ? 0 : a.truncatingRemainder(dividingBy: b))
        case "neg": push(-pop())
        case "abs": push(abs(pop()))
        case "sqrt": push(max(pop(), 0).squareRoot())
        case "exp": let e = pop(); push(pow(pop(), e))
        case "ln": push(log(max(pop(), 1e-300)))
        case "log": push(log10(max(pop(), 1e-300)))
        case "sin": push(sin(pop() * .pi / 180))
        case "cos": push(cos(pop() * .pi / 180))
        case "atan":
            let den = pop()
            let num = pop()
            var angle = atan2(num, den) * 180 / .pi
            if angle < 0 { angle += 360 }
            push(angle)
        case "floor": push(pop().rounded(.down))
        case "ceiling": push(pop().rounded(.up))
        case "round": push((pop() + 0.5).rounded(.down))
        case "truncate", "cvi": push(pop().rounded(.towardZero))
        case "cvr": push(pop())
        case "dup": if let last = stack.last { stack.append(last) }
        case "pop": _ = stack.popLast()
        case "exch":
            if stack.count >= 2 { stack.swapAt(stack.count - 1, stack.count - 2) }
        case "copy":
            let n = Int(pop())
            if n > 0, n <= stack.count { stack += stack.suffix(n) }
        case "index":
            let n = Int(pop())
            if n >= 0, n < stack.count { stack.append(stack[stack.count - 1 - n]) }
        case "roll":
            let j = Int(pop())
            let n = Int(pop())
            if n > 0, n <= stack.count {
                var top = Array(stack.suffix(n))
                stack.removeLast(n)
                let shift = ((j % n) + n) % n
                top = Array(top.suffix(shift) + top.prefix(n - shift))
                stack += top
            }
        case "eq", "ne", "gt", "ge", "lt", "le":
            let b = stack.popLast() ?? .null
            let a = stack.popLast() ?? .null
            let x = a.number ?? 0
            let y = b.number ?? 0
            let result: Bool
            switch op {
            case "eq": result = a == b
            case "ne": result = a != b
            case "gt": result = x > y
            case "ge": result = x >= y
            case "lt": result = x < y
            default: result = x <= y
            }
            stack.append(.bool(result))
        case "and", "or", "xor":
            let b = stack.popLast() ?? .null
            let a = stack.popLast() ?? .null
            if case .bool(let p) = a, case .bool(let q) = b {
                stack.append(.bool(op == "and" ? p && q : op == "or" ? p || q : p != q))
            } else {
                let p = Int(a.number ?? 0)
                let q = Int(b.number ?? 0)
                push(Double(op == "and" ? p & q : op == "or" ? p | q : p ^ q))
            }
        case "not":
            let a = stack.popLast() ?? .null
            if case .bool(let p) = a {
                stack.append(.bool(!p))
            } else {
                push(Double(~Int(a.number ?? 0)))
            }
        case "if":
            guard case .proc(let body)? = stack.popLast() else { return }
            if popBool() { run(body, stack: &stack) }
        case "ifelse":
            guard case .proc(let otherwise)? = stack.popLast(), case .proc(let then)? = stack.popLast() else { return }
            run(popBool() ? then : otherwise, stack: &stack)
        default:
            break
        }
    }
}

/// A colour space a content stream selects colours in.
indirect enum PDFImportColorSpace {
    case gray
    case rgb
    case displayP3
    case cmyk
    case lab(range: [Double])
    case indexed(base: PDFImportColorSpace, high: Int, lookup: [UInt8])
    case separation(name: String, alternate: PDFImportColorSpace, tint: PDFImportFunction?)
    case deviceN(names: [String], alternate: PDFImportColorSpace, tint: PDFImportFunction?)
    case pattern

    var components: Int {
        switch self {
        case .gray, .indexed, .separation, .pattern: return 1
        case .rgb, .displayP3, .lab: return 3
        case .cmyk: return 4
        case .deviceN(let names, _, _): return names.count
        }
    }

    /// The colour at the start of the space (black, or the full tint for spot inks).
    var initial: [Double] {
        switch self {
        case .gray, .rgb, .displayP3: return Array(repeating: 0, count: components)
        case .cmyk: return [0, 0, 0, 1]
        case .lab(let range): return [0, min(max(0, range[0]), range[1]), min(max(0, range[2]), range[3])]
        case .indexed, .pattern: return [0]
        case .separation, .deviceN: return Array(repeating: 1, count: components)
        }
    }

    /// The colour of `values`, or nil in the Pattern space.
    func color(_ values: [Double], alpha: Double = 1) -> Color? {
        func value(_ index: Int) -> Double { index < values.count ? values[index] : 0 }
        func unit(_ index: Int) -> Double { min(max(value(index), 0), 1) }
        switch self {
        case .gray:
            return Color(white: unit(0), alpha: alpha)
        case .rgb:
            return Color(red: unit(0), green: unit(1), blue: unit(2), alpha: alpha)
        case .displayP3:
            return Color(displayP3Red: unit(0), green: unit(1), blue: unit(2), alpha: alpha)
        case .cmyk:
            return Color(cyan: unit(0), magenta: unit(1), yellow: unit(2), black: unit(3), alpha: alpha)
        case .lab(let range):
            return Color(labL: min(max(value(0), 0), 100), a: min(max(value(1), range[0]), range[1]), b: min(max(value(2), range[2]), range[3]), alpha: alpha)
        case .indexed(let base, let high, let lookup):
            let index = min(max(Int(value(0).rounded()), 0), high)
            let n = base.components
            let entry = (0..<n).map { component -> Double in
                let offset = index * n + component
                let byte = offset < lookup.count ? Double(lookup[offset]) / 255 : 0
                if case .lab(let range) = base {
                    let low = component == 0 ? 0.0 : range[2 * component - 2]
                    let high = component == 0 ? 100.0 : range[2 * component - 1]
                    return low + byte * (high - low)
                }
                return byte
            }
            return base.color(entry, alpha: alpha)
        case .separation(let name, let alternate, let tint):
            if name == "None" {
                return Color(white: 0, alpha: 0)
            }
            if name == "All" {
                return Color(white: 1 - unit(0), alpha: alpha)
            }
            return alternate.color(tint?.evaluate([unit(0)]) ?? [1 - unit(0)], alpha: alpha)
        case .deviceN(_, let alternate, let tint):
            return alternate.color(tint?.evaluate(values) ?? values, alpha: alpha)
        case .pattern:
            return nil
        }
    }

    /// A device space by name (`DeviceRGB`, the inline abbreviations `G`, `RGB`, `CMYK`).
    static func device(_ name: String) -> PDFImportColorSpace? {
        switch name {
        case "DeviceGray", "G", "CalGray": return .gray
        case "DeviceRGB", "RGB", "CalRGB": return .rgb
        case "DeviceCMYK", "CMYK": return .cmyk
        case "Pattern": return .pattern
        default: return nil
        }
    }

    /// The space a name selects: a device space, or an entry of the resources' `/ColorSpace`.
    static func named(_ name: String, resources: PDFImportDict?) -> PDFImportColorSpace? {
        if let space = device(name) {
            return space
        }
        guard let value = resources?.dict("ColorSpace")?[name] else {
            return nil
        }
        return parse(value, resources: resources)
    }

    /// The space an object describes.
    static func parse(_ value: PDFImportValue, resources: PDFImportDict?) -> PDFImportColorSpace? {
        if let name = value.name {
            return named(name, resources: resources)
        }
        guard let array = value.array, let family = array[0]?.name else {
            return nil
        }
        switch family {
        case "ICCBased":
            guard let stream = array[1]?.stream else { return nil }
            let components = Int(stream.dict.number("N") ?? 3)
            switch components {
            case 1: return .gray
            case 4: return .cmyk
            default:
                return stream.data == PDFImportColorSpace.displayP3Profile ? .displayP3 : .rgb
            }
        case "CalRGB", "CalGray", "DeviceRGB", "DeviceGray", "DeviceCMYK", "Pattern":
            return device(family)
        case "Lab":
            return .lab(range: array[1]?.dict?.numbers("Range").flatMap { $0.count == 4 ? $0 : nil } ?? [-100, 100, -100, 100])
        case "Indexed", "I":
            guard let baseValue = array[1], let base = parse(baseValue, resources: resources) else { return nil }
            let high = Int(array[2]?.number ?? 0)
            let lookup: Data
            switch array[3] {
            case .string(let data)?: lookup = data
            case .stream(let stream)?: lookup = stream.data
            default: lookup = Data()
            }
            return .indexed(base: base, high: high, lookup: [UInt8](lookup))
        case "Separation":
            guard let alternateValue = array[2], let alternate = parse(alternateValue, resources: resources) else { return nil }
            return .separation(name: array[1]?.name ?? "", alternate: alternate, tint: array[3].flatMap(PDFImportFunction.parse))
        case "DeviceN":
            guard let alternateValue = array[2], let alternate = parse(alternateValue, resources: resources) else { return nil }
            return .deviceN(names: array[1]?.array?.values.compactMap(\.name) ?? [], alternate: alternate, tint: array[3].flatMap(PDFImportFunction.parse))
        default:
            return nil
        }
    }

    /// The Display P3 ICC profile Core Graphics (and so WireTuner's PDF writer) embeds.
    static let displayP3Profile: Data = CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data
}
