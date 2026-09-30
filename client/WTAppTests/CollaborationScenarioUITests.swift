import AppKit
import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WireTuner

/// One guide case in the app (COLLAB-003's UI half): my offline work against Priya's, measured by
/// WTSync's divergence rules, held for review in my document window, the review sheet's rows
/// read as a person reads them, one choice made through the sheet's model, and Priya's replica --
/// the base, her work, then my upload and my choice as the server sequences them -- ending on my
/// state hash.
@MainActor
final class ReviewScenario {
    var world = ReviewWorld()
    private(set) var controller: DocumentWindowController?
    private(set) var handle: DocumentHandle?
    private var environment: TestEnvironment?
    private var session: DocumentSession?
    /// Changes my window made after the review opened (the choices).
    private(set) var choices: [Wiretuner_Doc_V1_Change] = []
    private var token: DocumentHandle.ObservationToken?

    init() {}

    /// Opens my window over the merged state and holds the review in it.
    func present() async throws -> ReviewSheetModel {
        let environment = TestEnvironment()
        let handle = world.document()
        var document = environment.document
        let session = DocumentSession(document: handle, connector: nil, localUserID: "me")
        document.session = { _ in session }
        document.reviewWork = { RecordingWork() }
        let controller = DocumentWindowController(document: handle, environment: document)
        token = handle.observe { [weak self] change in
            if change.summary.origin != .remote, let applied = change.change, !applied.ops.isEmpty { self?.choices.append(applied) }
        }
        self.environment = environment
        self.session = session
        self.handle = handle
        self.controller = controller
        session.handle(.reviewNeeded(world.measure()))
        #expect(await eventually { controller.collaboration.review.isShown })
        return try #require(controller.collaboration.review.model)
    }

    /// The conflict rows: "kind [attributes]" -- the attribute names each property's title, or
    /// for a row without properties the attributes each side wrote.
    static func rows(_ model: ReviewSheetModel) -> [String] {
        model.rows.compactMap { row -> String? in
            guard let entry = row.entry else { return nil }
            var names = entry.properties.isEmpty
                ? Set((entry.localPaths + entry.remotePaths).map { RegisterNames.title($0) })
                : Set(entry.properties.map { ReviewSheetModel.title($0.property) })
            if !entry.paragraphs.isEmpty { names.insert("Text") }
            return "\(row.kind) [\(names.sorted().joined(separator: ", "))]"
        }
    }

    /// Runs `action` on the row of `node` and waits for its change.
    func choose(_ action: ReviewAction, on node: OpID, in model: ReviewSheetModel) async {
        model.select(model.rows.first { $0.node == node }?.id)
        #expect(model.actions.contains(action), "\(action) offered")
        _ = await model.perform(action)?.value
        await handle?.settle()
    }

    /// Priya's replica after the server sequenced my offline work and my choices behind hers.
    func priya() -> EngineState {
        var state = EngineState()
        var seq: UInt64 = 0
        for change in world.baseChanges + world.remote + world.local + choices {
            seq += 1
            state.apply(change, serverSeq: seq)
        }
        return state
    }

    /// Both replicas hold one state.
    func expectConverged(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(handle?.state.stateHash == priya().stateHash, "my window and Priya's replica differ", sourceLocation: sourceLocation)
    }

    func close() {
        if let token { handle?.stopObserving(token) }
        controller?.collaboration.review.close()
        controller?.close()
        withExtendedLifetime(environment) {}
        withExtendedLifetime(session) {}
    }
}

extension ReviewWorld {
    static let rectLocked = RegisterPath([NodeKind.rect.rawValue, 1, 3])

    static func lock(_ node: OpID) -> Wiretuner_Doc_V1_Op {
        var props = rect(width: 0)
        props.rect.common.locked = true
        return Ops.set(node, [rectLocked], values: props)
    }

    /// A layer "Art" with one rectangle "Logo mark" (and a second layer "Print"); the rectangle.
    mutating func logo() -> (layer: OpID, print: OpID, logo: OpID) {
        let layer = base([Ops.create(parent: Self.layers, position: [0x80], props: Self.layer("Art"))])
        let print = base([Ops.create(parent: Self.layers, position: [0x81], props: Self.layer("Print"))])
        let logo = base([Ops.create(parent: layer, position: [0x80], props: Self.rect(width: 10, name: "Logo mark"))])
        return (layer, print, logo)
    }
}

/// COLLAB-003's UI scenarios as app-hosted tests (XCUITest does not run on the build machine):
/// each guide case reaches my window as a held review, the sheet lists exactly the rows the guide
/// names, a choice is made through the sheet, and Priya's replica converges with mine.  The
/// simulator half (`CollaborationCaseScenarioTests`) runs the same cases across two server nodes
/// with packet loss.
@Suite(.serialized) @MainActor struct CollaborationScenarioUITests {
    @Test func sameAttributeOfflineUseMine() async throws {
        let s = ReviewScenario()
        defer { s.close() }
        let logo = s.world.logo().logo
        s.world.mine([ReviewWorld.rename(logo, "Brand mark")])
        s.world.theirs([ReviewWorld.rename(logo, "Wordmark")])
        let model = try await s.present()
        #expect(ReviewScenario.rows(model) == ["Same attribute [Name]"])
        await s.choose(.useMine, on: logo, in: model)
        #expect(s.handle?.state.store.register(logo, ReviewWorld.rectName) != nil)
        #expect(ObjectNaming.name(of: logo, in: try #require(s.handle).state) == "Brand mark")
        s.expectConverged()
    }

    @Test func dragAgainstDragOfflineKeepsBothCopies() async throws {
        let s = ReviewScenario()
        defer { s.close() }
        let (layer, _, logo) = s.world.logo()
        s.world.mine([ReviewWorld.move(logo, tx: 30)])
        s.world.theirs([ReviewWorld.move(logo, tx: 70)])
        let model = try await s.present()
        #expect(ReviewScenario.rows(model) == ["Same attribute [Transform]"])
        let start = try #require(s.handle).state
        let before = start.store.children(layer).filter(start.store.exists).count
        await s.choose(.keepBoth, on: logo, in: model)
        let state = try #require(s.handle).state
        #expect(state.store.children(layer).filter(state.store.exists).count == before + 1, "the copy sits beside the original")
        s.expectConverged()
    }

    @Test func anEditAgainstADeleteIsRestored() async throws {
        let s = ReviewScenario()
        defer { s.close() }
        let (_, print, logo) = s.world.logo()
        s.world.mine([Ops.move(logo, parent: print, position: [0x80])])
        s.world.theirs([Ops.setDeleted(logo)])
        let model = try await s.present()
        #expect(ReviewScenario.rows(model) == ["Edited and deleted [Deleted]"])
        #expect(try #require(s.handle).state.store.deleted(logo)?.current.value == true, "deleted in the merge")
        await s.choose(.restore, on: logo, in: model)
        let state = try #require(s.handle).state
        #expect(state.store.deleted(logo)?.current.value == false && state.store.placement(logo)?.parent == print, "back, on the layer it was moved to")
        s.expectConverged()
    }

    @Test func aLockAgainstAnOfflineEditKeepsTheirs() async throws {
        let s = ReviewScenario()
        defer { s.close() }
        let logo = s.world.logo().logo
        s.world.mine([ReviewWorld.move(logo, tx: 25)])
        s.world.theirs([ReviewWorld.lock(logo)])
        let model = try await s.present()
        #expect(ReviewScenario.rows(model) == ["Both edited [Locked, Transform]"])
        let choices = s.choices.count
        await s.choose(.useTheirs, on: logo, in: model)
        #expect(s.choices.count == choices, "Use theirs writes nothing")
        s.expectConverged()
    }

    @Test func bothMovedToDifferentLayers() async throws {
        let s = ReviewScenario()
        defer { s.close() }
        let (layer, print, logo) = s.world.logo()
        let third = s.world.base([Ops.create(parent: ReviewWorld.layers, position: [0x82], props: ReviewWorld.layer("Web"))])
        s.world.mine([Ops.move(logo, parent: print, position: [0x80])])
        s.world.theirs([Ops.move(logo, parent: third, position: [0x80])])
        let model = try await s.present()
        #expect(ReviewScenario.rows(model) == ["Both moved [Position]"])
        #expect(try #require(s.handle).state.store.placement(logo)?.parent != layer)
        await s.choose(.useMine, on: logo, in: model)
        #expect(try #require(s.handle).state.store.placement(logo)?.parent == print)
        s.expectConverged()
    }

    @Test func doneUploadsTheMergeWithTheChoicesMade() async throws {
        let s = ReviewScenario()
        defer { s.close() }
        let logo = s.world.logo().logo
        s.world.mine([ReviewWorld.resize(logo, width: 30)])
        s.world.theirs([ReviewWorld.resize(logo, width: 50)])
        let model = try await s.present()
        #expect(ReviewScenario.rows(model) == ["Same attribute [Size]"])
        await s.choose(.useTheirs, on: logo, in: model)
        s.expectConverged()
        await model.done()
        #expect(model.isFinished)
    }
}
