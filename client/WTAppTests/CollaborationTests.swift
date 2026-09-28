import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// A change by another replica, as the server would relay it.
func remoteChange(_ ops: [Wiretuner_Doc_V1_Op], replica: UInt64 = 0xBEEF, seq: UInt64 = 1, counter: UInt64 = 1_000_000) -> Wiretuner_Doc_V1_Change {
    var change = Wiretuner_Doc_V1_Change()
    change.replica = replica
    change.seq = seq
    change.startCounter = counter
    change.ops = ops
    return change
}

func bitmap(width: Int = 400, height: Int = 300) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

@Suite(.serialized) @MainActor struct PresenceModelTests {
    @Test func theAdapterMapsEveryField() async throws {
        let model = PresenceModel(localUserID: "me", clearAfter: .milliseconds(10))
        let adapter = PresenceAdapter(source: model)
        var notified = 0
        let token = adapter.observe { notified += 1 }
        var update = Wiretuner_Sync_V1_PresenceUpdate()
        update.user.userID = "u1"
        update.user.displayName = "Priya Shah"
        update.user.role = .editor
        update.colorIndex = 3
        update.state = .idle
        update.cursor.x = 5
        update.cursor.y = 6
        update.viewport.visible = .with { $0.x = 1; $0.y = 2; $0.width = 30; $0.height = 40 }
        update.viewport.zoom = 2
        update.tool = "pen"
        update.selection = [OpID(counter: 1, replica: 2).proto]
        update.selectionCount = 300
        update.subSelection = [LocalPresencePublisher.pointPath(contour: OpID(counter: 3, replica: 4), point: OpID(counter: 5, replica: 6)), RegisterPath([20]).proto]
        update.editing = [OpID(counter: 1, replica: 2).proto]
        update.caret.node = OpID(counter: 7, replica: 8).proto
        update.caret.position = OpID(counter: 9, replica: 8).elementID
        update.spotlight = true
        update.followingUserID = "u2"
        update.branchID = "b"
        model.apply(update)
        var anonymous = Wiretuner_Sync_V1_PresenceUpdate()
        anonymous.user.userID = "u2"
        model.apply(anonymous)
        let participant = try #require(adapter.participants.first)
        #expect(participant.name == "Priya Shah" && participant.colorIndex == 3 && participant.role == "Editor" && participant.isIdle)
        #expect(participant.cursor == Point(x: 5, y: 6) && participant.viewport == Rect(x: 1, y: 2, width: 30, height: 40) && participant.zoom == 2)
        #expect(participant.tool == "pen" && participant.selectionCount == 300 && participant.editing.count == 1)
        #expect(participant.points == [RemoteParticipant.PointElement(contour: OpID(counter: 3, replica: 4), point: OpID(counter: 5, replica: 6))])
        #expect(participant.caret?.node == SelectionID(OpID(counter: 7, replica: 8)) && participant.spotlight && participant.followingUserID == "u2")
        #expect(participant.branchID == "b")
        #expect(adapter.participants[1].name == "Someone")
        #expect(notified == 2)
        model.connectionChanged(false)
        #expect(adapter.participants.allSatisfy { $0.isFrozen })
        #expect(await eventually { adapter.isOffline })
        adapter.stopObserving(token)
        adapter.detach()
        adapter.detach()
        for (role, title) in [(Wiretuner_Account_V1_DocumentRole.owner, "Owner"), (.commenter, "Commenter"), (.viewer, "Viewer"), (.unspecified, "")] {
            #expect(PresenceAdapter.roleTitle(role) == title)
        }
    }

    @Test func activityTextFollowsTheGuide() async {
        let base = RemoteParticipant(id: "p", name: "Priya", colorIndex: 0)
        var p = base
        p.isFrozen = true
        #expect(AvatarStripModel.activity(p) == "Reconnecting")
        p = base
        p.isIdle = true
        #expect(AvatarStripModel.activity(p) == "Idle")
        p = base
        p.branchID = "b1"
        #expect(AvatarStripModel.activity(p, branch: { _ in "Autumn palette" }) == "Editing on branch \"Autumn palette\"")
        #expect(AvatarStripModel.activity(p) == "Editing on branch \"a branch\"")
        p = base
        p.editing = [SelectionID(OpID(counter: 1, replica: 1))]
        #expect(AvatarStripModel.activity(p, object: { _ in "Logo mark" }) == "Editing Logo mark")
        #expect(AvatarStripModel.activity(p) == "Editing an object")
        #expect(AvatarStripModel.activity(p, commentAnchor: { _ in "Logo mark" }) == "Commenting on Logo mark")
        p.editing.append(SelectionID(OpID(counter: 2, replica: 1)))
        #expect(AvatarStripModel.activity(p) == "Editing 2 objects")
        p = base
        p.selectionCount = 1
        #expect(AvatarStripModel.activity(p) == "Selected 1 object")
        p.selectionCount = 3
        #expect(AvatarStripModel.activity(p) == "Selected 3 objects")
        p = base
        #expect(AvatarStripModel.activity(p, page: { _ in 1 }) == "Viewing page 2")
        #expect(AvatarStripModel.activity(p) == "Viewing the pasteboard")

        // Against a document: objects by name, pages by the view's centre, comment anchors.
        let fixture = await SelectionFixture.make()
        let document = fixture.document
        p = base
        p.editing = [fixture.a]
        #expect(AvatarStripModel.activity(p, in: document) == "Editing Rectangle")
        p = base
        p.viewport = Rect(x: 10, y: 10, width: 20, height: 20)
        #expect(AvatarStripModel.activity(p, in: document) == "Viewing page 1")
        p.viewport = Rect(x: 5000, y: 5000, width: 20, height: 20)
        #expect(AvatarStripModel.activity(p, in: document) == "Viewing the pasteboard")
        var thread = Wiretuner_Doc_V1_NodeProps()
        thread.commentThread.anchor.id = fixture.a.opID.proto
        let anchored = await document.perform(OpsCommand("Thread", ops: [Ops.create(parent: WellKnown.document, position: [0x80], props: thread)])).value
        var loose = Wiretuner_Doc_V1_NodeProps()
        loose.commentThread = Wiretuner_Doc_V1_CommentThreadProps()
        let unanchored = await document.perform(OpsCommand("Thread", ops: [Ops.create(parent: WellKnown.document, position: [0x81], props: loose)])).value
        p = base
        p.editing = [SelectionID(OpID(counter: anchored!.startCounter, replica: anchored!.replica))]
        #expect(AvatarStripModel.activity(p, in: document) == "Commenting on Rectangle")
        p.editing = [SelectionID(OpID(counter: unanchored!.startCounter, replica: unanchored!.replica))]
        #expect(AvatarStripModel.activity(p, in: document) == "Commenting on the page")
    }

    @Test func theStripShowsSixThenOverflowsAndHasAnOwnMenu() {
        let model = AvatarStripModel()
        model.participants = (0..<8).map { RemoteParticipant(id: "p\($0)", name: "Person \($0)", colorIndex: $0, isIdle: $0 == 1) }
        #expect(model.shown.count == 6 && model.overflow.count == 2 && model.overflowTitle == "+2")
        var followed: [String] = []
        var stops = 0, spotlights = 0
        var toggled: [String] = []
        model.onFollow = { followed.append($0) }
        model.onStopFollowing = { stops += 1 }
        model.onSpotlight = { spotlights += 1 }
        model.displayOptions = { [AvatarStripModel.DisplayOption(id: "cursors", title: "Show others' cursors", isOn: true)] }
        model.onDisplayOption = { toggled.append($0) }
        #expect(model.ownMenuTitles == ["Spotlight Me", "Show others' cursors"])
        model.followingID = "p0"
        model.isSpotlighting = true
        #expect(model.ownMenuTitles == ["Stop Spotlighting", "Stop Following", "Show others' cursors"])
        AvatarStripView.follow(model, "p3")()
        for title in model.ownMenuTitles + ["Unknown"] { AvatarStripView.ownAction(model, title)() }
        #expect(followed == ["p3"] && stops == 1 && spotlights == 1 && toggled == ["cursors"])
        model.localName = "Sam Lee"
        #expect(AvatarStripView.card(model.participants[0], model) == "Person 0 · Viewing the pasteboard")
        for host in [NSHostingView(rootView: AvatarStripView(model: model)) as NSView, NSHostingView(rootView: AvatarView(participant: model.participants[1], model: model))] {
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0)
        }
        model.isOffline = true
        let offline = NSHostingView(rootView: AvatarStripView(model: model))
        offline.layoutSubtreeIfNeeded()
        #expect(offline.fittingSize.width > 0)
        model.participants = []
        #expect(model.overflowTitle == nil)
    }

    @Test func theSyncIndicatorExplainsEachState() {
        let model = SyncIndicatorModel()
        #expect(model.lastSyncedText() == "Not fully synced yet on this Mac")
        model.details.lastSynced = Date(timeIntervalSince1970: 0)
        #expect(model.lastSyncedText(now: Date(timeIntervalSince1970: 180)).hasPrefix("Last fully synced"))
        #expect(model.collaboratorsText == nil)
        model.details.collaborators = ["Priya"]
        #expect(model.collaboratorsText == "Priya also has it open")
        model.details.collaborators = ["Priya", "Tom", "Ana"]
        #expect(model.collaboratorsText == "Priya, Tom and Ana also have it open")
        let states: [SyncState] = [.saved, .readOnly(.role), .error("disk"), .needsReview, .needsSignIn, .storageFull(1), .offline(2)]
        let explanations = states.map { state -> String? in
            model.state = state
            model.details.errorDetail = state == .error("disk") ? "disk" : nil
            return model.explanation
        }
        #expect(explanations[0] == nil && explanations.dropFirst().allSatisfy { $0 != nil })
        model.state = .error("x")
        model.details.errorDetail = nil
        #expect(model.explanation == "Something is wrong that WireTuner cannot fix by retrying.")
        var actions: [SyncAction] = []
        model.onAction = { actions.append($0) }
        model.togglePopover()
        #expect(model.isPopoverShown)
        SyncPopoverView.run(model, .retryNow)()
        #expect(actions == [.retryNow] && !model.isPopoverShown)
        TitlebarCollaborationView.toggle(model)()
        #expect(model.isPopoverShown)
        for view in [NSHostingView(rootView: SyncPopoverView(model: model)) as NSView,
                     NSHostingView(rootView: TitlebarCollaborationView(avatars: AvatarStripModel(), sync: model))] {
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0)
        }
        model.state = .saved
        NSHostingView(rootView: SyncPopoverView(model: model)).layoutSubtreeIfNeeded()
    }
}

@Suite(.serialized) @MainActor struct PresenceOverlayTests {
    @Test func cursorsLabelsPointsCaretsAndFlashes() async throws {
        let fixture = await SelectionFixture.make()
        let document = fixture.document
        let overlay = PresenceOverlay(document: document, viewport: SelectionFixture.viewport)
        let clock = CursorLabelClock()
        var now = Date(timeIntervalSince1970: 100)
        clock.now = { now }
        let path = try #require(await document.addPath([Point(x: 10, y: 200), Point(x: 60, y: 220)]))
        let contour = try #require(document.path(path)?.contours.first)
        var priya = RemoteParticipant(id: "p", name: "Priya", colorIndex: 1, selection: [path, fixture.a], cursor: Point(x: 50, y: 60), tool: "pen")
        priya.points = [RemoteParticipant.PointElement(contour: contour.id, point: contour.points[0].id)]
        priya.editing = [fixture.a]
        priya.caret = RemoteCaret(node: fixture.b, position: .zero)
        var tom = RemoteParticipant(id: "t", name: "Tom", colorIndex: 2, cursor: Point(x: 10, y: 10), isFrozen: true)
        tom.caret = RemoteCaret(node: SelectionID(OpID(counter: 999, replica: 9)), position: .zero)
        let ghost = RemoteParticipant(id: "g", name: "Ghost", colorIndex: 3)
        #expect(clock.update([priya, tom, ghost]))
        #expect(!clock.update([priya, tom, ghost]))
        let cursors = overlay.cursors([priya, tom, ghost], options: PresenceDisplayOptions(), clock: clock)
        #expect(cursors.map(\.label) == ["Priya · Pen", "Tom"] && cursors[1].faded)
        #expect(overlay.cursors([priya], options: PresenceDisplayOptions(showNames: false), clock: clock).first?.label == nil)
        #expect(overlay.cursors([priya], options: PresenceDisplayOptions(showCursors: false), clock: clock).isEmpty)
        now = now.addingTimeInterval(CursorLabelClock.labelTimeout + 1)
        #expect(overlay.cursors([priya], options: PresenceDisplayOptions(), clock: clock).first?.label == nil)
        #expect(!clock.showsLabel("ghost"))
        #expect(overlay.points([priya]).count == 1)
        #expect(overlay.carets([priya, tom]).count == 1)

        let flashes = AttributionFlashController()
        flashes.now = { now }
        flashes.clearDelay = .milliseconds(1)
        var redraws = 0
        flashes.onChange = { redraws += 1 }
        let change = remoteChange([ReviewWorld.resize(fixture.a.opID, width: 70)])
        flashes.changeApplied(change, author: nil)
        #expect(flashes.flashes.isEmpty)
        flashes.isEnabled = { false }
        flashes.changeApplied(change, author: SessionAuthor(name: "Priya", colorIndex: 1))
        #expect(flashes.flashes.isEmpty)
        flashes.isEnabled = { true }
        flashes.changeApplied(change, author: SessionAuthor(name: "Priya", colorIndex: 1))
        flashes.changeApplied(remoteChange([Ops.move(fixture.a.opID, parent: WellKnown.layers, position: [1])]), author: SessionAuthor(name: "Priya", colorIndex: 1))
        let flash = try #require(flashes.active().first)
        #expect(flash.label == "Priya · Size, Position" && redraws == 1)
        #expect(flashes.progress(flash) == 0)
        let pulses = overlay.flashes(flashes.active(), progress: flashes.progress)
        #expect(pulses.count == 1 && pulses[0].alpha == 1)
        #expect(overlay.flashes([AttributionFlashController.Flash(node: SelectionID(OpID(counter: 9, replica: 9)), author: "x", colorIndex: 0, attributes: [], started: now)], progress: { _ in 0 }).isEmpty)
        #expect(AttributionFlashController.Flash(node: fixture.a, author: "Tom", colorIndex: 0, attributes: [], started: now).label == "Tom")

        let context = bitmap()
        overlay.draw(in: context, participants: [priya, tom], options: PresenceDisplayOptions(), clock: clock, flashes: flashes.active(),
                     progress: flashes.progress, following: PresencePalette.color(at: 1))
        overlay.draw(in: context, participants: [priya], options: PresenceDisplayOptions(showSelections: false), clock: clock)
        #expect(await eventually { redraws >= 2 })
        now = now.addingTimeInterval(2)
        #expect(flashes.active().isEmpty)
        #expect(ToolID("pen").displayTitle == "Pen" && ToolID("zzz").displayTitle == "Zzz")
        #expect(PresenceOverlay.arrow(at: Point(x: 0, y: 0)).boundingBox.width > 0)
    }

    @Test func registerNamesReadTheMergeTable() {
        #expect(RegisterNames.title(RegisterPath([NodeKind.rect.rawValue, 2])) == "Size")
        #expect(RegisterNames.title(RegisterPath([NodeKind.rect.rawValue, 1, 4])) == "Transform")
        #expect(RegisterNames.title(RegisterPath([NodeKind.rect.rawValue, 4, 1])) == "Fills")
        #expect(RegisterNames.title(RegisterPath([9999])) == "Attribute")
        #expect(RegisterNames.title(RegisterPath([NodeKind.rect.rawValue, 9999])) == "Rect")
        #expect(RegisterNames.humanized("stroke_width") == "Stroke width" && RegisterNames.humanized("") == "")
        let node = OpID(counter: 5, replica: 5)
        let path = RegisterPath([NodeKind.path.rawValue, 2])
        let ops: [Wiretuner_Doc_V1_Op] = [
            Ops.create(parent: WellKnown.layers, position: [1], props: Wiretuner_Doc_V1_NodeProps()),
            Ops.set(node, [RegisterPath([NodeKind.rect.rawValue, 2]), RegisterPath([NodeKind.rect.rawValue, 2])], values: Wiretuner_Doc_V1_NodeProps()),
            Ops.move(node, parent: WellKnown.layers, position: [1]), Ops.setDeleted(node), Ops.setDeleted(node, false),
            Ops.elementInsert(node, path, positions: [[1]], values: Wiretuner_Doc_V1_NodeProps()),
            Ops.elementMove(node, path.element(node), position: [1]), Ops.elementDelete(node, [path.element(node)]),
            Ops.textInsert(node, ReviewWorld.text, "a"), Ops.textDelete(node, ReviewWorld.text, first: node, count: 1), Ops.noop(),
        ]
        var mark = Wiretuner_Doc_V1_Op()
        mark.textMark.node = node.proto
        var empty = Wiretuner_Doc_V1_Op()
        empty.elementInsert.node = node.proto
        var bare = Wiretuner_Doc_V1_Op()
        bare.elementMove.node = node.proto
        var none = Wiretuner_Doc_V1_Op()
        none.elementDelete.node = node.proto
        let touched = RegisterNames.touched(by: remoteChange(ops + [mark, empty, bare, none]))
        #expect(touched.first { $0.node == node }?.attributes == ["Size", "Position", "Deleted", "Restored", "Contours", "Text", "Text style", "Points"])
    }

    @Test func objectsAreNamedAsThePanelNamesThem() async {
        let fixture = await SelectionFixture.make()
        let state = fixture.document.state
        #expect(ObjectNaming.name(of: fixture.a.opID, in: state) == "Rectangle")
        #expect(ObjectNaming.name(of: fixture.group.opID, in: state) == "Group")
        #expect(ObjectNaming.name(of: WellKnown.settings, in: state) == "Document settings")
        #expect(ObjectNaming.name(of: OpID(counter: 999, replica: 9), in: state) == "Object")
        var props = Wiretuner_Doc_V1_NodeProps()
        for (build, title) in [({ (p: inout Wiretuner_Doc_V1_NodeProps) in p.path = Wiretuner_Doc_V1_PathProps() }, "Path"),
                               ({ $0.ellipse = Wiretuner_Doc_V1_EllipseProps() }, "Ellipse"), ({ $0.polygon = Wiretuner_Doc_V1_PolygonProps() }, "Polygon"),
                               ({ $0.layer = Wiretuner_Doc_V1_LayerProps() }, "Layer"), ({ $0.text = Wiretuner_Doc_V1_TextProps() }, "Text"),
                               ({ $0.image = Wiretuner_Doc_V1_ImageProps() }, "Image")] {
            build(&props)
            #expect(ObjectNaming.kindTitle(props) == title)
        }
        #expect(ObjectNaming.common(Wiretuner_Doc_V1_NodeProps()) == nil)
    }

    @Test func outgoingPresenceIsWrittenForTheSession() async {
        let presence = LocalPresence()
        let publisher = LocalPresencePublisher(presence: presence)
        publisher.pointer(Point(x: 3, y: 4))
        publisher.viewport(Viewport(size: Size(width: 100, height: 50)))
        publisher.tool(.pen)
        let id = SelectionID(OpID(counter: 1, replica: 1))
        let point = PointReference(node: id.node, contour: OpID(counter: 2, replica: 1), point: OpID(counter: 3, replica: 1))
        publisher.selection(Selection().applying([id, SelectionID(OpID(counter: 4, replica: 1))], sub: [id: .points([point])], mode: .replace))
        publisher.editing([id])
        publisher.spotlight(true)
        publisher.following("u2")
        publisher.input()
        var update = await presence.presence()
        #expect(update?.cursor.x == 3 && update?.tool == "pen" && update?.selectionCount == 2 && update?.subSelection.count == 1)
        #expect(update?.editing.count == 1 && update?.spotlight == true && update?.followingUserID == "u2" && update?.viewport.zoom == 1)
        publisher.pointer(nil)
        publisher.following(nil)
        publisher.setSharing(false)
        update = await presence.presence()
        #expect(update?.hasCursor == false && update?.followingUserID == "" && update?.selection.isEmpty == true)
    }
}

@Suite(.serialized) @MainActor struct FollowTests {
    @Test func followingTracksTheTargetAndEnds() {
        let follow = FollowController()
        var applied: [Rect] = []
        var changes = 0
        follow.apply = { visible, _ in applied.append(visible) }
        follow.onChange = { changes += 1 }
        var priya = RemoteParticipant(id: "p", name: "Priya", colorIndex: 1, viewport: Rect(x: 0, y: 0, width: 10, height: 10), zoom: 2)
        follow.follow(priya)
        #expect(follow.isFollowing && follow.barText == "Following Priya" && applied.count == 1)
        priya.viewport = Rect(x: 5, y: 5, width: 10, height: 10)
        follow.presenceDidChange([priya], isOffline: false)
        #expect(applied.last == priya.viewport)
        priya.viewport = nil
        follow.presenceDidChange([priya], isOffline: false)
        // Switching to a branch ends following with an offer.
        priya.branchID = "b1"
        follow.presenceDidChange([priya], isOffline: false)
        #expect(!follow.isFollowing && follow.branchOffer?.branchID == "b1" && follow.barText == "Priya switched to a branch")
        #expect(follow.stop() && !follow.stop())
        priya.branchID = ""
        follow.follow(priya)
        follow.presenceDidChange([], isOffline: false)
        #expect(!follow.isFollowing)
        follow.follow(priya)
        follow.presenceDidChange([priya], isOffline: true)
        #expect(!follow.isFollowing && follow.barText == nil)
        follow.toggleSpotlight()
        #expect(follow.isSpotlighting && changes > 0)
    }

    @Test func spotlightsRaiseOneBannerPerRisingEdge() {
        let follow = FollowController()
        var tom = RemoteParticipant(id: "t", name: "Tom", colorIndex: 2, viewport: Rect(x: 0, y: 0, width: 5, height: 5), spotlight: true)
        follow.presenceDidChange([tom], isOffline: false)
        #expect(follow.banners.map(\.text) == ["Tom wants you to follow them"])
        follow.presenceDidChange([tom], isOffline: false)
        #expect(follow.banners.count == 1)
        follow.dismiss(follow.banners[0])
        follow.presenceDidChange([tom], isOffline: false)
        #expect(follow.banners.isEmpty)
        tom.spotlight = false
        follow.presenceDidChange([tom], isOffline: false)
        tom.spotlight = true
        follow.presenceDidChange([tom], isOffline: false)
        #expect(follow.banners.count == 1)
        tom.spotlight = false
        follow.presenceDidChange([tom], isOffline: false)
        #expect(follow.banners.isEmpty)
        tom.spotlight = true
        follow.presenceDidChange([tom], isOffline: false)
        follow.accept(follow.banners[0], participants: [tom])
        #expect(follow.followingID == "t" && follow.banners.isEmpty)
        follow.stop()
        tom.spotlight = false
        follow.presenceDidChange([tom], isOffline: false)
        tom.spotlight = true
        follow.presenceDidChange([tom], isOffline: false)
        follow.presenceDidChange([], isOffline: false)
        #expect(follow.banners.isEmpty)
        follow.accept(FollowController.Banner(id: "x", name: "X"), participants: [])
        #expect(!follow.isFollowing)
    }
}

@Suite(.serialized) @MainActor struct WindowCollaborationTests {
    func window(presence: StubPresenceModel = StubPresenceModel(), session: DocumentSession? = nil,
                fixture: SelectionFixture) -> (DocumentWindowController, TestEnvironment) {
        let environment = TestEnvironment()
        var document = environment.document
        document.makePresence = { _ in presence }
        document.session = { _ in session }
        document.userName = { "Sam Lee" }
        return (DocumentWindowController(document: fixture.document, environment: document), environment)
    }

    @Test func followingDrivesTheViewUntilTheUserNavigates() async {
        let fixture = await SelectionFixture.make()
        let presence = StubPresenceModel()
        let (controller, environment) = window(presence: presence, fixture: fixture)
        defer { controller.close() }
        let collaboration = controller.collaboration
        #expect(collaboration.avatars.localName == "Sam Lee")
        presence.participants = [RemoteParticipant(id: "p", name: "Priya", colorIndex: 4, viewport: Rect(x: 0, y: 0, width: 100, height: 100), zoom: 3, spotlight: true)]
        #expect(collaboration.banner.banners.count == 1 && !collaboration.bannerHost.isHidden)
        let banner = collaboration.banner.banners[0]
        CollaborationBannerView.follow(collaboration.banner, banner)()
        #expect(collaboration.follow.followingID == "p" && abs(controller.viewport.zoom - 3) < 0.001)
        #expect(collaboration.avatars.followingID == "p" && collaboration.banner.followText == "Following Priya")
        NSHostingView(rootView: CollaborationBannerView(model: collaboration.banner)).layoutSubtreeIfNeeded()
        collaboration.drawPresence(in: bitmap())
        controller.canvas.presenceLayer.display()
        // Scrolling ends it; so does Esc with nothing else to cancel, and Stop.
        controller.canvas.scroll(deltaX: 10, deltaY: 0, precise: true, modifierFlags: [], at: .zero)
        #expect(!collaboration.follow.isFollowing)
        collaboration.follow("p")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        #expect(controller.toolManager.keyDown(escape))
        #expect(!collaboration.follow.isFollowing)
        collaboration.follow("p")
        CollaborationBannerView.stop(collaboration.banner)()
        #expect(!collaboration.follow.isFollowing)
        collaboration.follow("nobody")
        collaboration.follow("p")
        controller.zoomIn()
        #expect(!collaboration.follow.isFollowing)
        CollaborationBannerView.dismiss(collaboration.banner, FollowController.Banner(id: "p", name: "Priya"))()
        collaboration.avatars.spotlight()
        #expect(collaboration.follow.isSpotlighting && collaboration.avatars.isSpotlighting)
        // Own-avatar display options are the preferences.
        let options = collaboration.avatars.displayOptions()
        #expect(options.map(\.title) == ["Show others' cursors", "Show names on collaborators' cursors", "Show others' selections"])
        collaboration.avatars.toggle(options[0].id)
        #expect(!environment.preferences[PreferenceCatalog.Sync.showCursors])
        WindowCollaboration.toggle("unknown", environment.preferences)
        environment.preferences.set(false, for: PreferenceCatalog.Sync.sharePresence)
        collaboration.avatars.follow("p")
        collaboration.avatars.stopFollowing()
        #expect(collaboration.avatars.activity(presence.participants[0]) == "Viewing page 1")
        controller.pressDidChange(true)
        controller.pressDidChange(false)
        collaboration.sync.run(.retryNow)
    }

    @Test func remoteChangesPulseAndAnnounceDeletions() async throws {
        let fixture = await SelectionFixture.make()
        let session = DocumentSession(document: fixture.document, connector: nil, localUserID: "me")
        let (controller, environment) = window(session: session, fixture: fixture)
        defer { controller.close() }
        session.handle(.presenceUpdate(try presenceFrame(user: "t", name: "Tom", session: 0xBEEF)))
        controller.collaboration.flashes.clearDelay = .milliseconds(1)
        _ = await controller.documentHandle.receive(remoteChange([ReviewWorld.resize(fixture.b.opID, width: 70)]), serverSeq: 1).value
        #expect(controller.collaboration.flashes.flashes[fixture.b]?.label == "Tom · Size")
        controller.selection.model.set(Selection([fixture.a]))
        _ = await controller.documentHandle.receive(remoteChange([Ops.setDeleted(fixture.a.opID)], seq: 2, counter: 1_000_010), serverSeq: 2).value
        #expect(controller.statusBar.message.stringValue == "Rectangle deleted by Tom")
        controller.selection.model.set(Selection([fixture.b]))
        _ = await controller.documentHandle.receive(remoteChange([Ops.setDeleted(fixture.b.opID)], replica: 0xCAFE, counter: 1_000_020), serverSeq: 3).value
        #expect(controller.statusBar.message.stringValue == "Rectangle deleted by someone else")
        // Session notices reach the status bar; a message too.
        session.handle(.changeDropped(seq: 1, message: "x"))
        #expect(controller.statusBar.message.stringValue.hasPrefix("A change could not be synced"))
        var suggest = heldReview(fixture.square.opID, mode: .readOnly)
        suggest.decision = .suggestReview
        session.handle(.merged(suggest))
        #expect(controller.statusBar.message.stringValue.contains("Review Merge"))
        environment.preferences.set(false, for: PreferenceCatalog.Sync.showCursors)
        controller.collaboration.tearDown()
    }

    @Test func theObjectPanelSaysWhoIsEditing() async {
        let fixture = await SelectionFixture.make()
        let presence = StubPresenceModel()
        let selection = ActiveSelection(model: SelectionModel(), document: fixture.document, presence: presence)
        #expect(selection.editingLine == nil)
        selection.model?.set(Selection([fixture.a]))
        #expect(selection.editingLine == nil)
        presence.participants = [RemoteParticipant(id: "p", name: "Priya", colorIndex: 0, editing: [fixture.a])]
        #expect(selection.editingLine == "Priya is editing this object")
        presence.participants.append(RemoteParticipant(id: "t", name: "Tom", colorIndex: 1, editing: [fixture.a]))
        #expect(selection.editingLine == "Priya and 1 more are editing this object")
        selection.model?.set(Selection([fixture.a, fixture.b]))
        #expect(selection.editingLine == "Priya and 1 more are editing the selection")
        presence.participants.removeLast()
        #expect(selection.editingLine == "Priya is editing the selection")
        let body = NSHostingView(rootView: ObjectPanelBody(selection: selection))
        body.layoutSubtreeIfNeeded()
    }

    @Test func collaborationCommandsFollowSpotlightAndToggle() async {
        let fixture = await SelectionFixture.make()
        let presence = StubPresenceModel()
        let session = DocumentSession(document: fixture.document, connector: nil, localUserID: "me")
        let (controller, environment) = window(presence: presence, session: session, fixture: fixture)
        defer { controller.close() }
        // With a session the window reads the session's presence; the stub is for the command's target.
        let registry = CommandRegistry()
        let target = TestBox<DocumentWindowController?>(nil)
        CollaborationCommands.install(into: registry, window: { target.value }, preferences: environment.preferences)
        let ids = CollaborationCommands.ID.self
        for id in [ids.reviewMerge, ids.follow, ids.spotlight] {
            #expect(registry.validate(id)?.reason == CollaborationCommands.noDocument)
        }
        #expect(registry.validate(ids.stopFollowing)?.isEnabled == false)
        target.value = controller
        #expect(registry.validate(ids.reviewMerge)?.reason == CollaborationCommands.nothingToReview)
        #expect(registry.validate(ids.follow)?.reason == CollaborationCommands.nobodyElse)
        #expect(registry.validate(ids.spotlight)?.title == "Spotlight Me")
        #expect(registry.perform(ids.spotlight))
        #expect(registry.validate(ids.spotlight)?.title == "Stop Spotlighting")
        #expect(!registry.perform(ids.follow))
        #expect(registry.validate(ids.showCursors)?.isChecked == true)
        #expect(registry.perform(ids.showCursors))
        #expect(registry.validate(ids.showCursors)?.isChecked == false)
        session.handle(.reviewNeeded(heldReview(fixture.a.opID)))
        #expect(registry.validate(ids.reviewMerge)?.isEnabled == true)
        #expect(await eventually { controller.collaboration.review.isShown })
        controller.collaboration.review.close()
        #expect(registry.perform(ids.reviewMerge))
        #expect(await eventually { controller.collaboration.review.isShown })
        controller.collaboration.review.close()
        #expect(!registry.perform(ids.stopFollowing))

        // Follow <name> follows the collaborator under the context menu, else the first one.
        let other = await SelectionFixture.make()
        let (plain, plainEnvironment) = window(presence: presence, fixture: other)
        defer { plain.close() }
        target.value = plain
        presence.participants = [RemoteParticipant(id: "p", name: "Priya", colorIndex: 0), RemoteParticipant(id: "t", name: "Tom", colorIndex: 1)]
        #expect(registry.validate(ids.follow)?.title == "Follow Priya")
        _ = plain.contextMenu(for: .presence(participantID: "t", name: "Tom"))
        #expect(registry.validate(ids.follow)?.title == "Follow Tom")
        #expect(registry.perform(ids.follow))
        #expect(plain.collaboration.follow.followingID == "t")
        #expect(registry.validate(ids.stopFollowing)?.isEnabled == true)
        #expect(registry.perform(ids.stopFollowing))

        // Hide <name>'s Cursor (COLLAB-060): this window stops drawing that cursor, the avatar says
        // so, and the item becomes Show <name>'s Cursor.
        #expect(registry.validate(ids.hideCursor)?.title == "Hide Tom's Cursor")
        #expect(registry.perform(ids.hideCursor))
        #expect(plain.collaboration.isCursorHidden("t") && !plain.collaboration.isCursorHidden("p"))
        #expect(plain.collaboration.avatars.hiddenCursors == ["t"])
        #expect(AvatarStripView.card(presence.participants[1], plain.collaboration.avatars).hasSuffix(AvatarStripModel.cursorHidden))
        #expect(registry.validate(ids.hideCursor)?.title == "Show Tom's Cursor")
        let hidden = PresenceOverlay(document: other.document, viewport: SelectionFixture.viewport)
        var pointing = presence.participants
        pointing[0].cursor = Point(x: 5, y: 5)
        pointing[1].cursor = Point(x: 9, y: 9)
        let marks = hidden.cursors(pointing, options: PresenceDisplayOptions(hiddenCursors: plain.collaboration.hiddenCursors), clock: CursorLabelClock())
        #expect(marks.map(\.participantID) == ["p"])
        plain.collaboration.drawPresence(in: bitmap())
        Render.view(AvatarView(participant: presence.participants[1], model: plain.collaboration.avatars), size: CGSize(width: 30, height: 30))
        #expect(registry.perform(ids.hideCursor))
        #expect(!plain.collaboration.isCursorHidden("t") && registry.validate(ids.hideCursor)?.title == "Hide Tom's Cursor")
        target.value = nil
        #expect(registry.validate(ids.hideCursor)?.reason == CollaborationCommands.noDocument)
        #expect(!registry.perform(ids.hideCursor))
        target.value = plain
        presence.participants = []
        #expect(registry.validate(ids.hideCursor)?.reason == CollaborationCommands.nobodyElse)
        withExtendedLifetime((environment, plainEnvironment)) {}
    }

    @Test func editCurrentLayerOnlyLimitsPicks() async {
        let fixture = await SelectionFixture.make()
        let (controller, environment) = window(fixture: fixture)
        defer { controller.close() }
        let art = LayerOrder(fixture.document.state).layer(of: fixture.a.opID, in: fixture.document.state)
        let layer = await fixture.document.perform(CreateLayer(name: "Top")).value?.createdNodes.first
        let viewport = SelectionFixture.viewport
        func picks() -> Bool { controller.selection.pick(at: Point(x: 30, y: 30), viewport: viewport, subselect: false)?.id == fixture.a }
        #expect(picks())
        environment.preferences.set(true, for: PreferenceCatalog.Object.editCurrentLayerOnly)
        controller.objectEditing.activeLayer = art
        #expect(picks())
        #expect(controller.selection.hitTester(viewport: viewport, subselect: false).options.activeLayer == art.map(NodeID.init))
        controller.objectEditing.activeLayer = layer
        #expect(!picks())
        #expect(controller.pickingLayer == layer)
        // A locked layer's objects are never picked (LIB-005: the hit tester skips its run).
        environment.preferences.set(false, for: PreferenceCatalog.Object.editCurrentLayerOnly)
        _ = await fixture.document.perform(SetLayerFlag([art!], .locked, true)).value
        #expect(!picks())
        // Hiding the active layer shows the warning strip.
        _ = await fixture.document.perform(SetLayerFlag([layer!], .visible, false)).value
        #expect(controller.collaboration.banner.warning != nil && !controller.collaboration.bannerHost.isHidden)
        controller.objectEditing.activeLayer = nil
    }

    /// DOC-012's rest: presence on masters -- a master tab's frames name its canvas (and no page),
    /// the document window's clear it; participants on another canvas are not drawn, not followed,
    /// and read "On Master A".
    @Test func presenceNamesTheMasterCanvas() async throws {
        let presence = LocalPresence()
        let master = OpID(counter: 9, replica: 1)
        let tab = LocalPresencePublisher(presence: presence, canvas: master)
        tab.page(OpID(counter: 2, replica: 1))
        tab.pointer(Point(x: 3, y: 4))
        var update = try #require(await presence.presence())
        #expect(update.hasCanvas && OpID(update.canvas) == master && !update.hasPage)
        let window = LocalPresencePublisher(presence: presence)
        window.viewport(Viewport(size: Size(width: 100, height: 50)))
        window.page(OpID(counter: 2, replica: 1))
        window.selection(Selection())
        update = try #require(await presence.presence())
        #expect(!update.hasCanvas && update.hasPage)
        tab.selection(Selection())
        tab.viewport(Viewport(size: Size(width: 10, height: 10)))
        update = try #require(await presence.presence())
        #expect(update.hasCanvas)
        // Read back as a participant.
        var frame = Wiretuner_Sync_V1_PresenceUpdate()
        frame.user.userID = "u1"
        frame.user.displayName = "Priya"
        frame.canvas = master.proto
        let participant = PresenceAdapter.participant(PresenceParticipant(frame))
        #expect(participant.canvas == master)
        #expect(PresenceAdapter.participant(PresenceParticipant(Wiretuner_Sync_V1_PresenceUpdate())).canvas == nil)
        // The hover card.
        #expect(AvatarStripModel.activity(participant, canvas: { _ in "Master A" }) == "On Master A")
        var editing = participant
        editing.editing = [SelectionID(OpID(counter: 3, replica: 1))]
        #expect(AvatarStripModel.activity(editing, object: { _ in "Logo" }, canvas: { _ in "Master A" }) == "Editing Logo on Master A")
        // Follow applies only a view on the window's canvas.
        let follow = FollowController()
        let applied = TestBox(0)
        follow.apply = { _, _ in applied.value += 1 }
        var viewed = participant
        viewed.viewport = Rect(x: 0, y: 0, width: 10, height: 10)
        follow.follow(viewed)
        follow.presenceDidChange([viewed], isOffline: false)
        #expect(applied.value == 0, "their view is in the master's space")
        follow.canvas = master
        follow.presenceDidChange([viewed], isOffline: false)
        #expect(applied.value >= 1)
    }
}
