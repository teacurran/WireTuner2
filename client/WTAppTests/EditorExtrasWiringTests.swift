import AppKit
import Foundation
import Testing
import WTInterchange
import WTModel
@testable import WireTuner

/// The client-ui remainders' app wiring (`AppDelegate+EditorExtras.swift`): a launched delegate
/// installs the hooks, commands and panels, and each hook reaches that delegate's documents.
@Suite(.serialized) @MainActor struct EditorExtrasWiringTests {
    @Test func aLaunchedDelegateWiresTheExtras() async throws {
        let suite = TestDefaults()
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        // Preferences and the front document reach the hooks.
        #expect(PointEditing.smoother() == delegate.preferences[PreferenceCatalog.General.smootherEditing])
        #expect(MeasurementLink.shared.enabled() == delegate.preferences[PreferenceCatalog.General.optionMeasurements])
        #expect(LayerFrames.playingLayer(window.documentHandle) == nil)
        #expect(CornerWidgetLayer.isShown())
        CornerWidgetLayer.showPanel()
        #expect(ExternalEditing.shared.window() === window && ExternalEditing.shared.cached(Data([1, 2, 3])) == nil)
        ExternalEditing.shared.showPanel(window)
        for panel in window.window?.childWindows ?? [] { panel.close() }
        #expect(RasterEffectSettingsFeatures.shared.window() === window)
        #expect(delegate.panels.descriptor(for: "object")?.optionsMenu().isEmpty == false)
        // History and merging: offline while testing.
        let history = HistoryPanelModel.shared
        #expect(history.window() === window && history.client() == nil)
        #expect(delegate.panels.descriptor(for: HistoryPanelModel.panelID) != nil)
        #expect(delegate.commands.validate(CollaborationFeatures.ID.mergeBranch)?.isEnabled == false)
        #expect(delegate.menuTarget?.perform("file.showHistory") == true)
        #expect(delegate.commands.validate("file.nameVersion")?.isEnabled == true)
        // Corner widgets toggle in this Mac's defaults and redraw every window.
        #expect(delegate.menuTarget?.perform(CornerWidgetCommands.id) == true)
        #expect(!CornerWidgetLayer.isShown())
        #expect(delegate.menuTarget?.perform(CornerWidgetCommands.id) == true)
        #expect(delegate.commands.contains(ContextMenuCatalog.ID.closePath))
        // A window's author lookup for the Library's change log.
        SymbolChangeLog.follow(window) { _ in nil }
        // Asynchronous hooks: a document not here has seq 0; a missing file does not convert.
        let seq = await BranchMergeCommand.parentSeq("not-open")
        #expect(seq == 0)
        await #expect(throws: (any Error).self) { _ = try await SvgAnimationFileActions.convert(URL(fileURLWithPath: "/nonexistent/anim.svg")) }

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
        suite.remove()
    }
}
