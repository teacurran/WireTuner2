import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

@Suite(.serialized) @MainActor struct CollaborationViewTests {
    @Test func bannersAndCursorLabelsRedraw() async {
        let environment = TestEnvironment()
        let presence = StubPresenceModel()
        var document = environment.document
        document.makePresence = { _ in presence }
        let controller = DocumentWindowController(document: .memory(title: "Views"), environment: document)
        defer { controller.close() }
        let collaboration = controller.collaboration
        collaboration.labelTimeout = .milliseconds(5)
        presence.participants = [RemoteParticipant(id: "p", name: "Priya", colorIndex: 1, cursor: Point(x: 1, y: 1), spotlight: true)]
        #expect(await eventually { collaboration.labelTimeouts == 1 })
        collaboration.banner.warning = "Hidden"
        collaboration.banner.followText = "Following Priya"
        let banner = NSHostingView(rootView: CollaborationBannerView(model: collaboration.banner))
        banner.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        banner.layoutSubtreeIfNeeded()
        #expect(banner.fittingSize.height > 0 && collaboration.banner.banners.count == 1)
        withExtendedLifetime(environment) {}
    }

    @Test func theLayersListShowsItsWarningSheetAndRenameField() async {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Layers")
        let controller = DocumentWindowController(document: document, environment: environment.document)
        defer { controller.close() }
        let layer = await document.perform(CreateLayer(name: "Art")).value!.createdNodes[0]
        _ = await document.perform(SetLayerFlag([layer], .visible, false)).value
        controller.objectEditing.activeLayer = layer
        let state = LayersPanelState()
        let model = LayersPanelModel(document: document, editing: controller.objectEditing, state: state)
        #expect(model.hiddenActiveWarning != nil)
        state.renaming = layer
        state.pendingRemoval = [layer]
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 320, height: 320))
        window.contentView = NSHostingView(rootView: LayersList(model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.close()
        withExtendedLifetime(environment) {}
    }
}
