import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A document window with the comments features installed, signed in as Ann.
@MainActor
struct CommentWorld {
    let setup = SetupWindow()
    let features: CommentsFeatures
    var role: DocumentRole = .owner

    init(role: DocumentRole = .owner, account: String = "acct-ann") {
        features = CommentsFeatures(preferences: setup.environment.preferences)
        features.account = { (account, account.isEmpty ? "" : "Ann") }
        features.members = { _ in [CommentMember(id: "acct-ann", name: "Ann"), CommentMember(id: "acct-bo", name: "Bo"), CommentMember(id: "team:t1", name: "Design")] }
        features.role = { _ in role }
        features.pasteboard = NSPasteboard(name: NSPasteboard.Name("CommentWorld-\(UUID().uuidString)"))
        let window = setup.window
        features.install(commands: setup.environment.commands, panels: setup.environment.panels, tools: setup.environment.tools) { window }
    }

    var window: DocumentWindowController { setup.window }
    var document: DocumentHandle { setup.document }
    var comments: WindowComments { features.attach(window) }

    func close() {
        features.detach(window)
        setup.close()
    }

    /// Waits for the members to load.
    func loaded() async {
        for _ in 0..<50 where comments.members.isEmpty { await Task.yield() }
    }

    /// Starts and posts a thread at `point` on `anchor`; returns its id.
    @discardableResult
    func thread(_ text: String, at point: Point = Point(x: 40, y: 40), on anchor: OpID? = nil) async -> OpID? {
        comments.begin(at: point, on: anchor)
        _ = await comments.post(CommentBody(text))?.value
        await document.settle()
        comments.refresh(force: true)
        return comments.model.threads.last?.id
    }
}

@Suite(.serialized) @MainActor struct CommentsFeatureTests {
    @Test func theCommandsPanelAndToolAreInstalled() async throws {
        let world = CommentWorld()
        defer { world.close() }
        let registry = world.setup.environment.commands
        #expect(world.setup.environment.panels.descriptor(for: CommentsFeatures.panelID)?.title == "Comments")
        #expect(world.setup.environment.tools.descriptor(for: CommentTool.id)?.shortcut == KeyEquivalent("c"))
        #expect(registry.command(CommentsFeatures.ID.addComment)?.validation() == .disabled(CommentsFeatures.noSelection))
        #expect(registry.command(CommentsFeatures.ID.showPins)?.validation() == .checked(true))
        registry.perform(CommentsFeatures.ID.showPins)
        #expect(world.setup.environment.preferences[PreferenceCatalog.Sync.showCommentPins] == false)
        registry.perform(CommentsFeatures.ID.showPins)
        registry.perform(CommentsFeatures.ID.showResolved)
        #expect(registry.command(CommentsFeatures.ID.showResolved)?.validation() == .checked(true))
        // Selecting an object enables Add Comment…, which places a pending pin on it.
        let ids = await world.document.addRectangles([Rect(x: 20, y: 20, width: 60, height: 40)])
        world.window.selection.model.apply(ids, mode: .replace)
        #expect(registry.command(CommentsFeatures.ID.addComment)?.validation() == .enabled)
        registry.perform(CommentsFeatures.ID.addComment)
        #expect(world.comments.pending?.anchor == ids[0].opID)
        world.comments.discardPending()
        world.comments.discardPending()
        #expect(world.comments.pending == nil)
        // A viewer cannot comment; without a window nothing is enabled.
        world.features.role = { _ in .viewer }
        #expect(registry.command(CommentsFeatures.ID.addComment)?.validation() == .disabled(CommentsFeatures.cannotComment))
        #expect(world.comments.commentOnSelection() == nil && world.comments.begin(at: Point(x: 0, y: 0), on: nil) == nil)
        world.features.window = { nil }
        #expect(registry.command(CommentsFeatures.ID.addComment)?.validation() == .disabled(CommentsFeatures.noDocument))
        #expect(world.features.front == nil)
        world.features.window = { world.window }
        #expect(world.features.comments(for: world.document) === world.comments)
        #expect(world.features.comments(for: DocumentHandle.memory(title: "Other")) == nil)
        // Preference changes redraw every window.
        world.setup.environment.preferences.set(true, for: PreferenceCatalog.Sync.pinsFollowFilter)
        world.setup.environment.preferences.set(true, for: PreferenceCatalog.Document.askVersionName)
        #expect(world.features.link("doc", OpID(counter: 3, replica: 4)).absoluteString == "wiretuner://document/doc?thread=3.4")
    }

    @Test func postingReplyingEditingReactingResolvingAndDeleting() async throws {
        let world = CommentWorld()
        defer { world.close() }
        await world.loaded()
        let ids = await world.document.addRectangles([Rect(x: 20, y: 20, width: 60, height: 40)])
        let thread = try #require(await world.thread("Is this red?", at: Point(x: 50, y: 40), on: ids[0].opID))
        let comments = world.comments
        #expect(comments.openThread == thread && comments.model[thread]?.anchorName != nil)
        #expect(world.document.undoTitle.hasPrefix("Undo Comment on"))
        // A reply with a mention of Bo.
        var draft = MentionDraft("Asking @B")
        #expect(draft.completions(comments.members).map(\.name) == ["Bo"])
        draft.choose(CommentMember(id: "acct-bo", name: "Bo"))
        draft.text += "please"
        _ = await comments.reply(to: thread, draft.body)?.value
        var entry = try #require(comments.model[thread])
        #expect(entry.comments.count == 2 && entry.comments[1].mentions == ["acct-bo"])
        // Edit, react (and take it back), resolve and reopen.
        _ = await comments.edit(entry.comments[1].id, in: thread, CommentBody("Asking again"))?.value
        _ = await comments.react("👍", to: entry.comments[0].id, in: thread)?.value
        entry = try #require(comments.model[thread])
        #expect(entry.comments[1].text == "Asking again" && entry.comments[0].reactions.count == 1)
        _ = await comments.react("👍", to: entry.comments[0].id, in: thread)?.value
        _ = await comments.setResolved(thread, true)?.value
        #expect(comments.model[thread]?.resolved == true)
        _ = await comments.setResolved(thread, false)?.value
        // Moving the pin onto empty space makes it a point pin.
        _ = await comments.movePin(thread, to: Point(x: 300, y: 200), on: nil)?.value
        #expect(comments.model[thread]?.anchoring == .point)
        // Delete asks first; a refusal writes nothing.
        world.window.confirm = { _, _ in false }
        #expect(comments.delete(entry.comments[1].id, in: thread) == nil && comments.deleteThread(thread) == nil)
        world.window.confirm = { _, _ in true }
        _ = await comments.delete(entry.comments[1].id, in: thread)?.value
        #expect(comments.model[thread]?.comments.count == 1)
        comments.copyLink(thread)
        #expect(world.features.pasteboard.string(forType: .string)?.contains("thread=") == true)
        _ = await comments.deleteThread(thread)?.value
        #expect(comments.model[thread] == nil && comments.openThread == nil)
        // Nothing happens for unknown threads or comments.
        let unknown = OpID(counter: 99_999, replica: 9)
        #expect(comments.reply(to: unknown, CommentBody("x")) == nil && comments.edit(unknown, in: unknown, CommentBody("x")) == nil)
        #expect(comments.delete(unknown, in: unknown) == nil && comments.setResolved(unknown, true) == nil && comments.react("👍", to: unknown, in: unknown) == nil)
        #expect(comments.movePin(unknown, to: Point(x: 0, y: 0), on: nil) == nil && comments.deleteThread(unknown) == nil)
        comments.open(unknown)
        comments.show(unknown)
        #expect(comments.post(CommentBody("no pending")) == nil)
    }

    @Test func pinsDrawHitTestAndFollowThePreferences() async throws {
        let world = CommentWorld()
        defer { world.close() }
        let comments = world.comments
        let preferences = world.setup.environment.preferences
        let first = try #require(await world.thread("First line\nsecond", at: Point(x: 60, y: 60)))
        let second = try #require(await world.thread("Other", at: Point(x: 200, y: 120)))
        _ = await comments.setResolved(second, true)?.value
        comments.close()
        let viewport = world.window.canvas.viewport
        let firstThread = try #require(comments.model[first])
        let center = try #require(comments.pinCenter(firstThread, viewport: viewport))
        #expect(comments.thread(atView: center, viewport: viewport)?.id == first)
        #expect(comments.thread(atView: Point(x: center.x + 40, y: center.y + 40), viewport: viewport) == nil)
        #expect(comments.visiblePins.map(\.id) == [first])
        preferences.set(true, for: PreferenceCatalog.Sync.showResolvedPins)
        #expect(comments.visiblePins.count == 2)
        let context = bitmap()
        comments.hovered = first
        comments.hovered = first
        comments.begin(at: Point(x: 100, y: 100), on: nil)
        comments.draw(in: context)
        comments.discardPending()
        WindowComments.drawLabel(in: context, text: String(repeating: "long ", count: 30), at: Point(x: 0, y: 0))
        comments.layer.draw(in: context)
        // Hidden pins show only the one chosen in the panel.
        preferences.set(false, for: PreferenceCatalog.Sync.showCommentPins)
        #expect(comments.visiblePins.isEmpty)
        comments.show(first, zoom: true)
        #expect(comments.visiblePins.map(\.id) == [first] && comments.openThread == first)
        preferences.set(true, for: PreferenceCatalog.Sync.showCommentPins)
        // Pins Follow Filter draws what the panel lists.
        preferences.set(true, for: PreferenceCatalog.Sync.pinsFollowFilter)
        comments.filter.state = .resolved
        #expect(comments.visiblePins.map(\.id) == [second])
        comments.filter.state = .open
        // Drawing tools hide the pins.
        world.window.toolManager.select("pen")
        #expect(!comments.showsPins)
        world.window.toolManager.select(.pointer)
        #expect(comments.showsPins)
        #expect(WindowComments.color(of: "a") == WindowComments.color(of: "a"))
        // Scrolling redraws the layer and keeps it the canvas's size.
        world.window.canvas.setViewport(world.window.canvas.navigation.zoom(viewport, to: 2))
        #expect(comments.layer.frame == world.window.canvas.bounds)
    }

    @Test func unreadCommentsAndMentionNotices() async throws {
        let world = CommentWorld()
        defer { world.close() }
        await world.loaded()
        let comments = world.comments
        let thread = try #require(await world.thread("Mine"))
        comments.close()
        // Bo replies from another Mac, mentioning Ann: unread until displayed, and a notice.
        let reply = Reply(to: thread, author: "acct-bo", body: CommentBody("@Ann look", mentions: [CommentBody.Mention(range: 0..<4, account: "acct-ann")]))
        await world.document.receiveRemote(reply)
        #expect(comments.unreadTotal == 1 && comments.model[thread]?.unreadCount == 1)
        let banner = world.window.collaboration.banner
        let notice = try #require(banner.actions.first)
        #expect(notice.text == "Bo mentioned you" && comments.notices.count == 1)
        banner.onAction(notice.id)
        #expect(comments.openThread == thread && comments.unreadTotal == 0 && banner.actions.isEmpty)
        // A second mention in another thread: dismissed without opening.
        let other = CreateThread(at: Point(x: 10, y: 10), author: "acct-bo", body: CommentBody("Team @Design", mentions: [CommentBody.Mention(range: 5..<12, account: "team:t1")]),
                                 in: world.document.state)
        await world.document.receiveRemote(other)
        let second = try #require(banner.actions.first)
        banner.onDismissAction(second.id)
        #expect(banner.actions.isEmpty)
        // Actions that are not the comments' pass through to the previous handlers.
        banner.onAction(UUID())
        banner.onDismissAction(UUID())
        // A new comment in the open thread counts as read at once.
        await world.document.receiveRemote(Reply(to: thread, author: "acct-bo", body: CommentBody("more")))
        #expect(comments.model[thread]?.unreadCount == 0)
        #expect(comments.name(of: "acct-ann") == "Ann" && comments.name(of: "acct-bo") == "Bo" && comments.name(of: "zz") == "zz" && comments.name(of: "") == "Someone")
    }

    @Test func permissionsFollowTheRole() async throws {
        let ann = CommentPermissions(role: .commenter, account: "a")
        let entry = CommentEntryFixture.thread(author: "b")
        #expect(ann.canComment && !ann.canMove(entry) && !ann.canResolve(entry) && !ann.canDeleteThreads)
        #expect(!ann.canEdit(entry.opener) && !ann.canDelete(entry.opener))
        let own = CommentEntryFixture.thread(author: "a")
        #expect(ann.canMove(own) && ann.canEdit(own.opener) && ann.canDelete(own.opener))
        let owner = CommentPermissions(role: .owner, account: "o")
        #expect(owner.canMove(entry) && owner.canDelete(entry.opener) && owner.canDeleteThreads && !owner.canEdit(entry.opener))
        let viewer = CommentPermissions(role: .viewer, account: "v")
        #expect(!viewer.canComment && !viewer.canMove(own))
        #expect(!CommentPermissions(role: .owner, account: "").canComment)
        let roster = ShareRoster(members: [ShareMember(accountID: "a", displayName: "Ann"), ShareMember(accountID: "", displayName: "Pending", isPending: true)],
                                 teamAccess: TeamAccessInfo(teamID: "t", teamName: "Team"))
        #expect(CommentMember.members(roster).map(\.id) == ["a", "team:t"] && CommentMember.members(roster)[1].isTeam)
    }

    @Test func theToolStartsThreadsOpensAndDragsPins() async throws {
        let world = CommentWorld()
        defer { world.close() }
        let setup = world.setup
        let ids = await world.document.addRectangles([Rect(x: 20, y: 20, width: 60, height: 40)])
        _ = world.comments
        world.window.toolManager.select(CommentTool.id)
        let tool = try #require(world.window.toolManager.activeTool as? CommentTool)
        #expect(tool.cursor == .crosshair)
        // A click on the object starts a thread attached to it.
        tool.mouseDown(setup.event(Point(x: 40, y: 40)))
        tool.mouseUp(setup.event(Point(x: 40, y: 40)))
        #expect(world.comments.pending?.anchor == ids[0].opID && tool.hasSomethingToCancel)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(tool.keyDown(escape) && world.comments.pending == nil && !tool.keyDown(escape))
        // A click on empty space starts a point pin; posting it opens the thread.
        tool.mouseUp(setup.event(Point(x: 300, y: 200)))
        #expect(world.comments.pending?.anchor == nil)
        _ = await world.comments.post(CommentBody("Here"))?.value
        await world.document.settle()
        let thread = try #require(world.comments.model.threads.first)
        world.comments.close()
        // Hovering the pin names it; a click on it opens it; a drag moves it onto the object.
        let pin = try #require(world.comments.pinCenter(thread, viewport: world.window.viewport))
        let onPin = CanvasEvent(pasteboardPoint: world.window.viewport.toPasteboard(pin), viewPoint: pin)
        tool.pointerMoved(onPin)
        #expect(world.comments.hovered == thread.id)
        tool.mouseDown(onPin)
        tool.mouseUp(onPin)
        #expect(world.comments.openThread == thread.id)
        tool.mouseDown(onPin)
        tool.mouseDragged(onPin)
        tool.mouseDragged(setup.event(Point(x: 50, y: 30)))
        tool.drawOverlay(in: bitmap(), viewport: world.window.viewport)
        tool.mouseUp(setup.event(Point(x: 50, y: 30)))
        await world.document.settle()
        world.comments.refresh(force: true)
        #expect(world.comments.model[thread.id]?.anchoring == .object(ids[0].opID))
        tool.flagsChanged(setup.event(Point(x: 0, y: 0)))
        tool.cancel()
        tool.drawOverlay(in: bitmap(), viewport: world.window.viewport)
        // A viewer's clicks do nothing.
        world.features.role = { _ in .viewer }
        #expect(tool.cursor == .operationNotAllowed)
        tool.mouseUp(setup.event(Point(x: 300, y: 300)))
        #expect(world.comments.pending == nil)
        tool.mouseDragged(setup.event(Point(x: 0, y: 0)))
        world.window.toolManager.select(.pointer)
        #expect(tool.context == nil)
        // Outside a window the tool does nothing.
        let loose = CommentTool { _ in nil }
        loose.mouseDown(setup.event(Point(x: 0, y: 0)))
        loose.mouseUp(setup.event(Point(x: 0, y: 0)))
        loose.pointerMoved(setup.event(Point(x: 0, y: 0)))
        #expect(!loose.hasSomethingToCancel && loose.cursor == .crosshair)
    }

    @Test func theThreadPopoverModelAndViews() async throws {
        let world = CommentWorld()
        defer { world.close() }
        await world.loaded()
        let comments = world.comments
        // The composer.
        comments.begin(at: Point(x: 30, y: 30), on: nil)
        let composer = ThreadViewModel(comments: comments)
        #expect(composer.isComposer && composer.title == "New comment" && composer.submit() == nil)
        Render.view(CommentThreadView(model: composer))
        CommentThreadView.draft(composer).wrappedValue = "Hi @"
        #expect(composer.completions.map(\.name) == ["Ann", "Bo", "Design"])
        CommentThreadView.choose(composer, CommentMember(id: "team:t1", name: "Design"))()
        #expect(composer.draft.text == "Hi @Design " && composer.draft.body.mentions.first?.account == "team:t1")
        _ = await composer.submit()?.value
        await world.document.settle()
        let thread = try #require(comments.openThread)
        let model = ThreadViewModel(comments: comments)
        #expect(!model.isComposer && model.title == "Thread 1")
        CommentThreadView.draft(model).wrappedValue = "A reply"
        _ = await model.submit()?.value
        await world.document.settle()
        comments.refresh(force: true)
        let entry = try #require(model.thread)
        Render.view(CommentThreadView(model: model))
        // Edit, react and delete through the row actions.
        CommentThreadView.edit(model, entry.comments[1])()
        CommentThreadView.editText(model).wrappedValue = "Edited reply"
        Render.view(CommentThreadView(model: model))
        CommentThreadView.saveEdit(model)()
        #expect(model.saveEdit() == nil)
        CommentThreadView.edit(model, entry.comments[1])()
        CommentThreadView.cancelEdit(model)()
        CommentThreadView.openReactions(model, entry.comments[0])()
        Render.view(CommentThreadView(model: model))
        CommentThreadView.openReactions(model, entry.comments[0])()
        CommentThreadView.react(model, "🎉", entry.comments[0])()
        try await Task.sleep(for: .milliseconds(50))
        await world.document.settle()
        comments.refresh(force: true)
        Render.view(CommentThreadView(model: model))
        CommentThreadView.resolve(model)()
        try await Task.sleep(for: .milliseconds(50))
        CommentThreadView.delete(model, try #require(model.thread).comments[1])()
        try await Task.sleep(for: .milliseconds(50))
        await world.document.settle()
        comments.refresh(force: true)
        #expect(model.thread?.resolved == true)
        // Deleting the opener of a thread with replies keeps it with "Comment deleted".
        CommentThreadView.draft(model).wrappedValue = "Another"
        _ = await model.submit()?.value
        await world.document.settle()
        comments.refresh(force: true)
        _ = await comments.delete(try #require(model.thread).opener.id, in: thread)?.value
        #expect(model.thread?.openerDeleted == true)
        Render.view(CommentThreadView(model: model))
        CommentThreadView.cancel(model)()
        #expect(comments.openThread == nil && model.title == "Comment")
        #expect(model.delete(entry.comments[0]) == nil && model.react("👍", entry.comments[0]) == nil && model.toggleResolved() == nil)
        model.beginEdit(CommentEntryFixture.thread(author: "someone").opener)
        #expect(model.editing == nil)
        CommentThreadView.draft(model).wrappedValue = "orphan"
        #expect(model.submit() == nil)
        // The composer's cancel discards the pin.
        comments.begin(at: Point(x: 30, y: 30), on: nil)
        CommentThreadView.cancel(ThreadViewModel(comments: comments))()
        #expect(comments.pending == nil)
        #expect(ThreadViewModel.time(0).isEmpty == false)
    }

    @Test func mentionDraftsTagTheNamesStillInTheText() {
        var draft = MentionDraft("mail@example")
        #expect(draft.query == nil && draft.completions([CommentMember(id: "a", name: "Ann")]).isEmpty)
        draft.choose(CommentMember(id: "a", name: "Ann"))
        #expect(draft.text == "mail@example")
        draft = MentionDraft("@")
        #expect(draft.query == "")
        draft.choose(CommentMember(id: "a", name: "Ann"))
        draft.text += "and @"
        draft.choose(CommentMember(id: "b", name: "Bo"))
        #expect(draft.body.mentions.map(\.range) == [0..<4, 9..<12])
        draft.text = "@Bo only"
        #expect(draft.body.mentions.map(\.account) == ["b"])
        draft.text = ""
        #expect(draft.body.mentions.isEmpty && draft.isEmpty)
        #expect(MentionDraft("@ ann").query == nil && MentionDraft("line @a\nb").query == nil)
    }

    @Test func thePanelListsFiltersAndActs() async throws {
        let world = CommentWorld()
        defer { world.close() }
        await world.loaded()
        let comments = world.comments
        let state = world.features.panel
        Render.view(CommentsPanelBody(state: state))
        let a = try #require(await world.thread("Alpha on page", at: world.setup.page.rect.center))
        let b = try #require(await world.thread("Beta outside", at: Point(x: -500, y: -500)))
        comments.close()
        await world.document.receiveRemote(Reply(to: b, author: "acct-bo", body: CommentBody("reply by Bo")))
        _ = await comments.setResolved(a, true)?.value
        comments.close()
        Render.view(CommentsPanelBody(state: state))
        #expect(CommentsPanel.rows(comments).map(\.id) == [b])
        CommentsPanel.binding(comments, \.state).wrappedValue = .all
        #expect(CommentsPanel.rows(comments).count == 2)
        CommentsPanel.binding(comments, \.place).wrappedValue = .pasteboard
        #expect(CommentsPanel.rows(comments).map(\.id) == [b])
        CommentsPanel.binding(comments, \.place).wrappedValue = .thisPage
        #expect(CommentsPanel.rows(comments).map(\.id) == [a])
        CommentsPanel.binding(comments, \.place).wrappedValue = .page(world.setup.page.id)
        #expect(CommentsPanel.rows(comments).map(\.id) == [a])
        CommentsPanel.binding(comments, \.place).wrappedValue = .everywhere
        CommentsPanel.binding(comments, \.person).wrappedValue = "acct-bo"
        #expect(CommentsPanel.rows(comments).map(\.id) == [b])
        CommentsPanel.binding(comments, \.person).wrappedValue = nil
        CommentsPanel.binding(comments, \.search).wrappedValue = "alpha"
        #expect(CommentsPanel.rows(comments).map(\.id) == [a])
        CommentsPanel.binding(comments, \.search).wrappedValue = ""
        CommentsPanel.binding(comments, \.mentionsMe).wrappedValue = true
        #expect(CommentsPanel.rows(comments).isEmpty)
        CommentsPanel.binding(comments, \.mentionsMe).wrappedValue = false
        CommentsPanel.binding(comments, \.state).wrappedValue = .resolved
        #expect(CommentsPanel.rows(comments).map(\.id) == [a])
        CommentsPanel.binding(comments, \.state).wrappedValue = .all
        #expect(CommentsPanel.places(comments).count == world.document.pageList.pages.count + 3)
        #expect(CommentsPanel.people(comments).map(\.1) == ["Everyone", "Ann", "Bo"])
        let row = try #require(CommentsPanel.rows(comments).first { $0.id == b })
        #expect(row.unread && row.replies == 1 && row.author == "Ann")
        Render.view(CommentsPanelBody(state: state))
        // Selecting opens the thread (and marks it read); the menu's actions run.
        CommentsPanel.select(comments, b, zoom: false)()
        #expect(comments.openThread == b && CommentsPanel.rows(comments).first { $0.id == b }?.unread == false)
        CommentsPanel.select(comments, a, zoom: true)()
        let menu = CommentsPanel.menu(comments, row: row)
        #expect(menu.map(\.0) == ["Resolve", "Copy Link", "Delete Thread"])
        for item in menu { item.1() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(CommentsPanel.menu(comments, row: CommentsPanel.Row(id: OpID(counter: 1, replica: 1), number: 0, firstLine: "", author: "", replies: 0,
                                                                     activity: "", unread: false, resolved: false)).isEmpty)
        // Without a window the panel says so.
        world.features.window = { nil }
        world.features.panel.window = { nil }
        Render.view(CommentsPanelBody(state: state))
        #expect(state.front == nil)
    }
}

/// Threads made directly, for permission checks.
enum CommentEntryFixture {
    @MainActor
    static func thread(author: String) -> CommentThread {
        var core = DocumentTemplate.core(replica: 5)
        let command = CreateThread(at: Point(x: 0, y: 0), author: author, body: CommentBody("x"), in: core.state)
        _ = try? core.perform(command, recording: DocumentCore.Recording(limit: 1, now: Date()))
        return CommentThreadModel(core.state).threads[0]
    }
}
