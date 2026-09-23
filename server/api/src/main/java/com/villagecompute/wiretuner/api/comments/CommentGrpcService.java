package com.villagecompute.wiretuner.api.comments;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.comments.CommentOps.Id;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository;
import com.villagecompute.wiretuner.docs.v1.GetUnreadRequest;
import com.villagecompute.wiretuner.docs.v1.GetUnreadResponse;
import com.villagecompute.wiretuner.docs.v1.ListMentionedDocumentsRequest;
import com.villagecompute.wiretuner.docs.v1.ListMentionedDocumentsResponse;
import com.villagecompute.wiretuner.docs.v1.MarkReadRequest;
import com.villagecompute.wiretuner.docs.v1.MarkReadResponse;
import com.villagecompute.wiretuner.docs.v1.MutinyCommentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.ThreadUnread;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.docs.v1.CommentService} (COLLAB-030; comments.adoc, Server): read marks and unread
 * counts against the server's record of comments ({@link CommentIndex}), which holds every comment
 * the log does, so the count includes comments the caller's client has not received yet. Unread is
 * "newer than the thread's read mark (by element id), not written by the caller, not deleted".
 */
@GrpcService
public class CommentGrpcService extends MutinyCommentServiceGrpc.CommentServiceImplBase {

    static final String UNREAD = """
            WITH m AS (SELECT DISTINCT thread_counter, thread_replica FROM comment_notification
                       WHERE account_id = $2 AND document_id = $1 AND kind = 'mention' AND seen_at IS NULL)
            SELECT c.thread_counter, c.thread_replica, c.element_counter, c.element_replica,
                   m.thread_counter IS NOT NULL
            FROM comment c JOIN comment_thread t ON t.document_id = c.document_id
                 AND t.node_counter = c.thread_counter AND t.node_replica = c.thread_replica
            LEFT JOIN comment_read r ON r.account_id = $2 AND r.document_id = c.document_id
                 AND r.thread_counter = c.thread_counter AND r.thread_replica = c.thread_replica
            LEFT JOIN m ON m.thread_counter = c.thread_counter AND m.thread_replica = c.thread_replica
            WHERE c.document_id = $1 AND NOT c.deleted AND c.author_account_id IS DISTINCT FROM $2
              AND (r.account_id IS NULL OR %s)
            ORDER BY t.created_seq, t.node_counter, t.node_replica,
                     c.element_counter, (c.element_replica # %s)
            """.formatted(CommentIndex.newer("r.through_counter", "r.through_replica", "c.element_counter",
            "c.element_replica"), CommentIndex.MIN);

    /** Raises the read mark, never lowers it; then marks the thread's notifications up to it seen. */
    static final String MARK = """
            INSERT INTO comment_read AS r (account_id, document_id, thread_counter, thread_replica,
                                           through_counter, through_replica)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (account_id, document_id, thread_counter, thread_replica) DO UPDATE
                SET through_counter = EXCLUDED.through_counter, through_replica = EXCLUDED.through_replica,
                    updated_at = now()
                WHERE %s
            """.formatted(CommentIndex.newer("r.through_counter", "r.through_replica", "EXCLUDED.through_counter",
            "EXCLUDED.through_replica"));

    static final String SEEN = """
            UPDATE comment_notification SET seen_at = now()
            WHERE account_id = $1 AND document_id = $2 AND thread_counter = $3 AND thread_replica = $4
              AND seen_at IS NULL AND (kind = 'resolved' OR NOT %s)
            """.formatted(CommentIndex.newer("$5", "$6", "comment_counter", "comment_replica"));

    static final String MENTIONED = """
            SELECT DISTINCT n.document_id FROM comment_notification n JOIN document d ON d.id = n.document_id
            WHERE n.account_id = $1 AND n.kind = 'mention' AND n.seen_at IS NULL AND d.trashed_at IS NULL
              AND n.document_id > $2 AND %s
            ORDER BY n.document_id LIMIT $3
            """.formatted(LibraryRepository.VISIBLE.replace("?1", "$1"));

    /** ListMentionedDocuments' default page; the proto caps it at 500. */
    static final int MENTIONED_PAGE = 200;

    static final UUID NIL = new UUID(0, 0);

    @Inject
    RoleGuard guard;

    @Inject
    Pool pool;

    @Override
    public Uni<GetUnreadResponse> getUnread(GetUnreadRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        return Panache.withTransaction(() -> guard.require(documentId, Role.VIEWER))
                .chain(grant -> pool.preparedQuery(UNREAD).execute(Tuple.of(documentId, grant.principal().accountId())))
                .map(rows -> {
                    Map<Id, ThreadUnread.Builder> threads = new LinkedHashMap<>();
                    int total = 0;
                    for (Row row : rows) {
                        Id thread = new Id(row.getLong(0), row.getLong(1));
                        threads.computeIfAbsent(thread, id -> ThreadUnread.newBuilder().setThread(id.opId())
                                .setMentionsMe(row.getBoolean(4)))
                                .addUnread(new Id(row.getLong(2), row.getLong(3)).elementId());
                        total++;
                    }
                    GetUnreadResponse.Builder response = GetUnreadResponse.newBuilder().setTotal(total);
                    threads.values().forEach(response::addThreads);
                    return response.build();
                });
    }

    @Override
    public Uni<MarkReadResponse> markRead(MarkReadRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        Id thread = Id.of(request.getThread());
        Id through = Id.of(request.getThrough());
        return Panache.withTransaction(() -> guard.require(documentId, Role.VIEWER))
                .chain(grant -> {
                    UUID account = grant.principal().accountId();
                    return pool.withTransaction(connection -> connection.preparedQuery(MARK)
                            .execute(Tuple.from(new Object[] {account, documentId, thread.counter(), thread.replica(),
                                    through.counter(), through.replica()}))
                            .chain(() -> connection.preparedQuery(SEEN).execute(Tuple.from(new Object[] {account,
                                    documentId, thread.counter(), thread.replica(), through.counter(),
                                    through.replica()}))));
                })
                .replaceWith(MarkReadResponse.getDefaultInstance());
    }

    @Override
    public Uni<ListMentionedDocumentsResponse> listMentionedDocuments(ListMentionedDocumentsRequest request) {
        UUID after = request.getCursor().isEmpty() ? NIL : Cursors.uuid(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), MENTIONED_PAGE);
        return Panache.withTransaction(() -> guard.authenticated())
                .chain(principal -> pool.preparedQuery(MENTIONED).execute(Tuple.of(principal.accountId(), after,
                        pageSize + 1)))
                .map(rows -> {
                    ListMentionedDocumentsResponse.Builder response = ListMentionedDocumentsResponse.newBuilder();
                    for (Row row : rows) {
                        if (response.getDocumentIdsCount() == pageSize) {
                            response.setNextCursor(Cursors.encode(response.getDocumentIds(pageSize - 1)));
                            break;
                        }
                        response.addDocumentIds(row.getUUID(0).toString());
                    }
                    return response.build();
                });
    }
}
