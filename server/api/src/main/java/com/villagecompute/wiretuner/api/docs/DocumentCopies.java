package com.villagecompute.wiretuner.api.docs;

import java.time.Instant;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.DocumentRoles;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
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
import com.villagecompute.wiretuner.api.sync.ReplicaBinding;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Writing new documents: Create with its initial change, and the copy behind Fork and Duplicate.
 * Every path is idempotent by the client-chosen id: a retry by the owner into the same space
 * answers the existing document; anything else under that id is {@code DOCUMENT_EXISTS}.
 *
 * <p>Until the snapshotter exists (SRV-007) a copy re-issues the source's history rather than one
 * creation change: the source's hot log up to the fork point is copied row for row, keeping each
 * server_seq, and the caller's extra changes follow. A fork point part of which has already been
 * compacted is {@code HISTORY_UNAVAILABLE} (docs/spec/server.adoc, Services).
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
                .chain(() -> bindReplica(principal, id, change.getReplica(), change.getSeq(), null))
                .replaceWith(id);
    }

    /** Fork or Duplicate: a new document owned by the caller from the source's state plus extra changes. */
    Uni<UUID> copy(Principal principal, Copy copy) {
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
                    .flatMap(space -> changeLog.countUpTo(copy.source().id(), copy.atSeq()).flatMap(held -> held < copy.atSeq()
                            ? Uni.createFrom().failure(StatusExceptions.historyUnavailable(copy.atSeq(), head))
                            : writeCopy(principal, copy, space)));
        });
    }

    private Uni<UUID> writeCopy(Principal principal, Copy copy, Spaces.Space space) {
        DocumentRow source = copy.source();
        Document doc = newDocument(principal, copy.newId(), space, copy.folderId(), copy.name());
        doc.kind = source.kind();
        doc.featureLevel = source.featureLevel();
        doc.template = copy.template();
        doc.thumbnailBlob = source.thumbnailBlob();
        doc.thumbnailAt = source.thumbnailAtMicros() == null ? null
                : Instant.EPOCH.plusNanos(source.thumbnailAtMicros() * 1000);
        return replicas.list("id.documentId", source.id())
                .flatMap(sourceReplicas -> changeLog.replicaHeads(source.id(), copy.atSeq())
                        .flatMap(heads -> plan(principal, copy, bindings(sourceReplicas), heads)))
                .flatMap(plan -> persistOwned(principal, doc, space)
                        .chain(documents::flush)
                        .chain(() -> changeLog.copyRange(source.id(), doc.id, copy.atSeq()))
                        .chain(() -> documentBlobs.copyReferences(source.id(), doc.id))
                        .chain(() -> appendAll(doc, copy.atSeq(), plan.appended()))
                        .chain(() -> Multi.createFrom().iterable(plan.callerReplicas().entrySet())
                                .onItem().transformToUniAndConcatenate(e -> bindReplica(principal, doc.id, e.getKey(),
                                        e.getValue(), plan.devices().get(e.getKey())))
                                .collect().asList())
                        .invoke(() -> doc.headSeq = copy.atSeq() + plan.appended().size()))
                .replaceWith(copy.newId());
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
     * Checks the extra changes against the copied range: a change already in it with the same
     * bytes is dropped, with other bytes is {@code REPLICA_CONFLICT}; a replica bound to another
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

    private Uni<Void> appendAll(Document doc, long after, List<Change> appended) {
        return Multi.createFrom().range(0, appended.size())
                .onItem().transformToUniAndConcatenate(i -> changeLog.persist(logRow(doc.id, after + 1 + i, appended.get(i))))
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
