import Foundation
import GRPCCore
import WTProto

/// Where the review sheet puts the local work when the user keeps it elsewhere (reconcile.adoc,
/// "Whole document", "Server involvement"): `DocumentService.Fork` for *Save my version as a
/// copy…*, `BranchService.CreateBranch` with the changes as `initial_changes` for *Keep my
/// changes on a branch*.
protocol ReviewWorkClient: Sendable {
    /// A new document from `source` at `atServerSeq` plus `changes`; returns its id.
    func fork(source: String, newID: String, atServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change], name: String) async throws -> String
    /// A branch of `parent` forked at `forkServerSeq` holding `changes`; returns its id.
    func createBranch(parent: String, branchID: String, name: String, forkServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change]) async throws -> String
}

/// The requests, built apart from the transport so tests assert on them.
enum ReviewRequests {
    /// The most changes a Fork or CreateBranch carries (docs/v1 protovalidate rules).
    static let changeLimit = 1000

    static func fork(source: String, newID: String, atServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change], name: String) -> Wiretuner_Docs_V1_ForkRequest {
        var request = Wiretuner_Docs_V1_ForkRequest()
        request.sourceDocumentID = source
        request.newDocumentID = newID
        request.atServerSeq = atServerSeq
        request.changes = changes
        request.name = String(name.prefix(256))
        return request
    }

    static func createBranch(parent: String, branchID: String, name: String, forkServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change])
        -> Wiretuner_Docs_V1_CreateBranchRequest {
        var request = Wiretuner_Docs_V1_CreateBranchRequest()
        request.parentDocumentID = parent
        request.branchDocumentID = branchID
        request.name = String(name.prefix(256))
        request.forkServerSeq = forkServerSeq
        request.initialChanges = changes
        return request
    }
}

/// The gRPC client, one unary call each through the app's `UnaryCaller`.
struct GRPCReviewWorkClient: ReviewWorkClient {
    typealias Documents = Wiretuner_Docs_V1_DocumentService.Method
    typealias Branches = Wiretuner_Docs_V1_BranchService.Method

    let caller: any UnaryCaller
    let accessToken: @Sendable () async throws -> String

    func fork(source: String, newID: String, atServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change], name: String) async throws -> String {
        let request = ReviewRequests.fork(source: source, newID: newID, atServerSeq: atServerSeq, changes: changes, name: name)
        let response: Documents.Fork.Output = try await caller.unary(Documents.Fork.descriptor, request, accessToken: try await accessToken())
        return response.document.id
    }

    func createBranch(parent: String, branchID: String, name: String, forkServerSeq: UInt64, changes: [Wiretuner_Doc_V1_Change]) async throws -> String {
        let request = ReviewRequests.createBranch(parent: parent, branchID: branchID, name: name, forkServerSeq: forkServerSeq, changes: changes)
        let response: Branches.CreateBranch.Output = try await caller.unary(Branches.CreateBranch.descriptor, request, accessToken: try await accessToken())
        return response.branch.branchDocumentID
    }
}
