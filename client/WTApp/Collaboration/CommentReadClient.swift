import Foundation
import WTProto
import WTSync

extension GRPCCommentReadService {
    /// `CommentService.GetUnread` and `MarkRead` through the app's unary caller.
    init(caller: any UnaryCaller, accessToken: @escaping @Sendable () async throws -> String) {
        typealias Methods = Wiretuner_Docs_V1_CommentService.Method
        self.init(getUnread: { request in
            let response: Methods.GetUnread.Output = try await caller.unary(Methods.GetUnread.descriptor, request, accessToken: try await accessToken())
            return response
        }, markRead: { request in
            let _: Methods.MarkRead.Output = try await caller.unary(Methods.MarkRead.descriptor, request, accessToken: try await accessToken())
        })
    }
}

/// The documents holding an unseen mention of this account (the library window's dots;
/// `CommentService.ListMentionedDocuments`).
protocol MentionedDocumentsClient: Sendable {
    func mentionedDocuments() async throws -> Set<String>
}

struct GRPCMentionedDocuments: MentionedDocumentsClient {
    typealias Methods = Wiretuner_Docs_V1_CommentService.Method

    let caller: any UnaryCaller
    let accessToken: @Sendable () async throws -> String

    /// Every page.
    func mentionedDocuments() async throws -> Set<String> {
        var result: Set<String> = []
        var cursor = ""
        repeat {
            var request = Wiretuner_Docs_V1_ListMentionedDocumentsRequest()
            request.cursor = cursor
            request.pageSize = 500
            let response: Methods.ListMentionedDocuments.Output = try await caller.unary(Methods.ListMentionedDocuments.descriptor, request,
                                                                                          accessToken: try await accessToken())
            result.formUnion(response.documentIds)
            cursor = response.nextCursor
        } while !cursor.isEmpty
        return result
    }
}
