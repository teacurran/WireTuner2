import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The fallbacks of the collaboration, review and layers models: empty documents, missing nodes,
/// unknown authors, every menu item.
@Suite(.serialized) @MainActor struct CollaborationEdgeTests {
    @Test func layersOnAnEmptyDocumentAndEveryMenuItem() async {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Empty")
        let controller = DocumentWindowController(document: document, environment: environment.document)
        defer { controller.close() }
        let state = LayersPanelState()
        let empty = LayersPanelModel(document: document, editing: controller.objectEditing, state: state)
        #expect(empty.targets.isEmpty && empty.activeLayer == nil && empty.moveObjectsToCurrent() == nil)
        #expect(empty.hiddenActiveWarning == nil && empty.duplicate() == nil)
        await empty.newLayer().value
        let first = await document.perform(CreateLayer(name: "One")).value!.createdNodes[0]
        let model = LayersPanelModel(document: document, editing: controller.objectEditing, state: state)
        // The separator moved without crossing a layer changes nothing.
        #expect(model.move(fromOffsets: [model.rows.count - 1], toOffset: model.rows.count - 1) == nil)
        // A colour that has no sRGB form falls back to black.
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))
        #expect(LayersPanelModel.color(pattern).rgb.r == 0)
        for item in model.optionItems { item.run() }
        await document.settle()
        state.pendingRemoval = []
        let layer = LayerOrder(document.state).layer(first) ?? model.layers[0]
        for item in model.contextItems(layer) { item.run() }
        await document.settle()
        state.pendingRemoval = []
        withExtendedLifetime(environment) {}
    }

    @Test func reviewFallbacks() async throws {
        var world = ReviewWorld()
        let layer = world.base([Ops.create(parent: ReviewWorld.layers, position: [0x80], props: ReviewWorld.layer("Art"))])
        let a = world.base([Ops.create(parent: layer, position: [0x80], props: ReviewWorld.rect(width: 10))])
        let b = world.base([Ops.create(parent: layer, position: [0x81], props: ReviewWorld.rect(width: 10))])
        world.theirs([ReviewWorld.resize(a, width: 20)])
        world.theirs([ReviewWorld.resize(b, width: 20)])
        var other = world.remote[1]
        other.replica = 99
        let document = world.document()
        let harness = ReviewHarness()
        // An entry for a node that does not exist, with a paragraph of a text it does not have.
        var review = heldReview(OpID(counter: 999, replica: 9), properties: [])
        review.entries[0].paragraphs = [ParagraphRef(text: ReviewWorld.text, terminator: .zero)]
        review.entries[0].actions = [.useMine, .keepBoth]
        let model = ReviewSheetModel(review: review, merged: world.state, remote: world.remote + [other], context: harness.context(document))
        #expect(model.paragraphRows.isEmpty)
        #expect(model.perform(.useMine) == nil && model.perform(.keepBoth) == nil)
        #expect(model.perform(.useMine, paragraph: ReviewSheetModel.ParagraphRow(id: "p", field: ReviewWorld.text, ids: [], diff: ParagraphDiff(segments: [], mine: "", theirs: ""))) == nil)
        #expect(model.authorName(12345) == "someone")
        model.select("nothing")
        #expect(model.selectedRow?.id == model.rows.first?.id)
        model.setFilter(.theirs)
        #expect(model.rows.count == 2)
        model.setFilter(.mine)
        #expect(model.rows.isEmpty && model.previewImage() == nil && model.selectedRow == nil)
        #expect(ReviewPreview.image(node: a, states: [], size: Size(width: 10, height: 10)) == nil)
        #expect(ReviewPreview.image(node: OpID(counter: 999, replica: 9), states: [world.state], size: Size(width: 10, height: 10)) == nil)
        // A failure that is not a library error still says what happened.
        struct Odd: Error {}
        harness.work.failure = Odd()
        let failing = ReviewSheetModel(review: review, merged: world.state, context: harness.context(document))
        await failing.run(.keepBranch)
        #expect(failing.message != nil)
    }

    @Test func sessionsAndHeadlessFallbacks() async throws {
        let sessions = DocumentSessions(connector: nil)
        let handle = DocumentHandle.memory(title: "Busy")
        let session = sessions.session(for: handle)
        session.status.update(.syncing(1))
        await sessions.documentDidClose(handle).value
        // Releasing a background session stops it and closes the document.
        await sessions.release(handle.id)
        #expect(sessions.background.isEmpty)
        let another = DocumentHandle.memory(title: "Stop")
        let running = sessions.session(for: another)
        running.status.update(.uploadingBacklog(10))
        await sessions.documentDidClose(another).value
        await sessions.stopAll()
        #expect(sessions.background.isEmpty && sessions.sessions.isEmpty)
        sessions.signedIn()
    }
}
