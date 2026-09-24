import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// PRINT-002: the archived NSPrintInfo (`SettingsProps.print_info`, local-only) is kept by the
/// local store across a relaunch and never enters the outbox, while print settings beside it do.
@Suite struct PrintInfoStoreTests {
    let scratch = Scratch()

    static func printInfo(_ store: LocalStore) async -> Data? {
        await store.read { DocumentPrintSettings($0).printInfo }
    }

    @Test func theArchiveSurvivesARelaunchAndNeverLeaves() async throws {
        let archive = Data((0..<600).map { UInt8($0 % 251) })
        let store = try await LocalStore.open(documentID: "P1", at: scratch.url(), options: options())
        _ = try await store.perform(SetPrintInfo(archive), recording: Fixture.recording())
        _ = try await store.perform(SetPrintSettings(.bleed(9)), recording: Fixture.recording())
        #expect(await Self.printInfo(store) == archive)
        let outbox = try await store.outbox()
        #expect(outbox.count == 2)
        #expect(outbox.allSatisfy { change in
            !LocalOnly.carries(change, schema: .generated) && change.ops.allSatisfy { $0.set.values.settings.printInfo.isEmpty }
        })
        #expect(outbox[1].ops[0].set.values.settings.print.bleed == 9)
        #expect(try await store.pendingUpload().allSatisfy { !LocalOnly.carries($0, schema: .generated) })
        try await store.close()

        let reopened = try await LocalStore.open(documentID: "P1", at: scratch.url(), options: options())
        #expect(await Self.printInfo(reopened) == archive)
        #expect(await reopened.read { DocumentPrintSettings($0).bleed } == 9)
        // Another Mac receiving everything this one sends has no archive.
        var other = EngineState()
        for change in try await reopened.outbox() { other.apply(change) }
        #expect(DocumentPrintSettings(other).printInfo == nil && DocumentPrintSettings(other).bleed == 9)
        try await reopened.close()
    }
}
