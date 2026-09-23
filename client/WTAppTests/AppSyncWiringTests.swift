import AppKit
import Foundation
import Testing
import WTModel
import WTSync
@testable import WireTuner

@Suite(.serialized) @MainActor struct AppSyncWiringTests {
    @Test func theAppGivesEveryDocumentASessionAndQuitsCleanly() async throws {
        let suite = TestDefaults()
        let stores = TestStores.directory()
        let connector = FakeSyncConnector()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, syncConnector: connector, storesDirectory: { stores })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(await eventually { delegate.activeDocumentWindow != nil })
        let window = try #require(delegate.activeDocumentWindow)
        let session = try #require(window.session)
        #expect(delegate.sessions.sessions[window.documentHandle.id] === session)
        #expect(await eventually { session.status.state == .saved })
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        let environment = delegate.documents.environment
        #expect(environment.userName() == "" && environment.reviewWork() == nil)
        // A document opened by id (the review sheet's copy) gets a window and a session.
        environment.openDocument("copy-id", "Copy")
        #expect(delegate.documents.document(id: "copy-id")?.title == "Copy")
        _ = try await environment.openModel("copy-id")
        // The popover's Sign In… and Export a Package… reach the app (the save panel is not run).
        delegate.packages.runSavePanel = { _, _ in nil }
        session.onExportPackage()
        delegate.sessions.onSignIn()
        #expect(delegate.commands.contains(CollaborationCommands.ID.reviewMerge))
        // Closing the windows ends the sessions.
        for controller in delegate.documents.allWindowControllers { controller.window?.close() }
        #expect(await eventually { delegate.sessions.sessions.isEmpty })
        delegate.activeSelection.presence = nil
    }
}
