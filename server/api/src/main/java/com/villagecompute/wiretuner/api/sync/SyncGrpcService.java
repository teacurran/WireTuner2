package com.villagecompute.wiretuner.api.sync;

import java.time.Duration;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongConsumer;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.blob.BlobGrpcService.Rechunker;
import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Snapshot;
import com.villagecompute.wiretuner.api.persistence.SnapshotRepository;
import com.villagecompute.wiretuner.api.sync.ChangeIngest.Pusher;
import com.villagecompute.wiretuner.crdt.schema.MergeTable;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.SnapshotCompression;
import com.villagecompute.wiretuner.doc.v1.SnapshotFrame;
import com.villagecompute.wiretuner.doc.v1.SnapshotHeader;
import com.villagecompute.wiretuner.sync.v1.AckRequest;
import com.villagecompute.wiretuner.sync.v1.AckResponse;
import com.villagecompute.wiretuner.sync.v1.ChangeRejected;
import com.villagecompute.wiretuner.sync.v1.FetchChangesRequest;
import com.villagecompute.wiretuner.sync.v1.FetchChangesResponse;
import com.villagecompute.wiretuner.sync.v1.FetchSnapshotRequest;
import com.villagecompute.wiretuner.sync.v1.FetchSnapshotResponse;
import com.villagecompute.wiretuner.sync.v1.MutinySyncServiceGrpc;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.Pong;
import com.villagecompute.wiretuner.sync.v1.PresenceState;
import com.villagecompute.wiretuner.sync.v1.PresenceUpdate;
import com.villagecompute.wiretuner.sync.v1.PushChangeBatchRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeBatchResponse;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeResponse;
import com.villagecompute.wiretuner.sync.v1.PushChangesRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangesResponse;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;
import com.villagecompute.wiretuner.sync.v1.SubscribeRequest;
import com.villagecompute.wiretuner.sync.v1.UpdatePresenceRequest;
import com.villagecompute.wiretuner.sync.v1.UpdatePresenceResponse;
import com.villagecompute.wiretuner.sync.v1.Welcome;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.sync.v1.SyncService} (SRV-004..006; docs/spec/sync-protocol.adoc). Any role may
 * subscribe, fetch, ack and send presence; pushing needs editor or owner. Pushes of one replica go
 * through the {@link ReplicaQueue} in arrival order, with the caller's authorisation resolved
 * concurrently as soon as the call arrives, so a window of pipelined pushes costs one authorisation
 * latency, not one per push.
 */
@GrpcService
public class SyncGrpcService extends MutinySyncServiceGrpc.SyncServiceImplBase {

    /** A snapshot is streamed in chunks of at most this many bytes. */
    static final int SNAPSHOT_CHUNK = 1024 * 1024;

    static final String STANDING = """
            SELECT d.head_seq, d.feature_level,
                   (SELECT COALESCE(max(s.server_seq), 0) FROM snapshot s WHERE s.document_id = d.id),
                   r.account_id, r.device_id, r.last_seq, r.retired_at IS NOT NULL
            FROM document d LEFT JOIN replica r ON r.document_id = d.id AND r.replica_id = $2
            WHERE d.id = $1
            """;

    static final String ACK = """
            INSERT INTO replica AS t (document_id, replica_id, account_id, device_id, last_ack_seq)
            VALUES ($1, $2, $3, $4, LEAST($5, (SELECT head_seq FROM document WHERE id = $1)))
            ON CONFLICT (document_id, replica_id) DO UPDATE
                SET last_ack_seq = GREATEST(t.last_ack_seq, EXCLUDED.last_ack_seq), last_seen_at = now()
            """;

    static final String STABLE = """
            UPDATE document SET stable_seq = GREATEST(stable_seq,
                (SELECT COALESCE(min(last_ack_seq), 0) FROM replica WHERE document_id = $1 AND retired_at IS NULL))
            WHERE id = $1 RETURNING stable_seq
            """;

    static final String LAST_ACCEPTED = """
            SELECT COALESCE(max(last_seq), 0) FROM replica WHERE document_id = $1 AND replica_id = $2 AND account_id = $3
            """;

    /** The serialized merge table every Welcome carries (docs/spec/crdt-model.adoc, Schema evolution). */
    static final ByteString MERGE_TABLE = ByteString.copyFrom(MergeTable.json());

    @ConfigProperty(name = "wt.sync.pong-after", defaultValue = "15S")
    Duration pongAfter;

    @ConfigProperty(name = "wt.sync.gap-wait", defaultValue = "200MS")
    Duration gapWait;

    @ConfigProperty(name = "wt.sync.live-buffer", defaultValue = "4096")
    int liveBuffer;

    @Inject
    RoleGuard guard;

    @Inject
    Participants participants;

    @Inject
    ReplicaQueue queue;

    @Inject
    PushGrants grants;

    @Inject
    ChangeIngest ingest;

    @Inject
    ChangeReader reader;

    @Inject
    SyncBus bus;

    @Inject
    PresenceStore presence;

    @Inject
    SnapshotRepository snapshots;

    @Inject
    BlobStore store;

    @Inject
    Pool pool;

    // ------------------------------------------------------------------------------------ Subscribe

    /** Where a new subscription stands: the caller, and the document and replica as read after listening. */
    record Standing(Principal principal, Role role, Participant participant, long head, int featureLevel,
            long snapshotSeq, long lastAccepted) {
    }

    /** An authorised caller and how collaborators see them. */
    record Caller(RoleGuard.Grant grant, Participant participant) {
    }

    @Override
    public Multi<ServerFrame> subscribe(SubscribeRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        long replica = request.getReplica();
        LiveFeed feed = new LiveFeed(documentId, reader, gapWait);
        return caller(documentId, Role.VIEWER)
                .chain(caller -> bus.listen(documentId, feed)
                        .chain(() -> standing(documentId, replica, caller.grant(), caller.participant())))
                .onFailure().invoke(() -> bus.unlisten(documentId, feed))
                .onItem().transformToMulti(standing -> frames(request, documentId, feed, standing));
    }

    /** The caller, checked for {@code minimum} on the document, with their participant. */
    private Uni<Caller> caller(UUID documentId, Role minimum) {
        return Panache.withTransaction(() -> guard.require(documentId, minimum)
                .chain(grant -> participants.of(grant.principal().accountId()).map(participant -> new Caller(grant, participant))));
    }

    private Uni<Standing> standing(UUID documentId, long replica, RoleGuard.Grant grant, Participant participant) {
        return pool.preparedQuery(STANDING).execute(Tuple.of(documentId, replica)).map(rows -> {
            Row row = rows.iterator().next();
            UUID boundAccount = row.getUUID(3);
            ReplicaBinding binding = boundAccount == null ? null
                    : new ReplicaBinding(boundAccount, row.getUUID(4), row.getLong(5), row.getBoolean(6));
            ReplicaBinding.check(binding, grant.principal(), replica);
            return new Standing(grant.principal(), grant.role(), participant, row.getLong(0), row.getInteger(1),
                    row.getLong(2), binding == null ? 0 : binding.lastSeq());
        });
    }

    private Multi<ServerFrame> frames(SubscribeRequest request, UUID documentId, LiveFeed feed, Standing standing) {
        long after = request.getAfterServerSeq();
        long replica = request.getReplica();
        boolean hint = after < standing.snapshotSeq();
        Welcome welcome = Welcome.newBuilder()
                .setRole(DocumentMessages.role(standing.role()))
                .setMergeTable(MERGE_TABLE)
                .setHeadSeq(standing.head())
                .setLastAcceptedSeq(standing.lastAccepted())
                .setSnapshotHint(hint)
                .setFeatureLevel(standing.featureLevel())
                .build();
        Multi<ServerFrame> replay = hint ? Multi.createFrom().empty()
                : reader.range(documentId, after, standing.head()).map(change -> ServerFrame.newBuilder().setChange(change).build());
        PresenceUpdate self = presenceOf(documentId, standing);
        Uni<Void> joined = request.hasPresence()
                ? presence.update(documentId, replica, filled(request.getPresence(), self))
                : Uni.createFrom().voidItem();
        Uni<ServerFrame> present = joined.chain(() -> presence.snapshot(documentId))
                .map(snapshot -> ServerFrame.newBuilder().setPresence(snapshot).build());
        long first = standing.head() + 1;
        AtomicLong lastSent = new AtomicLong(System.nanoTime());
        Multi<ServerFrame> live = Multi.createFrom().emitter(emitter -> feed.start(first, emitter), liveBuffer);
        Multi<ServerFrame> pongs = Multi.createFrom().ticks().every(pongAfter.dividedBy(3))
                .onOverflow().drop()
                .select().where(tick -> System.nanoTime() - lastSent.get() >= pongAfter.toNanos())
                .map(tick -> ServerFrame.newBuilder()
                        .setPong(Pong.newBuilder().setServerTimeMs(System.currentTimeMillis())).build());
        PresenceUpdate gone = self.toBuilder().setState(PresenceState.PRESENCE_STATE_GONE).build();
        return Multi.createBy().concatenating().streams(Multi.createFrom().item(ServerFrame.newBuilder().setWelcome(welcome).build()),
                        replay, present.toMulti(), Multi.createBy().merging().streams(live, pongs))
                .invoke(frame -> lastSent.set(System.nanoTime()))
                .onTermination().invoke(() -> {
                    bus.unlisten(documentId, feed);
                    presence.leave(documentId, replica, gone).subscribe().with(ignored -> { }, failure -> { });
                });
    }

    /** The server-filled part of the caller's presence on the document. */
    static PresenceUpdate presenceOf(UUID documentId, Standing standing) {
        return PresenceUpdate.newBuilder()
                .setUser(standing.participant().toBuilder().setRole(DocumentMessages.role(standing.role())))
                .setColorIndex(Math.floorMod(Objects.hash(documentId, standing.principal().accountId()), 12))
                .build();
    }

    /** The client's presence with the server-filled fields replaced. */
    static PresenceUpdate filled(PresenceUpdate sent, PresenceUpdate self) {
        return sent.toBuilder().setUser(self.getUser()).setColorIndex(self.getColorIndex()).clearBranchId().build();
    }

    // ---------------------------------------------------------------------------------------- Pushes

    @Override
    public Uni<PushChangeResponse> pushChange(PushChangeRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        Change change = request.getChange();
        Uni<Pusher> pusher = pusher(documentId);
        return queue.submit(documentId, change.getReplica(), () -> pusher.chain(p -> ingest.accept(p, documentId, change)))
                .map(serverSeq -> PushChangeResponse.newBuilder().setServerSeq(serverSeq).build());
    }

    @Override
    public Uni<PushChangeBatchResponse> pushChangeBatch(PushChangeBatchRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        List<Change> changes = request.getChangesList();
        Uni<Pusher> pusher = pusher(documentId);
        PushChangeBatchResponse.Builder response = PushChangeBatchResponse.newBuilder();
        return queue.submit(documentId, changes.get(0).getReplica(),
                        () -> acceptAll(pusher, documentId, changes, 0, response::addServerSeqs))
                .map(rejected -> rejected == null ? response.build() : response.setRejected(rejected).build());
    }

    /** One bulk upload's progress across frames. */
    static final class Bulk {
        UUID documentId;
        Uni<Pusher> pusher;
        long replica;
        ChangeRejected rejected;
    }

    @Override
    public Uni<PushChangesResponse> pushChanges(Multi<PushChangesRequest> frames) {
        Bulk bulk = new Bulk();
        return frames.onItem().transformToUniAndConcatenate(frame -> bulkFrame(bulk, frame))
                .select().first(Boolean::booleanValue)
                .collect().last()
                .chain(() -> bulk.documentId == null ? Uni.createFrom().item(0L)
                        : bulk.pusher.chain(p -> lastAccepted(bulk.documentId, bulk.replica, p.principal()))
                                .onFailure().recoverWithItem(0L))
                .map(last -> {
                    PushChangesResponse.Builder response = PushChangesResponse.newBuilder().setLastAcceptedSeq(last);
                    return bulk.rejected == null ? response.build() : response.setRejected(bulk.rejected).build();
                });
    }

    /** Ingests one frame; false once a change was rejected (the upload stops there). */
    private Uni<Boolean> bulkFrame(Bulk bulk, PushChangesRequest frame) {
        UUID documentId = UUID.fromString(frame.getDocumentId());
        List<Change> changes = frame.getChangesList();
        Change head = changes.get(0);
        if (bulk.documentId == null) {
            bulk.documentId = documentId;
            bulk.replica = head.getReplica();
            bulk.pusher = pusher(documentId);
        }
        if (!bulk.documentId.equals(documentId)) {
            return stop(bulk, head, "every frame of an upload must name the same document");
        }
        if (changes.size() > 1 && frame.getSerializedSize() > ChangeRules.MAX_FRAME_BYTES) {
            return stop(bulk, head, "a frame holding more than one change is at most " + ChangeRules.MAX_FRAME_BYTES + " bytes");
        }
        return queue.submit(documentId, head.getReplica(), () -> acceptAll(bulk.pusher, documentId, changes, 0, seq -> { }))
                .map(rejected -> {
                    bulk.rejected = rejected;
                    return rejected == null;
                });
    }

    private static Uni<Boolean> stop(Bulk bulk, Change change, String why) {
        bulk.rejected = Protos.rejected(change, StatusExceptions.validationFailed(why, java.util.Map.of("changes", why))).orElseThrow();
        return Uni.createFrom().item(false);
    }

    /**
     * Accepts {@code changes} from {@code from} in order until one is rejected; each accepted
     * server_seq (an identical retry's original one included) goes to {@code accepted}. The result
     * is the first rejection, or null. A failure without a WireTuner reason fails the call.
     */
    private Uni<ChangeRejected> acceptAll(Uni<Pusher> pusher, UUID documentId, List<Change> changes, int from,
            LongConsumer accepted) {
        if (from == changes.size()) {
            return Uni.createFrom().nullItem();
        }
        Change change = changes.get(from);
        return pusher.chain(p -> ingest.accept(p, documentId, change))
                .map(serverSeq -> {
                    accepted.accept(serverSeq);
                    return (ChangeRejected) null;
                })
                .onFailure().recoverWithUni(failure -> Protos.rejected(change, failure)
                        .map(rejected -> Uni.createFrom().item(rejected))
                        .orElseGet(() -> Uni.createFrom().failure(failure)))
                .chain(rejected -> rejected != null ? Uni.createFrom().item(rejected)
                        : acceptAll(pusher, documentId, changes, from + 1, accepted));
    }

    /**
     * The caller as a pusher on the document (editor or above), resolved at once and remembered:
     * the call's place in the replica's queue is taken before this completes.
     */
    private Uni<Pusher> pusher(UUID documentId) {
        Uni<Pusher> pusher = grants.pusher(documentId, () -> caller(documentId, Role.EDITOR)
                        .map(caller -> new Pusher(caller.grant().principal(), caller.participant())))
                .memoize().indefinitely();
        pusher.subscribe().with(ignored -> { }, failure -> { });
        return pusher;
    }

    private Uni<Long> lastAccepted(UUID documentId, long replica, Principal principal) {
        return pool.preparedQuery(LAST_ACCEPTED).execute(Tuple.of(documentId, replica, principal.accountId()))
                .map(rows -> rows.iterator().next().getLong(0));
    }

    // ------------------------------------------------------------------------------- Presence, Ack

    @Override
    public Uni<UpdatePresenceResponse> updatePresence(UpdatePresenceRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        long replica = request.getReplica();
        return caller(documentId, Role.VIEWER)
                .chain(caller -> standing(documentId, replica, caller.grant(), caller.participant()))
                .chain(standing -> presence.update(documentId, replica,
                        filled(request.getPresence(), presenceOf(documentId, standing))))
                .replaceWith(UpdatePresenceResponse.getDefaultInstance());
    }

    @Override
    public Uni<AckResponse> ack(AckRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        long replica = request.getReplica();
        return Panache.withTransaction(() -> guard.require(documentId, Role.VIEWER))
                .chain(grant -> standing(documentId, replica, grant, Participant.getDefaultInstance()))
                .chain(standing -> pool.preparedQuery(ACK).execute(Tuple.from(new Object[] {documentId, replica,
                        standing.principal().accountId(), ReplicaBinding.device(standing.principal()),
                        request.getAppliedServerSeq()})))
                .chain(() -> pool.preparedQuery(STABLE).execute(Tuple.of(documentId)))
                .map(rows -> AckResponse.newBuilder().setStableSeq(rows.iterator().next().getLong(0)).build());
    }

    // --------------------------------------------------------------------------------------- Catch-up

    @Override
    public Multi<FetchChangesResponse> fetchChanges(FetchChangesRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        long after = request.getAfterServerSeq();
        long requested = request.getUntilServerSeq();
        return Panache.withTransaction(() -> guard.require(documentId, Role.VIEWER))
                .chain(() -> reader.head(documentId))
                .onItem().transformToMulti(head -> {
                    long until = Math.min(requested == 0 ? head : requested, head);
                    FramePacker packer = new FramePacker(head);
                    return reader.range(documentId, after, until)
                            .onItem().transformToIterable(packer::add)
                            .onCompletion().switchTo(() -> Multi.createFrom().iterable(packer.flush()));
                });
    }

    @Override
    public Multi<FetchSnapshotResponse> fetchSnapshot(FetchSnapshotRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        long at = request.getAtOrBeforeServerSeq();
        return Panache.withTransaction(() -> guard.require(documentId, Role.VIEWER)
                        .chain(() -> snapshots.findAtOrBefore(documentId, at == 0 ? Long.MAX_VALUE : at)))
                .onItem().ifNull().failWith(() -> StatusExceptions.snapshotUnavailable(at))
                .onItem().transformToMulti(this::snapshotFrames);
    }

    private Multi<FetchSnapshotResponse> snapshotFrames(Snapshot snapshot) {
        SnapshotHeader header = SnapshotHeader.newBuilder()
                .setServerSeq(snapshot.id.serverSeq())
                .setStateHash(ByteString.copyFrom(HexFormat.of().parseHex(snapshot.stateHash)))
                .setCompression(SnapshotCompression.SNAPSHOT_COMPRESSION_ZSTD)
                .setCompressedSize(snapshot.sizeBytes)
                .setChunkCount((int) ((snapshot.sizeBytes + SNAPSHOT_CHUNK - 1) / SNAPSHOT_CHUNK))
                .setNodeCount(snapshot.nodeCount)
                .build();
        Rechunker rechunker = new Rechunker(SNAPSHOT_CHUNK);
        Multi<SnapshotFrame> chunks = store.get(snapshot.objectKey)
                .onItem().transformToIterable(rechunker::add)
                .onCompletion().switchTo(() -> Multi.createFrom().iterable(rechunker.flush()))
                .map(chunk -> SnapshotFrame.newBuilder().setChunk(chunk).build());
        return Multi.createBy().concatenating()
                .streams(Multi.createFrom().item(SnapshotFrame.newBuilder().setHeader(header).build()), chunks)
                .map(frame -> FetchSnapshotResponse.newBuilder().setFrame(frame).build());
    }
}
