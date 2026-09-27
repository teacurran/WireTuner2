import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WTTestSupport

/// DOC-031: pages, master pages and guides under concurrency (pages.adoc, master-pages.adoc and
/// grid-guides.adoc, "Merge semantics"), through the simulator, with LIB-023's three clients: Ben's
/// work is concurrent with Ana's, live (within a dropped connection, which merges without asking)
/// or after 12 hours offline, whose review must hold exactly the rows the pages name.  Every run
/// converges to one state hash on every client and the server.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(6))) struct DocumentSetupScenarioTests {
    typealias Team = LibraryScenarioTests.Team

    /// Three Letter pages (the first writes the page every new document reads).
    static func pages(_ team: Team) async throws -> [OpID] {
        await team.ana.perform(AddPages(count: 2))
        try await team.sim.settle()
        let pages = PageList(team.ana.state).pages.map(\.id)
        #expect(pages.count == 3)
        return pages
    }

    /// A 20 pt square at `point` (pasteboard), drawn by `client`.
    static func draw(_ client: SimClient, at point: Point) async throws -> OpID {
        let command = CreateShape(.rectangle(CornerRadii.uniform(0)), size: Size(width: 20, height: 20),
                                  transform: .translation(x: point.x, y: point.y))
        return try #require(await client.perform(command)?.createdObjects.first)
    }

    /// What the review held, checked: the object rows, the removed-target rows and the release
    /// rows are exactly the given ones (and zero pages when `zeroPages`); held reviews are settled
    /// with *Keep the merged result*.  Live, nothing asked.  Then everyone converges.
    static func expect(_ team: Team, _ review: ReviewModel?, offline: Bool, rows: Set<ReviewRow> = [],
                       removed: [RemovedTargetEntry.Kind] = [], releases: [ReleaseOverlap.Kind] = [], zeroPages: Bool = false) async throws {
        if offline {
            let review = try #require(review)
            #expect(ReviewRow.rows(review) == rows)
            #expect(review.removedTargets.map(\.kind) == removed)
            #expect(review.releaseOverlaps.map(\.kind) == releases)
            #expect(review.zeroPages == zeroPages)
            if review.holdsOutbox { try await team.ben.keepMerged() }
        } else {
            #expect(review?.holdsOutbox != true, "a brief drop merges without asking")
            #expect(team.ben.reviews == 0)
        }
        try await team.sim.settle()
        try await team.sim.expectConverged()
    }

    static func page(_ id: OpID, _ client: SimClient) -> Page? { PageList(client.state)[id] }

    // MARK: Pages

    /// Resize race: Ana makes page 2 A4 while Ben makes it Tabloid; `geometry` is atomic, the later
    /// write stands whole.  Offline, the page is *Same attribute* (*Geometry*).
    @Test(arguments: [false, true]) func resizeRace(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("doc-resize-\(offline)", seed: 3101)
        defer { Task { await team.sim.shutdown() } }
        let pages = try await Self.pages(team)
        let a4 = try #require(PagePreset.named("A4").map { PageGeometry($0) })
        let tabloid = try #require(PagePreset.named("Tabloid").map { PageGeometry($0) })
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(SetPageGeometry([pages[1]], to: tabloid))
        } theirs: {
            await team.ana.perform(SetPageGeometry([pages[1]], to: a4))
        }
        try await Self.expect(team, review, offline: offline, rows: [ReviewRow(node: pages[1], kind: .sameRegister, attributes: ["Geometry"])])
        let winner = try #require(team.ana.state.store.register(pages[1], PageFields.geometry)?.op)
        let expected = winner.replica == (await team.ben.store.replica) ? tabloid : a4
        for person in team.everyone { #expect(Self.page(pages[1], person)?.geometry == expected) }
    }

    /// Remove vs. draw: Ana removes page 3 while Ben draws on it; the page goes, Ben's square stays
    /// on the pasteboard where the page was.  Offline, the square is listed "Created on a page that
    /// was removed" with *Restore page*, which brings the page back around it.
    @Test(arguments: [false, true]) func removeVersusDraw(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("doc-remove-draw-\(offline)", seed: 3102)
        defer { Task { await team.sim.shutdown() } }
        let pages = try await Self.pages(team)
        let third = try #require(Self.page(pages[2], team.ana))
        var drawn: OpID?
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            drawn = try await Self.draw(team.ben, at: Point(x: third.rect.midX, y: third.rect.midY))
        } theirs: {
            await team.ana.perform(RemovePages([pages[2]], in: team.ana.state))
        }
        let square = try #require(drawn)
        try await Self.expect(team, review, offline: offline, removed: offline ? [.removedPage] : [])
        for person in team.everyone {
            #expect(person.state.isLive(square) && Self.page(pages[2], person) == nil)
            #expect(Objects.bounds(of: square, in: person.state)?.minX == third.rect.midX, "where the page was")
        }
        if offline, let row = review?.removedTargets.first {
            #expect(row.object == square && row.target == pages[2] && row.choices == [.restore] && row.kind.title == "Created on a page that was removed")
            #expect(await team.ben.perform(try #require(try row.command(.restore, in: team.ben.state))) != nil)
            try await team.sim.settle()
            try await team.sim.expectConverged()
            for person in team.everyone { #expect(Self.page(pages[2], person)?.rect == third.rect && person.state.isLive(square)) }
        }
    }

    /// Move vs. move: both drag page 2 down with its square, by different distances.  `origin` and each object's transform are
    /// registers: the later drag wins page and square together, on every client.  Offline, page and
    /// square are each *Same attribute* (*Origin*, *Transform*).
    @Test(arguments: [false, true]) func moveVersusMove(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("doc-move-move-\(offline)", seed: 3103)
        defer { Task { await team.sim.shutdown() } }
        let pages = try await Self.pages(team)
        let second = try #require(Self.page(pages[1], team.ana))
        let square = try await Self.draw(team.ana, at: Point(x: second.rect.midX, y: second.rect.midY))
        try await team.sim.settle()
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(MovePage(pages[1], by: Vector(dx: 0, dy: 300)))
        } theirs: {
            await team.ana.perform(MovePage(pages[1], by: Vector(dx: 0, dy: 600)))
        }
        try await Self.expect(team, review, offline: offline, rows: [
            ReviewRow(node: pages[1], kind: .sameRegister, attributes: ["Origin"]),
            ReviewRow(node: square, kind: .sameRegister, attributes: ["Transform"]),
        ])
        let dy = try #require(Self.page(pages[1], team.ana)).origin.y - second.origin.y
        #expect(dy == 300 || dy == 600)
        for person in team.everyone {
            #expect(Self.page(pages[1], person)?.origin.y == second.origin.y + dy)
            #expect(Objects.bounds(of: square, in: person.state)?.minY == second.rect.midY + dy, "the square follows the winning drag")
        }
    }

    /// Reorder race: Ana moves page 3 to the front while Ben moves page 1 to the end -- both apply;
    /// then Ana moves page 2 to the front and Ben to the middle -- the later wins.  Offline, only the page both
    /// moved is listed, *Both moved* (*Position*).
    @Test(arguments: [false, true]) func reorderRace(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("doc-reorder-\(offline)", seed: 3104)
        defer { Task { await team.sim.shutdown() } }
        let pages = try await Self.pages(team)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(ReorderPage(pages[0], to: 3))
            await team.ben.perform(ReorderPage(pages[1], to: 2))
        } theirs: {
            await team.ana.perform(ReorderPage(pages[2], to: 1))
            await team.ana.perform(ReorderPage(pages[1], to: 1))
        }
        try await Self.expect(team, review, offline: offline, rows: [ReviewRow(node: pages[1], kind: .moveVsMove, attributes: ["Position"])])
        let order = PageList(team.ana.state).pages.map(\.id)
        #expect(Set(order) == Set(pages) && order.firstIndex(of: pages[2])! < order.firstIndex(of: pages[0])!, "both first moves apply")
        let winner = try #require(team.ana.state.store.placement(pages[1])?.op)
        #expect((order.first == pages[1]) == (winner.replica == (await team.ana.store.replica)), "the later move of page 2 wins")
        for person in team.everyone { #expect(PageList(person.state).pages.map(\.id) == order) }
    }

    /// Zero pages: in a two-page document Ana removes page 1 while Ben removes page 2, each legal
    /// locally.  The document reads as one Letter page everywhere; offline, Ben's review says "All
    /// pages were removed; a page was added" (without holding anything), and the next page command
    /// writes the page.
    @Test(arguments: [false, true]) func zeroPages(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("doc-zero-pages-\(offline)", seed: 3105)
        defer { Task { await team.sim.shutdown() } }
        await team.ana.perform(AddPages(count: 1))
        try await team.sim.settle()
        let pages = PageList(team.ana.state).pages.map(\.id)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(RemovePages([pages[1]], in: team.ben.state))
        } theirs: {
            await team.ana.perform(RemovePages([pages[0]], in: team.ana.state))
        }
        try await Self.expect(team, review, offline: offline, zeroPages: offline)
        if offline { #expect(review?.holdsOutbox == false && review?.decision == .suggestReview) }
        for person in team.everyone { #expect(PageList(person.state).isSynthesized) }
        await team.cy.perform(AddPages(count: 1))
        try await team.sim.settle()
        try await team.sim.expectConverged()
        for person in team.everyone { #expect(PageList(person.state).pages.count == 2 && !PageList(person.state).isSynthesized) }
    }

    /// Master edit vs. child release: Ana moves the master's rectangle while Ben releases the child
    /// page; the copies are as Ben saw the master.  Offline, one *Released stale master* row names
    /// the page; *Update the copies* re-copies the moved master.
    @Test(arguments: [false, true]) func masterEditVersusChildRelease(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("doc-master-release-\(offline)", seed: 3106)
        defer { Task { await team.sim.shutdown() } }
        let pages = try await Self.pages(team)
        let first = try #require(Self.page(pages[0], team.ana))
        let object = try await Self.draw(team.ana, at: Point(x: first.rect.minX + 10, y: first.rect.minY + 10))
        await team.ana.perform(ConvertToMasterPage(pages[0]))
        try await team.sim.settle()
        let master = try #require(PageList(team.ana.state).masters.first?.id)
        #expect(Self.page(pages[0], team.ana)?.master == master)
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(ReleaseChildPages([pages[0]], in: team.ben.state))
        } theirs: {
            await team.ana.perform(MoveObjects([object], by: Vector(dx: 5, dy: 0)))
        }
        try await Self.expect(team, review, offline: offline, releases: offline ? [.staleMaster] : [])
        func copies(_ person: SimClient) -> [Rect] {
            let list = PageList(person.state)
            return PageObjects.objects(on: list[pages[0]]!, in: person.state, pages: list).map(\.bounds)
        }
        for person in team.everyone {
            #expect(copies(person).map(\.minX) == [first.rect.minX + 10], "the copy is as Ben saw the master")
            #expect(Objects.bounds(of: object, in: person.state)?.minX == first.rect.minX + 15)
        }
        if offline, let row = review?.releaseOverlaps.first {
            #expect(row.page == pages[0] && row.master == master)
            #expect(await team.ben.perform(try #require(row.command(.updateCopies, in: team.ben.state))) != nil)
            try await team.sim.settle()
            try await team.sim.expectConverged()
            for person in team.everyone { #expect(copies(person).map(\.minX) == [first.rect.minX + 15]) }
        }
    }

    // MARK: Guides

    /// A guide on page 1 at 100 pt.
    static func guide(_ team: Team, _ page: OpID) async throws -> OpID {
        await team.ana.perform(AddGuides(on: [page], axis: .vertical, at: [100]))
        try await team.sim.settle()
        return try #require(Self.page(page, team.ana)?.guides.first?.id)
    }

    /// Guide drag race: both drag one guide; `position` is a register, the later drop stands.
    /// Offline, the page is *Same attribute* (*Guides*).
    @Test(arguments: [false, true]) func guideDragRace(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("doc-guide-drag-\(offline)", seed: 3107)
        defer { Task { await team.sim.shutdown() } }
        let pages = try await Self.pages(team)
        let guide = try await Self.guide(team, pages[0])
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            for x in stride(from: 110.0, through: 150, by: 10) { await team.ben.perform(MoveGuide(on: pages[0], [guide], to: x)) }
        } theirs: {
            await team.ana.perform(MoveGuide(on: pages[0], [guide], to: 40))
        }
        try await Self.expect(team, review, offline: offline, rows: [ReviewRow(node: pages[0], kind: .sameRegister, attributes: ["Guides"])])
        let position = try #require(Self.page(pages[0], team.ana)?.guides.first?.position)
        #expect(position == 40 || position == 150)
        for person in team.everyone { #expect(Self.page(pages[0], person)?.guides.map(\.position) == [position]) }
    }

    /// Guide delete vs. move: Ana deletes the guide Ben is dragging; it is removed everywhere.
    /// Offline, the page is listed *Edited and deleted* (*Guides removed*) -- the guide is an
    /// element of the page's `guides` -- and restoring the element brings it back at Ben's drop.
    @Test(arguments: [false, true]) func guideDeleteVersusMove(offline: Bool) async throws {
        let team = try await LibraryScenarioTests.team("doc-guide-delete-\(offline)", seed: 3108)
        defer { Task { await team.sim.shutdown() } }
        let pages = try await Self.pages(team)
        let guide = try await Self.guide(team, pages[0])
        let review = try await LibraryScenarioTests.concurrently(team, offline: offline) {
            await team.ben.perform(MoveGuide(on: pages[0], [guide], to: 180))
        } theirs: {
            await team.ana.perform(DeleteGuides(on: pages[0], [guide]))
        }
        try await Self.expect(team, review, offline: offline, rows: [ReviewRow(node: pages[0], kind: .editVsDelete, attributes: ["Guides removed"])])
        for person in team.everyone { #expect(Self.page(pages[0], person)?.guides.isEmpty == true) }
        if offline, let entry = review?.entries.first {
            try await ReviewChoices.restore(entry, on: team.ben)
            try await team.sim.settle()
            try await team.sim.expectConverged()
            for person in team.everyone { #expect(Self.page(pages[0], person)?.guides.map(\.position) == [180]) }
        }
    }

    // MARK: A day offline

    /// An offline day of page edits on two clients: Ana and Ben each work 24 simulated hours on
    /// their own pages -- adding pages, dragging, resizing, renaming, guides, drawing -- with Cy
    /// online, then reconnect.  Nothing overlaps, so neither review lists a row; every client
    /// converges, and each page shows the last of its owner's edits.
    @Test func anOfflineDayOfPageEditsOnTwoClients() async throws {
        let team = try await LibraryScenarioTests.team("doc-offline-day", seed: 3109)
        defer { Task { await team.sim.shutdown() } }
        team.ana.keepsMergedResult = false
        let pages = try await Self.pages(team)
        team.ana.goOffline()
        team.ben.goOffline()
        let a4 = try #require(PagePreset.named("A4").map { PageGeometry($0) })
        for hour in 0..<24 {
            await team.ana.perform(MovePage(pages[0], by: Vector(dx: 0, dy: 10)))
            await team.ben.perform(MovePage(pages[2], by: Vector(dx: 10, dy: 0)))
            if hour == 3 { await team.ana.perform(SetPageGeometry([pages[0]], to: a4)) }
            if hour == 5 { await team.ben.perform(RenamePage(pages[2], to: "Back cover", in: team.ben.state)) }
            if hour == 8 { await team.ana.perform(AddGuides(on: [pages[0]], axis: .horizontal, at: [72, 144])) }
            if hour == 9 { await team.ben.perform(AddGuides(on: [pages[2]], axis: .vertical, at: [36])) }
            if hour == 12 { await team.ana.perform(AddPages(count: 2, after: pages[0])) }
            if hour == 20, let page = Self.page(pages[2], team.ben) {
                _ = try await Self.draw(team.ben, at: Point(x: page.rect.midX, y: page.rect.midY))
            }
            team.sim.advance(by: .seconds(3600))
        }
        await team.cy.perform(RenamePage(pages[1], to: "Inside", in: team.cy.state))
        try await team.sim.settle([team.cy])
        let seenAna = team.ana.events.count
        let seenBen = team.ben.events.count
        team.ana.goOnline()
        team.ben.goOnline()
        try await team.sim.settle()
        try await team.sim.expectConverged()
        for (person, seen) in [(team.ana, seenAna), (team.ben, seenBen)] {
            let reviews = person.events.dropFirst(seen).compactMap { event -> ReviewModel? in
                switch event {
                case .merged(let review), .reviewNeeded(let review): review
                default: nil
                }
            }
            #expect(!reviews.isEmpty && reviews.allSatisfy { ReviewRow.rows($0).isEmpty && !$0.holdsOutbox }, "\(person.name): nothing overlapped")
        }
        let list = PageList(team.cy.state)
        #expect(list.pages.count == 5)
        #expect(list[pages[0]]?.geometry == a4 && list[pages[0]]?.guides.count == 2)
        #expect(list[pages[2]]?.name == "Back cover" && list[pages[2]]?.guides.count == 1 && list[pages[1]]?.name == "Inside")
        for person in team.everyone { #expect(PageList(person.state) == list) }
    }
}
