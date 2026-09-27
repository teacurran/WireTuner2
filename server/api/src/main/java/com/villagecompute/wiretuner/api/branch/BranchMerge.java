package com.villagecompute.wiretuner.api.branch;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.comments.CommentIndex;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.history.ChangeIndex;
import com.villagecompute.wiretuner.api.history.DocumentStates;
import com.villagecompute.wiretuner.api.history.TouchedNodes;
import com.villagecompute.wiretuner.api.persistence.BranchRepository;
import com.villagecompute.wiretuner.api.persistence.BranchRepository.BranchRow;
import com.villagecompute.wiretuner.api.sync.ChangeIngest;
import com.villagecompute.wiretuner.api.sync.DocumentEvents;
import com.villagecompute.wiretuner.api.sync.ChangeReader;
import com.villagecompute.wiretuner.api.sync.Participants;
import com.villagecompute.wiretuner.api.sync.Protos;
import com.villagecompute.wiretuner.api.sync.SyncBus;
import com.villagecompute.wiretuner.crdt.NodeStore;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.MergeBranchRequest;
import com.villagecompute.wiretuner.docs.v1.MergeBranchResponse;
import com.villagecompute.wiretuner.sync.v1.BranchEventKind;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.core.buffer.Buffer;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.SqlConnection;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * {@code BranchService.MergeBranch} (SRV-011; branches.adoc, Merge semantics). The branch's changes
 * after its last merge point (or its fork) are replayed into the parent as they are, in branch-log
 * order -- except that the ops naming a node the review decided "Use main" for
 * ({@code excluded_nodes}) become {@code Noop}s over the same counters ({@link TouchedNodes#without}),
 * so the parent's version of those nodes stands -- then the review's {@code resolutions} are pushed
 * as ordinary changes from the caller's parent replica.
 *
 * <p>The replay is one transaction holding the parent's row lock: when the parent has changes after
 * {@code reviewed_parent_seq} (in the hot log) naming an excluded node or a node a resolution names,
 * the merge is {@code FAILED_PRECONDITION / MERGE_STALE}; a replayed (replica, seq) the parent
 * already holds is {@code REPLICA_CONFLICT}; otherwise the changes take the next server_seqs, with
 * {@code merged_from_branch_id} set and the parent's collection point as their horizon (a branch
 * does not hold back the parent's garbage collection). They are then fanned out to the parent's
 * subscribers with their authors on the branch, one publish after the other. Ops that name a node
 * the parent does not have (compacted there since the fork, or never merged) are counted as
 * {@code dropped_ops}. Once recorded, the merge is told to the parent's and the branch's sessions as a
 * {@code BranchEvent} (COLLAB-019).
 */
@ApplicationScoped
public class BranchMerge {

    private static final Logger LOG = Logger.getLogger(BranchMerge.class);

    static final String LOCK = "SELECT head_seq, collect_seq, collect_time_ms FROM document WHERE id = $1 FOR UPDATE";

    static final String SINCE = "SELECT bytes FROM change_log WHERE document_id = $1 AND server_seq > $2";

    static final String HELD = """
            SELECT c.replica_id, c.seq FROM change_log c
            JOIN unnest($2::bigint[], $3::bigint[]) AS k(replica_id, seq) ON k.replica_id = c.replica_id AND k.seq = c.seq
            WHERE c.document_id = $1 LIMIT 1
            """;

    static final String INSERT = """
            INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size, horizon_seq, horizon_ms,
                                    merged_from_branch_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            """;

    static final String HEAD = "UPDATE document SET head_seq = $2 WHERE id = $1";

    /** The caller and the branch, checked. */
    record Merging(BranchRow branch, ChangeIngest.Pusher pusher) {
    }

    /** Where the replay landed in the parent: the seqs before and after it. */
    record Landed(long before, long last) {
    }

    @Inject
    RoleGuard guard;

    @Inject
    BranchRepository branches;

    @Inject
    Participants participants;

    @Inject
    ChangeReader reader;

    @Inject
    DocumentStates states;

    @Inject
    ChangeIngest ingest;

    @Inject
    SyncBus bus;

    @Inject
    Pool pool;

    @Inject
    DocumentEvents events;

    public Uni<MergeBranchResponse> merge(MergeBranchRequest request) {
        UUID branchId = UUID.fromString(request.getBranchDocumentId());
        Set<OpId> excluded = new HashSet<>();
        request.getExcludedNodesList().forEach(node -> excluded.add(OpId.of(node)));
        Set<OpId> reviewed = new HashSet<>(excluded);
        request.getResolutionsList().forEach(change -> reviewed.addAll(TouchedNodes.of(change)));
        return Panache.withTransaction(() -> guard.require(branchId, Role.VIEWER)
                        .chain(() -> branches.find(branchId))
                        .onItem().ifNull().failWith(StatusExceptions::documentNotFound)
                        .chain(branch -> guard.require(branch.parentId(), Role.EDITOR)
                                .chain(grant -> participants.of(grant.principal().accountId())
                                        .map(author -> new Merging(branch, new ChangeIngest.Pusher(grant.principal(), author,
                                                grant.role()))))))
                .chain(merging -> {
                    BranchRow branch = merging.branch();
                    long from = Math.max(branch.forkSeq(), branch.mergedBranchSeq());
                    return reader.range(branchId, from, branch.headSeq()).collect().asList()
                            .map(changes -> changes.stream().map(c -> c.toBuilder()
                                    .setChange(TouchedNodes.without(c.getChange(), excluded)).build()).toList())
                            .chain(changes -> dropped(branch.parentId(), changes).chain(dropped -> replay(branch, changes,
                                    request.getReviewedParentSeq(), reviewed)
                                    .call(landed -> fanOut(branch, changes, landed.before()))
                                    .chain(landed -> resolve(merging.pusher(), branch.parentId(),
                                            request.getResolutionsList(), landed))
                                    .chain(landed -> Panache.withTransaction(() -> branches.merged(branchId, branch.headSeq(),
                                                    landed.last(), request.getKeepOpen() ? "active" : "merged")
                                            .chain(() -> branches.find(branchId))
                                            .chain(merged -> events.event(merging.pusher().principal().accountId(),
                                                    actor -> BranchGrpcService.event(merged,
                                                            BranchEventKind.BRANCH_EVENT_KIND_MERGED, actor))
                                                    .map(event -> new BranchGrpcService.Told(merged, event))))
                                            .call(told -> events.publish(branch.parentId(), told.event())
                                                    .chain(() -> events.publish(branchId, told.event())))
                                            .map(told -> response(told.row(), landed, dropped)))));
                });
    }

    private static MergeBranchResponse response(BranchRow merged, Landed landed, int dropped) {
        MergeBranchResponse.Builder response = MergeBranchResponse.newBuilder()
                .setBranch(BranchGrpcService.branch(merged))
                .setDroppedOps(dropped);
        if (landed.last() > landed.before()) {
            response.setFirstParentSeq(landed.before() + 1).setLastParentSeq(landed.last());
        }
        return response.build();
    }

    /** How many ops of {@code changes} name a node the parent (at its head now) does not have and no earlier op creates. */
    private Uni<Integer> dropped(UUID parentId, List<SequencedChange> changes) {
        return reader.head(parentId).chain(head -> states.at(parentId, head)).map(engine -> {
            NodeStore store = engine.store();
            Set<OpId> created = new HashSet<>();
            int dropped = 0;
            for (SequencedChange change : changes) {
                for (TouchedNodes.Named op : TouchedNodes.ops(change.getChange())) {
                    if (op.op().hasCreate()) {
                        created.add(op.node());
                    } else if (op.node() != null && !created.contains(op.node()) && !store.exists(op.node())) {
                        dropped++;
                    }
                }
            }
            return dropped;
        });
    }

    /** Writes the replayed changes at the parent's next seqs under its row lock; checks the review first. */
    private Uni<Landed> replay(BranchRow branch, List<SequencedChange> changes, long reviewedParentSeq, Set<OpId> reviewed) {
        UUID parentId = branch.parentId();
        return pool.withTransaction(connection -> connection.preparedQuery(LOCK).execute(Tuple.of(parentId)).chain(rows -> {
            Row row = rows.iterator().next();
            long head = row.getLong(0);
            return stale(connection, parentId, reviewedParentSeq, reviewed, head)
                    .chain(() -> held(connection, parentId, changes))
                    .chain(() -> insert(connection, branch, changes, head, row.getLong(1), row.getLong(2)))
                    .replaceWith(new Landed(head, head + changes.size()));
        }));
    }

    /** MERGE_STALE when a parent change after the reviewed head names a reviewed node. */
    private static Uni<Void> stale(SqlConnection connection, UUID parentId, long reviewedParentSeq, Set<OpId> reviewed,
            long head) {
        if (reviewed.isEmpty()) {
            return Uni.createFrom().voidItem();
        }
        return connection.preparedQuery(SINCE).execute(Tuple.of(parentId, reviewedParentSeq)).invoke(rows -> {
            for (Row row : rows) {
                if (TouchedNodes.of(Protos.change(row.getBuffer(0).getBytes())).stream().anyMatch(reviewed::contains)) {
                    throw StatusExceptions.mergeStale(reviewedParentSeq, head);
                }
            }
        }).replaceWithVoid();
    }

    /** REPLICA_CONFLICT when the parent already holds one of the replayed (replica, seq)s. */
    private static Uni<Void> held(SqlConnection connection, UUID parentId, List<SequencedChange> changes) {
        Long[] replicas = changes.stream().map(c -> c.getChange().getReplica()).toArray(Long[]::new);
        Long[] seqs = changes.stream().map(c -> c.getChange().getSeq()).toArray(Long[]::new);
        return connection.preparedQuery(HELD).execute(Tuple.of(parentId, replicas, seqs)).invoke(rows -> {
            for (Row row : rows) {
                throw StatusExceptions.replicaConflict(row.getLong(0), row.getLong(1));
            }
        }).replaceWithVoid();
    }

    private static Uni<Void> insert(SqlConnection connection, BranchRow branch, List<SequencedChange> changes, long head,
            long collectSeq, long collectTimeMs) {
        if (changes.isEmpty()) {
            return Uni.createFrom().voidItem();
        }
        List<Tuple> rows = new ArrayList<>(changes.size());
        for (int i = 0; i < changes.size(); i++) {
            Change change = changes.get(i).getChange();
            byte[] bytes = change.toByteArray();
            rows.add(Tuple.from(new Object[] {branch.parentId(), head + 1 + i, change.getReplica(), change.getSeq(),
                    Buffer.buffer(bytes), bytes.length, collectSeq, collectTimeMs, branch.branchId()}));
        }
        return connection.preparedQuery(INSERT).executeBatch(rows)
                .chain(() -> ChangeIndex.write(connection, branch.parentId(), head + 1,
                        changes.stream().map(SequencedChange::getChange).toList()))
                .chain(() -> CommentIndex.mergeRecord(connection, branch.branchId(), branch.parentId(), head + 1))
                .chain(() -> connection.preparedQuery(HEAD).execute(Tuple.of(branch.parentId(), head + changes.size())))
                .replaceWithVoid();
    }

    /** Tells the parent's subscribers, each change with its author on the branch. */
    private Uni<Void> fanOut(BranchRow branch, List<SequencedChange> changes, long before) {
        List<SequencedChange> sequenced = new ArrayList<>(changes.size());
        for (int i = 0; i < changes.size(); i++) {
            sequenced.add(changes.get(i).toBuilder().clearAuthor().setServerSeq(before + 1 + i).build());
        }
        // One publish at a time, in the background: a merge of thousands must not flood the Valkey pool.
        return reader.withAuthors(branch.branchId(), sequenced).invoke(authored -> Multi.createFrom().iterable(authored)
                .onItem().transformToUniAndConcatenate(change -> bus.publish(branch.parentId(),
                        ServerFrame.newBuilder().setChange(change).build()))
                .collect().last()
                .subscribe().with(LOG::trace, LOG::warn)).replaceWithVoid();
    }

    /** Pushes the resolutions as the caller's changes, in order; the landing then ends at the last one. */
    private Uni<Landed> resolve(ChangeIngest.Pusher pusher, UUID parentId, List<Change> resolutions, Landed landed) {
        return Multi.createFrom().iterable(resolutions)
                .onItem().transformToUniAndConcatenate(change -> ingest.accept(pusher, parentId, change))
                .collect().asList()
                .map(seqs -> seqs.isEmpty() ? landed : new Landed(landed.last() == landed.before()
                        ? seqs.get(0) - 1 : landed.before(), seqs.get(seqs.size() - 1)));
    }
}
