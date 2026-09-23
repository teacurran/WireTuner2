import Testing
@testable import WTCRDT

@Suite struct FractionalIndexTests {
    static func key(_ lo: [UInt8]?, _ hi: [UInt8]?, _ suffix: UInt64 = 0x1234) throws -> [UInt8] {
        try FractionalIndex.between(lo, hi, suffix: suffix)
    }

    @Test func splitMix64MatchesTheReferenceSequence() {
        var random = SplitMix64(seed: 0)
        #expect(random.next() == 0xE220_A839_7B1D_CDAF)
        #expect(random.next() == 0x6E78_9E6A_A1B9_65F4)
    }

    @Test func buildsKeysFromTheNeighboursDigitsAndASuffix() throws {
        #expect(try Self.key(nil, nil) == [0x80, 0x34, 0x13])
        #expect(try Self.key([0x80, 0x11], nil) == [0x81, 0x34, 0x13])
        #expect(try Self.key([0xFF, 0xFF, 0x05], nil) == [0xFF, 0xFF, 0x06, 0x34, 0x13])
        #expect(try Self.key([0xFF], nil) == [0xFF, 0x01, 0x34, 0x13])
        #expect(try Self.key(nil, [0x80]) == [0x7F, 0x34, 0x13])
        #expect(try Self.key(nil, [0x01, 0x40]) == [0x00, 0xFF, 0x34, 0x13])
        #expect(try Self.key(nil, [0x00, 0x00, 0x07]) == [0x00, 0x00, 0x06, 0x34, 0x13])
        #expect(try Self.key([0x20], [0x80]) == [0x50, 0x34, 0x13])
        #expect(try Self.key([0x80, 0x10], [0x81, 0x05]) == [0x80, 0x11, 0x34, 0x13])
        #expect(try Self.key([0x80], [0x80, 0x01]) == [0x80, 0x00, 0x01, 0x34, 0x13])
        #expect(try Self.key([0x80], [0x81], .max) == [0x80, 0x01, 0xFF, 0x01])
    }

    @Test func rejectsKeysItCouldNotHaveGenerated() {
        #expect(throws: FractionalIndex.OrderError(description: " is not a generated position")) { try Self.key([], nil) }
        #expect(throws: FractionalIndex.OrderError(description: "8000 is not a generated position")) { try Self.key(nil, [0x80, 0]) }
        #expect(throws: FractionalIndex.OrderError(description: "81 does not sort before 80")) { try Self.key([0x81], [0x80]) }
        #expect(throws: FractionalIndex.OrderError.self) { try Self.key([0x80], [0x80]) }
    }

    @Test func everyKeySortsStrictlyBetweenItsNeighbours() throws {
        var random = SplitMix64(seed: 17)
        var keys: [[UInt8]] = []
        for _ in 0..<2_000 {
            let index = Int(random.next() % UInt64(keys.count + 1))
            let lo = index > 0 ? keys[index - 1] : nil
            let hi = index < keys.count ? keys[index] : nil
            let key = try FractionalIndex.between(lo, hi, using: &random)
            #expect(key.last != 0)
            #expect(lo.map { FractionalIndex.less($0, key) } ?? true)
            #expect(hi.map { FractionalIndex.less(key, $0) } ?? true)
            keys.insert(key, at: index)
        }
    }

    @Test func aThousandSequentialAppendsStayUnderFortyBytes() throws {
        var random = SplitMix64(seed: 1)
        var last: [UInt8]?
        var longest = 0
        for _ in 0..<1_000 {
            last = try FractionalIndex.between(last, nil, using: &random)
            longest = max(longest, last!.count)
        }
        #expect(longest < 40)
        var prepended: [UInt8]?
        for _ in 0..<1_000 {
            prepended = try FractionalIndex.between(nil, prepended, using: &random)
        }
        #expect(prepended!.count < 40)
    }

    @Test func childOrderIsPositionThenID() {
        let a = (position: [UInt8]([0x80]), id: OpID(counter: 2, replica: 1))
        let b = (position: [UInt8]([0x80]), id: OpID(counter: 1, replica: 9))
        let c = (position: [UInt8]([0x7F, 0xFF]), id: OpID(counter: 9, replica: 9))
        #expect(FractionalIndex.childOrder(b, a))
        #expect(FractionalIndex.childOrder(c, b))
        #expect(!FractionalIndex.childOrder(a, c))
        #expect(FractionalIndex.less([0x80], [0x80, 0x00]))
    }
}
