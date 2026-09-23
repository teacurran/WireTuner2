import Foundation
import WTCRDT
import WTModel
import WTProto
import WTSync

/// A command performed under another label: the simulator labels every change it makes
/// uniquely ("alice#12 Move"), so the report can say which one went missing and the label
/// conservation check can find each in the server's log (coalescing and salvage keep labels).
public struct Labelled: Command {
    public let inner: any Command
    public let label: String

    public init(_ inner: any Command, label: String) {
        self.inner = inner
        self.label = label
    }

    public var coalescing: UndoCoalescing { inner.coalescing }
    public var recordsUndo: Bool { inner.recordsUndo }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try inner.execute(&builder, state: state)
    }
}

/// Bearer tokens from the simulated identity provider: each lives `lifetime` of simulated time,
/// and none can be had while the client's link is cut (a refresh needs the network too).
public actor SimTokens: TokenProvider {
    public let server: SimServer
    public let account: String
    public let lifetime: Duration
    public let link: NetworkLink
    private var token: String?
    /// Tokens handed out, and how many of them were asked for after a refusal.
    public private(set) var issued = 0
    public private(set) var refreshes = 0

    public init(server: SimServer, account: String, lifetime: Duration, link: NetworkLink) {
        self.server = server
        self.account = account
        self.lifetime = lifetime
        self.link = link
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if let token, !forceRefresh { return token }
        guard !link.isPartitioned else { throw URLError(.notConnectedToInternet) }
        if forceRefresh { refreshes += 1 }
        let fresh = await server.issueToken(for: account, lifetime: lifetime)
        issued += 1
        token = fresh
        return fresh
    }
}

/// One simulated person at one Mac (docs/spec/testing.adoc, "Multi-client simulation"), wired as
/// WTApp's `DocumentSession` wires a window: a `LocalStore`, the WTModel `Document` façade over
/// it as the sync client's sink, and a real `SyncClient` whose transport is a `ProxyTransport`
/// over this client's `NetworkLink`.  `stateReplaced` reloads the façade and a collection point
/// advances the store's horizon, as the app does.
@MainActor
public final class SimClient {
    public let name: String
    public let user: SimUser
    public let device: String
    public let documentID: String
    public let link: NetworkLink
    public let store: LocalStore
    public let document: Document
    public let client: SyncClient
    public let tokens: any TokenProvider
    /// What this person's presence says (the tool of the last edit); others see it.
    public let presence: LocalPresence
    /// This client's wall clock (the simulated clock with its skew).
    public let clock: @Sendable () -> Date
    public private(set) var transitions: [SyncTransition] = []
    public private(set) var events: [SyncEvent] = []
    /// The label of every change this client made, in order.
    public private(set) var performed: [String] = []
    /// Labels whose changes were discarded (*Save my version as a copy*), and labels salvage may
    /// have dropped whole.
    public private(set) var discarded: Set<String> = []
    public private(set) var forgiven: Set<String> = []
    /// Commands that could not run against the merged state (their target deleted meanwhile).
    public private(set) var skipped = 0
    public private(set) var isStopped = false
    /// Whether a review that holds the outbox is settled at once with *Keep the merged result*
    /// (what dismissing the sheet does), as a person who is not looking at it would; scenarios that
    /// examine the review turn it off.
    public var keepsMergedResult: Bool
    /// Reviews that held this client's outbox.
    public private(set) var reviews = 0
    private var serial = 0
    private var feeds: [Task<Void, Never>] = []
    private let log: SimulationLog

    init(name: String, user: SimUser, device: String, documentID: String, link: NetworkLink, store: LocalStore, document: Document,
         client: SyncClient, tokens: any TokenProvider, presence: LocalPresence, clock: @escaping @Sendable () -> Date, log: SimulationLog,
         keepsMergedResult: Bool) {
        self.name = name
        self.user = user
        self.device = device
        self.documentID = documentID
        self.link = link
        self.store = store
        self.document = document
        self.client = client
        self.tokens = tokens
        self.presence = presence
        self.clock = clock
        self.log = log
        self.keepsMergedResult = keepsMergedResult
        let transitions = client.transitions()
        let events = client.events()
        feeds.append(Task { [weak self] in
            for await transition in transitions { self?.record(transition) }
        })
        feeds.append(Task { [weak self] in
            for await event in events { await self?.handle(event) }
        })
    }

    private func record(_ transition: SyncTransition) {
        transitions.append(transition)
        log.record("\(name): \(transition.from) -> \(transition.to) (\(transition.cause))")
    }

    private func handle(_ event: SyncEvent) async {
        events.append(event)
        switch event {
        case .stateReplaced(let seq):
            log.record("\(name): state replaced at \(seq)")
            await document.reload()
        case .collectionPoint(let seq, _):
            // As WTApp's DocumentSession does until DocumentCore can collect: the point is at or
            // before the stable seq, so it is recorded as the horizon.
            if seq > 0 { await store.advanceHorizon(to: seq) }
        case .replicaRotated(let from, let to):
            log.record("\(name): replica \(from) rotated to \(to)")
        case .reviewNeeded(let review):
            reviews += 1
            log.record("\(name): review needed (\(review.mode), \(review.entries.count) entries)")
            if let report = review.recovered {
                forgiven.formUnion(report.dropped.map(\.label))
            }
            if keepsMergedResult {
                log.record("\(name): keeps the merged result")
                try? await client.resolveReview(.upload)
            }
        case .salvaged(let report):
            log.record("\(name): salvaged \(report.salvagedChanges) changes, \(report.dropped.count) ops dropped")
            forgiven.formUnion(report.dropped.map(\.label))
        case .merged(let review):
            log.record("\(name): merged (\(review.decision))")
        case .changeDropped(let seq, let message):
            log.record("\(name): change \(seq) dropped: \(message)")
        default:
            break
        }
    }

    // MARK: Editing

    /// Performs `command` under a unique label and tells the sync client; nil (and counted as
    /// skipped) when the command cannot run against the current state or appended nothing.
    @discardableResult
    public func perform(_ command: any Command) async -> Wiretuner_Doc_V1_Change? {
        serial += 1
        let label = "\(name)#\(serial) \(command.label)"
        presence.update { $0.tool = command.label }
        presence.input()
        do {
            guard let change = try await document.perform(Labelled(command, label: label)) else {
                skipped += 1
                return nil
            }
            performed.append(label)
            await client.localChangesAvailable()
            return change
        } catch {
            skipped += 1
            return nil
        }
    }

    /// The merged state the façade shows.
    public var state: EngineState { document.state }

    public var syncState: SyncState {
        get async { await client.state }
    }

    // MARK: Session

    public func start() async {
        await client.start()
    }

    /// Stops the sync client (the window closed); the store stays open for reading.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        await client.stop()
    }

    /// Stops the client and closes the store.
    func close() async {
        await stop()
        for feed in feeds { feed.cancel() }
        feeds = []
        try? await store.close()
    }

    /// Cuts this client off the network.
    public func goOffline() {
        link.partition()
    }

    public func goOnline() {
        link.heal()
        Task { [client] in await client.retry() }
    }

    /// Waits until the sync state satisfies `condition`.
    public func waitFor(_ what: String, timeout: Duration = .seconds(60), _ condition: @escaping (SyncState) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(await client.state) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let trail = transitions.suffix(12).map { "\($0.to) (\($0.cause))" }.joined(separator: "; ")
        throw Simulation.Failure(description: "\(name) timed out waiting for \(what), at \(await client.state): \(trail)")
    }

    /// Settles the pending review with *Keep the merged result*.
    public func keepMerged() async throws {
        try await client.resolveReview(.upload)
    }

    /// *Save my version as a copy…*: forks the document at the review's base with the unsent
    /// changes (`DocumentService.Fork`, as WTApp's review sheet does), then reverts this document to
    /// the server's state.  Returns the copy's id.
    public func saveCopy(on server: SimServer, as copyID: String) async throws -> String {
        let changes = try await store.outbox()
        let base = try await store.reviewHold()?.baseSeq ?? 0
        let token = try await tokens.accessToken(forceRefresh: false)
        try await server.fork(documentID, newID: copyID, atServerSeq: base, changes: changes, token: token)
        discarded.formUnion(changes.map(\.label))
        try await client.resolveReview(.discardLocalChanges)
        log.record("\(name): saved \(changes.count) changes as \(copyID) at \(base), local changes discarded")
        return copyID
    }

    /// Whether the transitions ever reached a state matching `match`.
    public func reached(_ match: (SyncState) -> Bool) -> Bool {
        transitions.contains { match($0.to) }
    }
}
