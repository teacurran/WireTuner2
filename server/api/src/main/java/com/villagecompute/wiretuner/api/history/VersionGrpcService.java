package com.villagecompute.wiretuner.api.history;

import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.api.auth.DocumentRoles;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.docs.DocumentCopies;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository;
import com.villagecompute.wiretuner.api.persistence.VersionRepository;
import com.villagecompute.wiretuner.api.persistence.VersionRepository.VersionRow;
import com.villagecompute.wiretuner.api.sync.ChangeReader;
import com.villagecompute.wiretuner.api.sync.Protos;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.DeleteVersionRequest;
import com.villagecompute.wiretuner.docs.v1.DeleteVersionResponse;
import com.villagecompute.wiretuner.docs.v1.HistoryRow;
import com.villagecompute.wiretuner.docs.v1.ListHistoryRequest;
import com.villagecompute.wiretuner.docs.v1.ListHistoryResponse;
import com.villagecompute.wiretuner.docs.v1.ListNodeHistoryRequest;
import com.villagecompute.wiretuner.docs.v1.ListNodeHistoryResponse;
import com.villagecompute.wiretuner.docs.v1.ListVersionsRequest;
import com.villagecompute.wiretuner.docs.v1.ListVersionsResponse;
import com.villagecompute.wiretuner.docs.v1.MutinyVersionServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.NameVersionRequest;
import com.villagecompute.wiretuner.docs.v1.NameVersionResponse;
import com.villagecompute.wiretuner.docs.v1.PinVersionRequest;
import com.villagecompute.wiretuner.docs.v1.PinVersionResponse;
import com.villagecompute.wiretuner.docs.v1.RestoreAsCopyRequest;
import com.villagecompute.wiretuner.docs.v1.RestoreAsCopyResponse;
import com.villagecompute.wiretuner.docs.v1.Session;
import com.villagecompute.wiretuner.docs.v1.UpdateVersionRequest;
import com.villagecompute.wiretuner.docs.v1.UpdateVersionResponse;
import com.villagecompute.wiretuner.docs.v1.Version;
import com.villagecompute.wiretuner.sync.v1.Participant;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.docs.v1.VersionService} (SRV-011; history.adoc, Specification). Named versions
 * are bookmarks on a server_seq, identified by the client's UUIDv7; pinning one materializes a
 * snapshot at exactly its seq ({@link Snapshots}), so it stays viewable after its changes leave the
 * retained log; restore-as-copy is a Fork at the seq with no changes. The timeline and node history
 * come from {@link History}. Any role reads; editor or owner names, updates, pins and deletes.
 */
@GrpcService
public class VersionGrpcService extends MutinyVersionServiceGrpc.VersionServiceImplBase {

    /** The default page of every list here. */
    static final int PAGE = 50;

    /** The replica's logged changes, newest first: where a version named offline resolves its change. */
    static final String REPLICA_CHANGES = """
            SELECT server_seq, bytes FROM change_log WHERE document_id = $1 AND replica_id = $2 ORDER BY seq DESC
            """;

    @Inject
    RoleGuard guard;

    @Inject
    DocumentRoles roles;

    @Inject
    VersionRepository versions;

    @Inject
    History history;

    @Inject
    ChangeReader reader;

    @Inject
    DocumentStates states;

    @Inject
    Snapshots snapshots;

    @Inject
    DocumentCopies copies;

    @Inject
    LibraryRepository library;

    @Inject
    DocumentRepository documents;

    @Inject
    Pool pool;

    // ---------------------------------------------------------------------------------- Timeline

    @Override
    public Uni<ListHistoryResponse> listHistory(ListHistoryRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        int pageSize = Cursors.pageSize(request.getPageSize(), PAGE);
        Long cursor = request.getCursor().isEmpty() ? null : Cursors.number(Cursors.decode(request.getCursor(), 1)[0]);
        return tx(() -> guard.require(documentId, Role.VIEWER)).chain(() -> reader.head(documentId)).chain(head -> {
            long before = cursor != null ? cursor : request.getBeforeServerSeq() == 0 ? head + 1 : request.getBeforeServerSeq();
            return history.sessions(documentId, before, pageSize, request.getQuery(), request.getExpandSession())
                    .chain(page -> history.retainedFrom(documentId, head)
                            .chain(retained -> tx(() -> versions.between(documentId, page.nextBefore(), before))
                                    .map(named -> timeline(page.sessions(), named, page.nextBefore(), retained))));
        });
    }

    /** Sessions and versions interleaved by server_seq, newest first; a version goes above a session ending at its seq. */
    static ListHistoryResponse timeline(List<Session> sessions, List<VersionRow> named, long nextBefore, long retained) {
        ListHistoryResponse.Builder response = ListHistoryResponse.newBuilder().setRetainedFromSeq(retained);
        int v = 0;
        for (Session session : sessions) {
            while (v < named.size() && named.get(v).serverSeq() >= session.getLastServerSeq()) {
                response.addRows(HistoryRow.newBuilder().setVersion(version(named.get(v++))));
            }
            response.addRows(HistoryRow.newBuilder().setSession(session));
        }
        named.subList(v, named.size()).forEach(row -> response.addRows(HistoryRow.newBuilder().setVersion(version(row))));
        if (nextBefore > 0) {
            response.setNextCursor(Cursors.encode(Long.toString(nextBefore)));
        }
        return response.build();
    }

    @Override
    public Uni<ListNodeHistoryResponse> listNodeHistory(ListNodeHistoryRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        int pageSize = Cursors.pageSize(request.getPageSize(), PAGE);
        Long cursor = request.getCursor().isEmpty() ? null : Cursors.number(Cursors.decode(request.getCursor(), 1)[0]);
        return tx(() -> guard.require(documentId, Role.VIEWER)).chain(() -> reader.head(documentId))
                .chain(head -> history.nodeChanges(documentId, OpId.of(request.getNode()), cursor != null ? cursor : head + 1,
                        pageSize))
                .map(page -> {
                    ListNodeHistoryResponse.Builder response = ListNodeHistoryResponse.newBuilder()
                            .addAllChanges(page.changes()).addAllAuthors(page.authors());
                    if (page.nextBefore() > 0) {
                        response.setNextCursor(Cursors.encode(Long.toString(page.nextBefore())));
                    }
                    return response.build();
                });
    }

    // ---------------------------------------------------------------------------------- Versions

    @Override
    public Uni<ListVersionsResponse> listVersions(ListVersionsRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        int pageSize = Cursors.pageSize(request.getPageSize(), PAGE);
        long afterMicros = Long.MAX_VALUE;
        UUID afterId = new UUID(-1, -1);
        if (!request.getCursor().isEmpty()) {
            String[] parts = Cursors.decode(request.getCursor(), 2);
            afterMicros = Cursors.number(parts[0]);
            afterId = Cursors.uuid(parts[1]);
        }
        long micros = afterMicros;
        UUID after = afterId;
        return tx(() -> guard.require(documentId, Role.VIEWER)
                .chain(() -> versions.list(documentId, micros, after, pageSize + 1)))
                .map(rows -> {
                    List<VersionRow> shown = rows.size() > pageSize ? rows.subList(0, pageSize) : rows;
                    ListVersionsResponse.Builder response = ListVersionsResponse.newBuilder();
                    shown.forEach(row -> response.addVersions(version(row)));
                    if (rows.size() > pageSize) {
                        VersionRow last = shown.get(shown.size() - 1);
                        response.setNextCursor(Cursors.encode(Long.toString(last.createdAtMicros()), last.id().toString()));
                    }
                    return response.build();
                });
    }

    @Override
    public Uni<NameVersionResponse> nameVersion(NameVersionRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        UUID versionId = UUID.fromString(request.getVersionId());
        return tx(() -> guard.require(documentId, Role.EDITOR).flatMap(grant -> versions.find(versionId).flatMap(existing -> {
            if (existing != null) {
                return existing.documentId().equals(documentId) ? Uni.createFrom().item(existing)
                        : Uni.createFrom().failure(StatusExceptions.documentExists());
            }
            return seq(documentId, request)
                    .chain(seq -> versions.insert(versionId, documentId, seq, request.getName(), request.getNote(),
                            grant.principal().accountId()))
                    .chain(() -> versions.find(versionId));
        }))).map(row -> NameVersionResponse.newBuilder().setVersion(version(row)).build());
    }

    /**
     * The seq a new version bookmarks: the server_seq of {@code through_local_change}'s change when
     * given (the one of the replica's logged changes whose counters it falls in; history.adoc,
     * Version naming), else the requested seq, the head for 0; a seq beyond the head or a change not
     * in the log is {@code HISTORY_UNAVAILABLE}.
     */
    private Uni<Long> seq(UUID documentId, NameVersionRequest request) {
        return reader.head(documentId).chain(head -> {
            if (request.hasThroughLocalChange()) {
                long replica = request.getThroughLocalChange().getReplica();
                long counter = request.getThroughLocalChange().getCounter();
                return pool.preparedQuery(REPLICA_CHANGES).execute(Tuple.of(documentId, replica)).map(rows -> {
                    for (Row row : rows) {
                        Change change = Protos.change(row.getBuffer(1).getBytes());
                        if (Long.compareUnsigned(change.getStartCounter(), counter) <= 0) {
                            return row.getLong(0);
                        }
                    }
                    throw StatusExceptions.historyUnavailable(counter, head);
                });
            }
            long seq = request.getServerSeq() == 0 ? head : request.getServerSeq();
            return seq > head ? Uni.createFrom().failure(StatusExceptions.historyUnavailable(seq, head))
                    : Uni.createFrom().item(seq);
        });
    }

    @Override
    public Uni<UpdateVersionResponse> updateVersion(UpdateVersionRequest request) {
        UUID versionId = UUID.fromString(request.getVersionId());
        return tx(() -> editable(versionId)
                .chain(row -> versions.update(versionId, request.hasName(), request.getName(), request.hasNote(),
                        request.getNote()))
                .chain(() -> versions.find(versionId)))
                .map(row -> UpdateVersionResponse.newBuilder().setVersion(version(row)).build());
    }

    @Override
    public Uni<DeleteVersionResponse> deleteVersion(DeleteVersionRequest request) {
        UUID versionId = UUID.fromString(request.getVersionId());
        return tx(() -> editable(versionId).chain(() -> versions.delete(versionId)))
                .replaceWith(DeleteVersionResponse.getDefaultInstance());
    }

    @Override
    public Uni<PinVersionResponse> pinVersion(PinVersionRequest request) {
        UUID versionId = UUID.fromString(request.getVersionId());
        return tx(() -> editable(versionId))
                .call(row -> request.getPinned() && row.serverSeq() > 0
                        ? states.at(row.documentId(), row.serverSeq()).chain(engine -> snapshots.write(row.documentId(),
                                row.serverSeq(), engine, engine.store().stableSeq(), 0))
                        : Uni.createFrom().voidItem())
                .chain(row -> tx(() -> versions.pin(versionId, request.getPinned()).chain(() -> versions.find(versionId))))
                .map(row -> PinVersionResponse.newBuilder().setVersion(version(row)).build());
    }

    /** The version, with the caller checked for editor on its document; {@code NOT_FOUND} for an unknown id. */
    private Uni<VersionRow> editable(UUID versionId) {
        return versions.find(versionId)
                .onItem().ifNull().failWith(StatusExceptions::documentNotFound)
                .call(row -> guard.require(row.documentId(), Role.EDITOR));
    }

    @Override
    public Uni<RestoreAsCopyResponse> restoreAsCopy(RestoreAsCopyRequest request) {
        UUID sourceId = UUID.fromString(request.getDocumentId());
        UUID newId = UUID.fromString(request.getNewDocumentId());
        UUID space = request.getSpaceId().isEmpty() ? null : UUID.fromString(request.getSpaceId());
        UUID folderId = request.getFolderId().isEmpty() ? null : UUID.fromString(request.getFolderId());
        return tx(() -> guard.require(sourceId, Role.VIEWER).flatMap(grant -> library.row(sourceId).flatMap(source -> {
            Principal principal = grant.principal();
            DocumentCopies.Copy copy = new DocumentCopies.Copy(source, newId, space == null ? principal.accountId() : space,
                    folderId, request.getName().isEmpty() ? source.name() : request.getName(), request.getServerSeq(),
                    List.of(), false);
            return copies.copy(principal, copy)
                    .chain(documents::flush)
                    .chain(() -> library.row(newId))
                    .chain(row -> roles.effectiveRole(newId, principal.accountId()).map(role -> DocumentMessages.document(row, role)));
        }))).map(doc -> RestoreAsCopyResponse.newBuilder().setDocument(doc).build());
    }

    /** The {@code Version} message of a row. */
    static Version version(VersionRow row) {
        return Version.newBuilder()
                .setId(row.id().toString())
                .setDocumentId(row.documentId().toString())
                .setServerSeq(row.serverSeq())
                .setName(row.name())
                .setNote(row.note())
                .setCreatedBy(Participant.newBuilder().setUserId(row.authorId()).setDisplayName(row.authorName()))
                .setCreatedAt(DocumentMessages.micros(row.createdAtMicros()))
                .setPinned(row.pinned())
                .build();
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
