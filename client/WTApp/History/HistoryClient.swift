import Foundation
import GRPCCore
import SwiftProtobuf
import WTCRDT
import WTModel
import WTProto

/// One change inside a session row (history.adoc, "The History panel").
struct HistoryChange: Equatable, Identifiable, Sendable {
    var serverSeq: UInt64
    var label: String
    var wallTime: Date?
    /// The objects it touched (up to eight), with their names then.
    var nodes: [OpID]
    var names: [String]
    var id: UInt64 { serverSeq }
}

/// One person's stretch of work: "Priya · 14:02–15:40 · 312 changes".
struct HistorySession: Equatable, Sendable {
    var author: String
    var firstSeq: UInt64
    var lastSeq: UInt64
    var startedAt: Date?
    var endedAt: Date?
    var changeCount: Int
    /// The branch the changes were merged from, by name.
    var branch: String?
    /// The session's changes, once expanded.
    var changes: [HistoryChange]
}

/// A named version.
struct HistoryVersion: Equatable, Sendable {
    var id: String
    var name: String
    var note: String
    var serverSeq: UInt64
    var author: String
    var createdAt: Date?
}

/// A timeline row.
enum HistoryRow: Equatable, Identifiable, Sendable {
    case session(HistorySession)
    case version(HistoryVersion)

    var id: String {
        switch self {
        case .session(let session): "s\(session.firstSeq)-\(session.lastSeq)"
        case .version(let version): "v\(version.id)"
        }
    }

    /// The server seq the row's state is at (a session's last change, a version's).
    var serverSeq: UInt64 {
        switch self {
        case .session(let session): session.lastSeq
        case .version(let version): version.serverSeq
        }
    }

    var version: HistoryVersion? {
        if case .version(let version) = self { return version }
        return nil
    }
}

/// One page of `ListHistory`.
struct HistoryPage: Equatable, Sendable {
    var rows: [HistoryRow]
    var nextCursor: String
    /// Rows at or below this seq are summarized (older than the retention window).
    var retainedFromSeq: UInt64
}

/// The History panel's calls (`VersionService`).
protocol HistoryClient: Sendable {
    func history(of document: String, cursor: String, query: String, expandSession: UInt64) async throws -> HistoryPage
    func rename(version: String, name: String?, note: String?) async throws
    func delete(version: String) async throws
    /// A new document holding the state at `serverSeq`; its id.
    func restoreAsCopy(of document: String, serverSeq: UInt64, newID: String, name: String) async throws -> String
    /// One object's changes, newest first (`ListNodeHistory`; the object history popover).
    func nodeHistory(of document: String, node: OpID, cursor: String) async throws -> NodeHistoryPage
}

struct GRPCHistoryClient: HistoryClient {
    typealias Methods = Wiretuner_Docs_V1_VersionService.Method

    let caller: any UnaryCaller
    let accessToken: @Sendable () async throws -> String

    static func date(_ timestamp: Google_Protobuf_Timestamp, present: Bool) -> Date? { present ? timestamp.date : nil }

    static func row(_ row: Wiretuner_Docs_V1_HistoryRow) -> HistoryRow? {
        switch row.row {
        case .session(let session)?:
            let changes = session.changes.map { change in
                HistoryChange(serverSeq: change.serverSeq, label: change.label, wallTime: date(change.wallTime, present: change.hasWallTime),
                              nodes: change.nodes.map { OpID($0.id) }, names: change.nodes.map(\.name))
            }
            return .session(HistorySession(author: session.author.displayName, firstSeq: session.firstServerSeq, lastSeq: session.lastServerSeq,
                                           startedAt: date(session.startedAt, present: session.hasStartedAt), endedAt: date(session.endedAt, present: session.hasEndedAt),
                                           changeCount: Int(session.changeCount), branch: session.mergedFromBranchName.isEmpty ? nil : session.mergedFromBranchName,
                                           changes: changes))
        case .version(let version)?:
            return .version(HistoryVersion(id: version.id, name: version.name, note: version.note, serverSeq: version.serverSeq,
                                           author: version.createdBy.displayName, createdAt: date(version.createdAt, present: version.hasCreatedAt)))
        case nil:
            return nil
        }
    }

    func history(of document: String, cursor: String, query: String, expandSession: UInt64) async throws -> HistoryPage {
        var request = Wiretuner_Docs_V1_ListHistoryRequest()
        request.documentID = document
        request.cursor = cursor
        request.pageSize = 100
        request.query = query
        request.expandSession = expandSession
        let response: Methods.ListHistory.Output = try await caller.unary(Methods.ListHistory.descriptor, request, accessToken: try await accessToken())
        return HistoryPage(rows: response.rows.compactMap(Self.row), nextCursor: response.nextCursor, retainedFromSeq: response.retainedFromSeq)
    }

    func rename(version: String, name: String?, note: String?) async throws {
        var request = Wiretuner_Docs_V1_UpdateVersionRequest()
        request.versionID = version
        if let name { request.name = name }
        if let note { request.note = note }
        let _: Methods.UpdateVersion.Output = try await caller.unary(Methods.UpdateVersion.descriptor, request, accessToken: try await accessToken())
    }

    func delete(version: String) async throws {
        var request = Wiretuner_Docs_V1_DeleteVersionRequest()
        request.versionID = version
        let _: Methods.DeleteVersion.Output = try await caller.unary(Methods.DeleteVersion.descriptor, request, accessToken: try await accessToken())
    }

    func restoreAsCopy(of document: String, serverSeq: UInt64, newID: String, name: String) async throws -> String {
        var request = Wiretuner_Docs_V1_RestoreAsCopyRequest()
        request.documentID = document
        request.serverSeq = serverSeq
        request.newDocumentID = newID
        request.name = name
        let response: Methods.RestoreAsCopy.Output = try await caller.unary(Methods.RestoreAsCopy.descriptor, request, accessToken: try await accessToken())
        return response.document.id
    }
}
