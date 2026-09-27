import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// COLLAB-038's wait: `SyncClient.isCaughtUp` holds only once the session is up and the log is
/// applied through the head its `Welcome` named -- a deep link opened while the document is 5,000
/// changes behind selects after the catch-up, not before.
@Suite(.timeLimit(.minutes(3))) struct CaughtUpTests {
    @Test func caughtUpOnlyOnceTheLogIsAppliedToTheHead() async throws {
        let server = FakeSyncServer()
        let count = 5_000
        for seq in 1...count {
            try await server.inject(remoteChange(seq: UInt64(seq)))
        }
        let harness = try await Harness(server: server)
        #expect(await harness.client.isCaughtUp == false, "not before the session")
        await harness.client.start()
        let deadline = ContinuousClock.now + .seconds(120)
        while await !harness.client.isCaughtUp, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await harness.store.lastServerSeq == UInt64(count), "every change is applied when it says so")
        try await harness.stop()
    }
}
