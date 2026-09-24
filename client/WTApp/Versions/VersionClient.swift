import Foundation
import GRPCCore
import SwiftProtobuf
import WTProto

/// `VersionService.NameVersion`, the one version RPC menu:File[Save Version…] needs (saving.adoc,
/// "Saving a version"; IO-003).  A protocol so the saving is tested against fakes.
protocol VersionClient: Sendable {
    func nameVersion(_ request: Wiretuner_Docs_V1_NameVersionRequest, accessToken: String) async throws -> Wiretuner_Docs_V1_Version
}

/// The request, built apart from the call so it is tested without a server.
enum VersionRequests {
    static func nameVersion(documentID: String, version: PendingVersion, anchor: LocalChangeRef?) -> Wiretuner_Docs_V1_NameVersionRequest {
        var message = Wiretuner_Docs_V1_NameVersionRequest()
        message.documentID = documentID
        message.versionID = version.id
        message.serverSeq = version.serverSeq
        if let anchor {
            var id = Wiretuner_Doc_V1_OpId()
            id.counter = anchor.counter
            id.replica = anchor.replica
            message.throughLocalChange = id
        }
        message.name = version.name
        message.note = version.note
        return message
    }
}

/// grpc-swift 2 through the shared unary caller.
struct GRPCVersionClient: VersionClient {
    let caller: any UnaryCaller

    init(caller: any UnaryCaller) {
        self.caller = caller
    }

    init(api: URL, clientVersion: String, deviceID: String) {
        self.init(caller: GRPCUnaryCaller(api: api, clientVersion: clientVersion, deviceID: deviceID))
    }

    func nameVersion(_ request: Wiretuner_Docs_V1_NameVersionRequest, accessToken: String) async throws -> Wiretuner_Docs_V1_Version {
        let response: Wiretuner_Docs_V1_NameVersionResponse = try await caller.unary(
            Wiretuner_Docs_V1_VersionService.Method.NameVersion.descriptor, request, accessToken: accessToken
        )
        return response.version
    }
}
