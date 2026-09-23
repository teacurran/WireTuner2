package com.villagecompute.wiretuner.api.docs;

import java.time.Instant;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.api.auth.DocumentRoles;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.history.ChangeIndex;
import com.villagecompute.wiretuner.api.history.DocumentStates;
import com.villagecompute.wiretuner.api.history.Snapshots;
import com.villagecompute.wiretuner.api.persistence.ChangeLog;
import com.villagecompute.wiretuner.api.persistence.ChangeLogId;
import com.villagecompute.wiretuner.api.persistence.ChangeLogRepository;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentBlobRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentMember;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberId;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository.DocumentRow;
import com.villagecompute.wiretuner.api.persistence.Replica;
import com.villagecompute.wiretuner.api.persistence.ReplicaId;
import com.villagecompute.wiretuner.api.persistence.ReplicaRepository;
import com.villagecompute.wiretuner.api.persistence.Snapshot;
import com.villagecompute.wiretuner.api.persistence.SnapshotId;
import com.villagecompute.wiretuner.api.persistence.SnapshotRepository;
import com.villagecompute.wiretuner.api.sync.ReplicaBinding;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Writing new documents: Create with its initial change, and the copy behind Fork and Duplicate.
 * Every path is idempotent by the client-chosen id: a retry by the owner into the same space
 * answers the existing document; anything else under that id is {@code DOCUMENT_EXISTS}.
 *
 * <p>A copy starts from the source's state at the fork point (SRV-007): the newest snapshot at or
 * before it plus the tail through {@code wt-crdt} ({@link DocumentStates}), stored as the copy's
 * snapshot at the same server_seq, so the copy keeps every node id, register OpId and unstable
 * tombstone (branches.adoc, Merge semantics) and its head starts at the fork point with no log
 * rows below it; the caller's extra changes follow. A fork point the retained history cannot
 * rebuild is {@code HISTORY_UNAVAILABLE} (docs/spec/server.adoc, Services).
 */
@ApplicationScoped
public class DocumentCopies {

    /** One Fork or Duplicate, with its defaults already applied. */
    public record Copy(DocumentRow source, UUID newId, UUID spaceId, UUID folderId, String name, long atSeq,
            List<Change> changes, boolean template) {
    }

    @Inject
    DocumentRoles roles;

    @Inject
    Spaces spaces;

    @Inject
    DocumentRepository documents;

    @Inject
    DocumentMemberRepository members;

    @Inject
    ChangeLogRepository changeLog;

    @Inject
    ReplicaRepository replicas;

    @Inject
    DocumentBlobRepository documentBlobs;

    @Inject
    DocumentStates states;

    @Inject
    Snapshots snapshots;

    @Inject
    SnapshotRepository snapshotRows;

    /**
     * A Create, Fork or Duplicate whose id already exists: the same call again if the caller owns
     * that document in the requested space and (for Create) its first change is the one sent now.
     */
    Uni<UUID> retried(Principal principal, Document existing, UUID spaceId, Change initialChange) {
        UUID existingSpace = existing.teamId == null ? existing.ownerAccountId : existing.teamId;
        if (!existingSpace.equals(spaceId)) {
            return Uni.createFrom().failure(StatusExceptions.documentExists());
        }
        return roles.effectiveRole(existing.id, principal.accountId()).flatMap(role -> {
            if (role != Role.OWNER) {
                return Uni.createFrom().failure(StatusExceptions.documentExists());
            }
            if (initialChange == null) {
                return Uni.createFrom().item(existing.id);
            }
            return changeLog.findById(new ChangeLogId(existing.id, 1)).flatMap(first ->
                    first != null && Arrays.equals(first.bytes, initialChange.toByteArray())
                            ? Uni.createFrom().item(existing.id)
                            : Uni.createFrom().failure(StatusExceptions.documentExists()));
        });
    }

    /** A new document with the caller as owner and, when sent, its first change at server_seq 1. */
    Uni<UUID> create(Principal principal, UUID id, Spaces.Space space, UUID folderId, CreateRequest request) {
        Document doc = newDocument(principal, id, space, folderId, request.getName());
        doc.kind = DocumentMessages.kindName(request.getKind());
        Uni<Void> written = persistOwned(principal, doc, space);
        if (!request.hasInitialChange()) {
            return written.replaceWith(id);
        }
        Change change = request.getInitialChange();
        if (change.getSeq() != 1) {
            return Uni.createFrom().failure(StatusExceptions.seqGap(1, change.getSeq()));
        }
        doc.headSeq = 1;
        return written
                .chain(() -> changeLog.persist(logRow(id, 1, change)))
                .chain(() -> changeLog.flush())
                .chain(() -> Panache.getSession().chain(session -> ChangeIndex.write(session, id, 1, change)))
                .chain(() -> bindReplica(principal, id, change.getReplica(), change.getSeq(), null))
                .replaceWith(id);
    }

    /** Fork or Duplicate: a new document owned by the caller from the source's state plus extra changes. */
    public Uni<UUID> copy(Principal principal, Copy copy) {
        return documents.findById(copy.newId()).flatMap(existing -> {
            if (existing != null) {
                return retried(principal, existing, copy.spaceId(), null);
            }
            long head = copy.source().headSeq();
            if (copy.atSeq() > head) {
                return Uni.createFrom().failure(StatusExceptions.historyUnavailable(copy.atSeq(), head));
            }
            return spaces.creatable(principal, copy.spaceId())
                    .flatMap(space -> spaces.folderIn(copy.folderId(), copy.spaceId()).replaceWith(space))
                    .flatMap(space -> {
                        Document doc = newDocument(principal, copy.newId(), space, copy.folderId(), copy.name());
                        return writeCopy(principal, copy, doc, () -> persistOwned(principal, doc, space));
                    });
        });
    }

    /**
     * A branch document (SRV-011): the parent's state at the fork point in the parent's space and
     * folder, with the parent's owner. It gets no member rows: its roles are the parent's, resolved
     * through it on every lookup (COLLAB-019; branches.adoc, Branch permissions). The caller has been
     * checked for editor on the parent.
     */
    public Uni<UUID> branch(Principal principal, Copy copy) {
        DocumentRow parent = copy.source();
        Document doc = new Document();
        doc.id = copy.newId();
        doc.ownerAccountId = parent.ownerAccountId();
        doc.teamId = parent.teamId();
        doc.folderId = parent.folderId();
        doc.name = copy.name();
        doc.createdByAccountId = principal.accountId();
        return writeCopy(principal, copy, doc, () -> documents.persist(doc).replaceWithVoid());
    }

    /** Writes {@code doc} ({@code persist}) as a copy of the source at the fork point, then appends the extra changes. */
    private Uni<UUID> writeCopy(Principal principal, Copy copy, Document doc, Supplier<Uni<Void>> persist) {
        DocumentRow source = copy.source();
        doc.kind = source.kind();
        doc.featureLevel = source.featureLevel();
        doc.template = copy.template();
        doc.thumbnailBlob = source.thumbnailBlob();
        doc.thumbnailAt = source.thumbnailAtMicros() == null ? null
                : Instant.EPOCH.plusNanos(source.thumbnailAtMicros() * 1000);
        return states.at(source.id(), copy.atSeq()).flatMap(engine -> replicas.list("id.documentId", source.id())
                .flatMap(sourceReplicas -> plan(principal, copy, bindings(sourceReplicas), heads(engine)))
                .flatMap(plan -> persist.get()
                        .chain(documents::flush)
                        .chain(() -> snapshot(doc.id, copy.atSeq(), engine))
                        .chain(() -> documentBlobs.copyReferences(source.id(), doc.id))
                        .chain(() -> Panache.getSession().chain(session -> ChangeIndex.copyNames(session, source.id(),
                                doc.id, copy.atSeq())))
                        .chain(() -> appendAll(doc, copy.atSeq(), plan.appended()))
                        .chain(() -> Multi.createFrom().iterable(plan.callerReplicas().entrySet())
                                .onItem().transformToUniAndConcatenate(e -> bindReplica(principal, doc.id, e.getKey(),
                                        e.getValue(), plan.devices().get(e.getKey())))
                                .collect().asList())
                        .invoke(() -> doc.headSeq = copy.atSeq() + plan.appended().size())))
                .replaceWith(copy.newId());
    }

    /** The highest seq the state holds of each replica. */
    private static Map<Long, Long> heads(Engine engine) {
        Map<Long, Long> heads = new HashMap<>();
        engine.store().replicas().forEach((replica, state) -> heads.put(replica, state.seq()));
        return heads;
    }

    /** The copy's snapshot at the fork point (none for an empty fork point). */
    private Uni<Void> snapshot(UUID documentId, long atSeq, Engine engine) {
        if (atSeq == 0) {
            return Uni.createFrom().voidItem();
        }
        Snapshots.Encoded encoded = Snapshots.encode(documentId, atSeq, engine);
        Snapshot row = new Snapshot();
        row.id = new SnapshotId(documentId, atSeq);
        row.objectKey = encoded.key();
        row.stateHash = encoded.stateHash();
        row.sizeBytes = encoded.object().length;
        row.uncompressedSize = encoded.uncompressedSize();
        row.nodeCount = encoded.nodeCount();
        return snapshots.put(encoded).chain(() -> snapshotRows.persist(row)).replaceWithVoid();
    }

    /** The extra changes to append and the caller's replicas on the copy, with their last seqs and devices. */
    record Plan(List<Change> appended, Map<Long, Long> callerReplicas, Map<Long, UUID> devices) {
    }

    private static Map<Long, Replica> bindings(List<Replica> sourceReplicas) {
        Map<Long, Replica> byId = new HashMap<>();
        sourceReplicas.forEach(r -> byId.put(r.id.replicaId(), r));
        return byId;
    }

    /**
     * Checks the extra changes against the copied range: a change already in it (in the source's
     * hot log up to the fork point) with the same bytes is dropped, with other bytes is
     * {@code REPLICA_CONFLICT}; a replica bound to another
     * account on the source is {@code REPLICA_CONFLICT}; seqs continue each replica without gaps
     * ({@code SEQ_GAP}).
     */
    private Uni<Plan> plan(Principal principal, Copy copy, Map<Long, Replica> sourceReplicas, Map<Long, Long> heads) {
        Map<Long, Long> lastSeq = new HashMap<>(heads);
        Map<Long, Long> callerReplicas = new HashMap<>();
        Map<Long, UUID> devices = new HashMap<>();
        sourceReplicas.values().stream()
                .filter(r -> r.accountId.equals(principal.accountId()) && heads.containsKey(r.id.replicaId()))
                .forEach(r -> {
                    callerReplicas.put(r.id.replicaId(), heads.get(r.id.replicaId()));
                    devices.put(r.id.replicaId(), r.deviceId);
                });
        List<Change> appended = new java.util.ArrayList<>();
        return Multi.createFrom().iterable(copy.changes())
                .onItem().transformToUniAndConcatenate(change -> changeLog.findByReplicaSeq(copy.source().id(),
                        change.getReplica(), change.getSeq(), copy.atSeq()).invoke(existing -> {
                            if (existing != null) {
                                if (!Arrays.equals(existing.bytes, change.toByteArray())) {
                                    throw StatusExceptions.replicaConflict(change.getReplica(), change.getSeq());
                                }
                                return;
                            }
                            Replica bound = sourceReplicas.get(change.getReplica());
                            if (bound != null && !bound.accountId.equals(principal.accountId())) {
                                throw StatusExceptions.replicaConflict(change.getReplica(), change.getSeq());
                            }
                            long expected = lastSeq.getOrDefault(change.getReplica(), 0L) + 1;
                            if (change.getSeq() != expected) {
                                throw StatusExceptions.seqGap(expected, change.getSeq());
                            }
                            lastSeq.put(change.getReplica(), change.getSeq());
                            callerReplicas.put(change.getReplica(), change.getSeq());
                            appended.add(change);
                        }))
                .collect().asList()
                .map(ignored -> new Plan(appended, callerReplicas, devices));
    }

    /** Appends the extra changes after the fork point, each with its history index (COLLAB-020). */
    private Uni<Void> appendAll(Document doc, long after, List<Change> appended) {
        return Multi.createFrom().range(0, appended.size())
                .onItem().transformToUniAndConcatenate(i -> changeLog.persist(logRow(doc.id, after + 1 + i, appended.get(i)))
                        .chain(() -> changeLog.flush())
                        .chain(() -> Panache.getSession().chain(session -> ChangeIndex.write(session, doc.id, after + 1 + i,
                                appended.get(i)))))
                .collect().asList()
                .replaceWithVoid();
    }

    private static Document newDocument(Principal principal, UUID id, Spaces.Space space, UUID folderId, String name) {
        Document doc = new Document();
        doc.id = id;
        doc.ownerAccountId = space.team() ? null : space.id();
        doc.teamId = space.team() ? space.id() : null;
        doc.folderId = folderId;
        doc.name = name;
        doc.createdByAccountId = principal.accountId();
        return doc;
    }

    /** Persists the row; a team document's owner is its creator's {@code document_member} row. */
    private Uni<Void> persistOwned(Principal principal, Document doc, Spaces.Space space) {
        Uni<Void> persisted = documents.persist(doc).replaceWithVoid();
        if (!space.team()) {
            return persisted;
        }
        DocumentMember owner = new DocumentMember();
        owner.id = new DocumentMemberId(doc.id, principal.accountId());
        owner.role = Role.OWNER.dbName();
        owner.addedBy = principal.accountId();
        return persisted.chain(() -> members.persist(owner)).replaceWithVoid();
    }

    private static ChangeLog logRow(UUID documentId, long serverSeq, Change change) {
        byte[] bytes = change.toByteArray();
        ChangeLog row = new ChangeLog();
        row.id = new ChangeLogId(documentId, serverSeq);
        row.replicaId = change.getReplica();
        row.seq = change.getSeq();
        row.bytes = bytes;
        row.byteSize = bytes.length;
        return row;
    }

    /** Binds the replica to the caller on the document (docs/spec/security.adoc, Replica binding). */
    private Uni<Void> bindReplica(Principal principal, UUID documentId, long replicaId, long lastSeq, UUID device) {
        Replica replica = new Replica();
        replica.id = new ReplicaId(documentId, replicaId);
        replica.accountId = principal.accountId();
        UUID bound = device != null ? device : principal.deviceId();
        replica.deviceId = bound != null ? bound : ReplicaBinding.NO_DEVICE;
        replica.lastSeq = lastSeq;
        return replicas.persist(replica).replaceWithVoid();
    }
}
