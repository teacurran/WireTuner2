import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto

/// The Animation panel's *Background* (WEB-017's model half).
@Suite struct AnimationBackgroundTests {
    @Test func theBackgroundReadsPageColorUntilWrittenAndKeepsLoopingOn() throws {
        var a = Replica(0xB)
        #expect(AnimationFrameBackground.current(in: a.state) == .pageColor)
        let change = try #require(try a.perform(SetAnimationBackground(.transparent)))
        #expect(change.label == "Animation Settings" && change.ops.count == 1)
        #expect(AnimationFrameBackground.current(in: a.state) == .transparent && AnimationInfo(a.state).loop)
        try a.perform(SetAnimationSettings(loop: false))
        try a.perform(SetAnimationBackground(.white))
        #expect(AnimationFrameBackground.current(in: a.state) == .white && !AnimationInfo(a.state).loop)
        try a.perform(SetAnimationBackground(.pageColor))
        #expect(AnimationFrameBackground.current(in: a.state) == .pageColor)
        #expect(AnimationFrameBackground(.unspecified) == .pageColor && AnimationFrameBackground.allCases.count == 3)
    }
}
