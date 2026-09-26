import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// One change to one object, as the object's history lists it (history.adoc, "Who changed this
/// object"): when, by whom, what the user did, which attributes it wrote and which of those lost
/// to a concurrent write ("did not apply").
struct NodeHistoryEntry: Equatable, Identifiable, Sendable {
    var serverSeq: UInt64
    var label: String
    var author: String
    var wallTime: Date?
    var attributes: [String]
    var lost: [String]
    var id: UInt64 { serverSeq }
}

/// One page of `ListNodeHistory`, newest first.
struct NodeHistoryPage: Equatable, Sendable {
    var entries: [NodeHistoryEntry]
    var nextCursor: String
}

extension HistoryClient {
    /// The object's history is not offered by this client (a test fake of the panel's calls).
    func nodeHistory(of document: String, node: OpID, cursor: String) async throws -> NodeHistoryPage {
        NodeHistoryPage(entries: [], nextCursor: "")
    }
}

extension GRPCHistoryClient {
    static func entries(_ response: Wiretuner_Docs_V1_ListNodeHistoryResponse) -> [NodeHistoryEntry] {
        response.changes.enumerated().map { index, change in
            let author = response.authors.indices.contains(index) ? response.authors[index].displayName : ""
            return NodeHistoryEntry(serverSeq: change.serverSeq, label: change.label, author: author.isEmpty ? "Someone" : author,
                                    wallTime: date(change.wallTime, present: change.hasWallTime), attributes: change.attributes, lost: change.lostAttributes)
        }
    }

    func nodeHistory(of document: String, node: OpID, cursor: String) async throws -> NodeHistoryPage {
        var request = Wiretuner_Docs_V1_ListNodeHistoryRequest()
        request.documentID = document
        request.node = node.proto
        request.cursor = cursor
        request.pageSize = 50
        let response: Methods.ListNodeHistory.Output = try await caller.unary(Methods.ListNodeHistory.descriptor, request, accessToken: try await accessToken())
        return NodeHistoryPage(entries: Self.entries(response), nextCursor: response.nextCursor)
    }
}

/// The object history popover and the line that opens it (history.adoc, "Who changed this
/// object"; COLLAB-022's popover, COLLAB-023's line): _Changed by Priya, 5 minutes ago_ under the
/// selected object's name in the Object panel, and a click lists the object's own changes -- who,
/// when, what ("Fill", "Position"), a "did not apply" mark on writes that lost -- with btn:[View] on
/// each opening the read-only version window at the state just before that change.
@MainActor
@Observable
final class NodeHistoryModel {
    let node: OpID
    private(set) var entries: [NodeHistoryEntry] = []
    private(set) var nextCursor = ""
    private(set) var isLoading = false
    private(set) var message: String?
    @ObservationIgnored let history: HistoryPanelModel
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    init(node: OpID, history: HistoryPanelModel = .shared) {
        self.node = node
        self.history = history
    }

    /// Whether the line can show at all: a document and the network.
    var isAvailable: Bool { history.window() != nil && history.client() != nil }

    /// Reads the newest page (or the next one, `more`).
    func load(more: Bool = false) async {
        guard let window = history.window(), let client = history.client() else { return }
        if more && nextCursor.isEmpty { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.nodeHistory(of: window.documentHandle.id, node: node, cursor: more ? nextCursor : "")
            entries = more ? entries + page.entries : page.entries
            nextCursor = page.nextCursor
            message = nil
        } catch {
            message = "This object's history could not be read: \(error.localizedDescription)"
        }
    }

    /// "Changed by Priya, 5 minutes ago"; nil before anything is known.
    var line: String? {
        guard let newest = entries.first else { return nil }
        guard let when = newest.wallTime else { return "Changed by \(newest.author)" }
        return "Changed by \(newest.author), \(Self.relative(when, now: now()))"
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Fill, Position" with each losing write marked; the label when nothing is listed.
    static func what(_ entry: NodeHistoryEntry) -> String {
        guard !entry.attributes.isEmpty else { return entry.label }
        return entry.attributes.map { entry.lost.contains($0) ? "\($0) (did not apply)" : $0 }.joined(separator: ", ")
    }

    /// "Priya · 14:02"
    static func byline(_ entry: NodeHistoryEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return [entry.author, entry.wallTime.map(formatter.string)].compactMap { $0 }.joined(separator: " · ")
    }

    /// btn:[View]: the document as it was just before `entry`, read-only.
    @discardableResult
    func view(_ entry: NodeHistoryEntry) async -> Bool {
        guard entry.serverSeq > 0, let window = history.window(), let features = history.features,
              let state = try? await features.versionState(window, entry.serverSeq - 1) else { return false }
        let row = HistoryRow.session(HistorySession(author: entry.author, firstSeq: entry.serverSeq - 1, lastSeq: entry.serverSeq - 1, startedAt: nil,
                                                    endedAt: entry.wallTime, changeCount: 0, branch: nil, changes: []))
        let history = history
        let actions = VersionWindows.Actions(
            restore: { Task { await history.restore(row) } },
            restoreAsCopy: { Task { await history.restoreAsCopy(row) } },
            compare: { Task { await history.compareWithCurrent(row) } }
        )
        history.showVersion(state, "Before \u{201C}\(entry.label)\u{201D} by \(entry.author)", window, actions)
        return true
    }
}

/// The blame line in the Object panel: one object selected and the network there.
struct BlameLineView: View {
    let node: OpID
    @State private var model: NodeHistoryModel?
    @State private var showing = false

    static func toggling(_ showing: Binding<Bool>) -> () -> Void { { showing.wrappedValue.toggle() } }

    var body: some View {
        Group {
            if let model, model.isAvailable, let line = model.line {
                Button(line, action: Self.toggling($showing))
                    .buttonStyle(.link).font(.caption)
                    .accessibilityIdentifier("object.blame")
                    .popover(isPresented: $showing, arrowEdge: .leading) { NodeHistoryPopoverView(model: model) }
            }
        }
        .padding(.horizontal)
        .task(id: node) {
            let model = NodeHistoryModel(node: node)
            self.model = model
            await model.load()
        }
    }
}

/// The popover: the object's changes, newest first, each with btn:[View].
struct NodeHistoryPopoverView: View {
    let model: NodeHistoryModel

    static func viewing(_ model: NodeHistoryModel, _ entry: NodeHistoryEntry) -> () -> Void { { Task { await model.view(entry) } } }
    static func loadingMore(_ model: NodeHistoryModel) -> () -> Void { { Task { await model.load(more: true) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History of this object").font(.headline)
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            List(model.entries) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NodeHistoryModel.what(entry))
                            .foregroundStyle(entry.lost.isEmpty ? .primary : .secondary)
                        Text(NodeHistoryModel.byline(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("View", action: Self.viewing(model, entry)).accessibilityIdentifier("objectHistory.view")
                }
            }
            .frame(minHeight: 160)
            .accessibilityIdentifier("objectHistory.list")
            if !model.nextCursor.isEmpty {
                Button("Show More", action: Self.loadingMore(model)).accessibilityIdentifier("objectHistory.more")
            }
        }
        .padding(10)
        .frame(width: 320, height: 300)
    }
}
