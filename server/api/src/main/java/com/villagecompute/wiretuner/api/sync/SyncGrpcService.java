package com.villagecompute.wiretuner.api.sync;

import java.time.Duration;
import java.util.HexFormat;
import java.util.List;
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
import com.villagecompute.wiretuner.api.history.Snapshotter;
import com.villagecompute.wiretuner.api.observability.RateLimiter;
import com.villagecompute.wiretuner.api.observability.WtMetrics;
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
import io.smallrye.mutiny.subscription.Cancellable;
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
                   r.account_id, r.device_id, r.last_seq, r.retired_at IS NOT NULL,
                   (SELECT b.parent_document_id FROM branch b WHERE b.document_id = d.id)
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
            WHERE id = $1 RETURNING stable_seq, head_seq, collect_seq, collect_time_ms
            """;

    /**
     * D-067: the replica confirmed receiving the last publication by acking again, so that becomes
     * its horizon (the one its next changes are recorded with), and this answer is the new
     * publication: the stable point with the server's clock.
     */
    static final String PUBLISHED = """
            UPDATE replica SET horizon_seq = published_seq, horizon_ms = published_ms,
                               published_seq = $3, published_ms = $4
            WHERE document_id = $1 AND replica_id = $2
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

    @Inject
    Colors colors;

    @Inject
    RateLimiter limits;

    @Inject
    WtMetrics metrics;

    @Inject
    LiveSessions sessions;

    @Inject
    Snapshotter snapshotter;

    // ------------------------------------------------------------------------------------ Subscribe

    /**
     * Where a new subscription stands: the caller, and the document and replica as read after listening;
     * {@code root} is the document's presence family (its parent when it is a branch, else itself).
     */
    record Standing(Principal principal, Role role, Participant participant, long head, int featureLevel,
            long snapshotSeq, long lastAccepted, int color, UUID documentId, UUID root, long replica) {

        /** Whether the subscription is on a branch, whose presence is its parent's. */
        boolean onBranch() {
            return !root.equals(documentId);
        }
    }

    /** A subscription registered on the bus, where it stands, and its presence relay from the parent (branches only). */
    record Opened(LiveFeed feed, PresenceRelay relay, Standing standing) {
    }

    /**
     * A branch subscription's listener on its parent's channel: it passes on the presence updates of the
     * family (a branch's presence lives with its parent's, {@link PresenceStore}) and nothing else. A
     * lost presence frame costs nothing, so there is nothing to resynchronise.
     */
    record PresenceRelay(LiveFeed feed) implements SyncBus.Listener {
        @Override
        public void frame(ServerFrame frame) {
            if (frame.hasPresenceUpdate()) {
                feed.frame(frame);
            }
        }

        @Override
        public UUID account() {
            return null;
        }

        @Override
        public void resync() {
            // Presence is current state: the next update replaces whatever was lost.
        }
    }

    /** An authorised caller and how collaborators see them. */
    record Caller(RoleGuard.Grant grant, Participant participant) {
    }

    @Override
    public Multi<ServerFrame> subscribe(SubscribeRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        long replica = request.getReplica();
        return caller(documentId, Role.VIEWER)
                .chain(caller -> {
                    LiveFeed feed = new LiveFeed(documentId, caller.grant().principal().accountId(), reader, gapWait);
                    return bus.listen(documentId, feed)
                            .chain(() -> standing(documentId, replica, caller.grant(), caller.participant()))
                            .chain(standing -> relay(standing, feed).map(relay -> new Opened(feed, relay, standing)))
                            .onFailure().invoke(() -> bus.unlisten(documentId, feed));
                })
                .onItem().transformToMulti(opened -> frames(request, documentId, opened));
    }

    /** On a branch, the feed's presence relay from the parent's channel, registered; null on a document with no parent. */
    private Uni<PresenceRelay> relay(Standing standing, LiveFeed feed) {
        if (!standing.onBranch()) {
            return Uni.createFrom().nullItem();
        }
        PresenceRelay relay = new PresenceRelay(feed);
        return bus.listen(standing.root(), relay).replaceWith(relay);
    }

    /** The caller, checked for {@code minimum} on the document, with their participant. */
    private Uni<Caller> caller(UUID documentId, Role minimum) {
        return Panache.withTransaction(() -> guard.require(documentId, minimum)
                .chain(grant -> participants.of(grant.principal().accountId()).map(participant -> new Caller(grant, participant))));
    }

    private Uni<Standing> standing(UUID documentId, long replica, RoleGuard.Grant grant, Participant participant) {
        return pool.preparedQuery(STANDING).execute(Tuple.of(documentId, replica)).chain(rows -> {
            Row row = rows.iterator().next();
            UUID boundAccount = row.getUUID(3);
            ReplicaBinding binding = boundAccount == null ? null
                    : new ReplicaBinding(boundAccount, row.getUUID(4), row.getLong(5), row.getBoolean(6));
            ReplicaBinding.check(binding, grant.principal(), replica);
            UUID parent = row.getUUID(7);
            UUID root = parent == null ? documentId : parent;
            return colors.of(root, grant.principal().accountId()).map(color -> new Standing(grant.principal(),
                    grant.role(), participant, row.getLong(0), row.getInteger(1), row.getLong(2),
                    binding == null ? 0 : binding.lastSeq(), color, documentId, root, replica));
        });
    }

    private Multi<ServerFrame> frames(SubscribeRequest request, UUID documentId, Opened opened) {
        LiveFeed feed = opened.feed();
        Standing standing = opened.standing();
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
        PresenceUpdate self = presenceOf(standing);
        Uni<Void> joined = request.hasPresence()
                ? presence.update(standing.root(), documentId, replica, filled(request.getPresence(), self))
                : Uni.createFrom().voidItem();
        Uni<ServerFrame> present = joined.chain(() -> presence.snapshot(standing.root()))
                .map(snapshot -> ServerFrame.newBuilder().setPresence(snapshot).build());
        long first = standing.head() + 1;
        AtomicLong lastSent = new AtomicLong(System.nanoTime());
        // Heartbeats go through the feed, so the end of the feed (an AccessRemoved) ends the stream.
        Multi<ServerFrame> live = Multi.createFrom().emitter(emitter -> {
            feed.start(first, emitter);
            Cancellable ticks = Multi.createFrom().ticks().every(pongAfter.dividedBy(3))
                    .onOverflow().drop()
                    .select().where(tick -> System.nanoTime() - lastSent.get() >= pongAfter.toNanos())
                    .subscribe().with(tick -> feed.heartbeat(ServerFrame.newBuilder()
                            .setPong(Pong.newBuilder().setServerTimeMs(System.currentTimeMillis())).build()));
            emitter.onTermination(ticks::cancel);
        }, liveBuffer);
        PresenceUpdate gone = self.toBuilder().setState(PresenceState.PRESENCE_STATE_GONE).build();
        metrics.subscribed(documentId);
        UUID account = standing.principal().accountId();
        sessions.open(documentId, account);
        return Multi.createBy().concatenating().streams(Multi.createFrom().item(ServerFrame.newBuilder().setWelcome(welcome).build()),
                        replay, present.toMulti(), live)
                .invoke(frame -> lastSent.set(System.nanoTime()))
                .onTermination().invoke(() -> {
                    metrics.unsubscribed(documentId);
                    sessions.close(documentId, account);
                    bus.unlisten(documentId, feed);
                    if (opened.relay() != null) {
                        bus.unlisten(standing.root(), opened.relay());
                    }
                    if (!bus.documents().contains(documentId)) {
                        snapshotter.closed(documentId).subscribe().with(ignored -> { }, failure -> { });
                    }
                    presence.leave(standing.root(), documentId, replica, gone).subscribe().with(ignored -> { }, failure -> { });
                });
    }

    /**
     * The server-filled part of the caller's presence on the document: who, with role, their color (one
     * per person in the document and its branches), the branch the session is on, and the session (its
     * replica) (COLLAB-004, COLLAB-005).
     */
    static PresenceUpdate presenceOf(Standing standing) {
        return PresenceUpdate.newBuilder()
                .setUser(standing.participant().toBuilder().setRole(DocumentMessages.role(standing.role())))
                .setColorIndex(standing.color())
                .setBranchId(standing.onBranch() ? standing.documentId().toString() : "")
                .setSession(standing.replica())
                .build();
    }

    /** The client's presence with the server-filled fields replaced, whatever the client sent in them. */
    static PresenceUpdate filled(PresenceUpdate sent, PresenceUpdate self) {
        return sent.toBuilder().setUser(self.getUser()).setColorIndex(self.getColorIndex()).setBranchId(self.getBranchId())
                .setSession(self.getSession()).build();
    }

    // ---------------------------------------------------------------------------------------- Pushes

    @Override
    public Uni<PushChangeResponse> pushChange(PushChangeRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        Change change = request.getChange();
        Uni<Pusher> pusher = allowed(pusher(documentId), documentId, 1);
        return queue.submit(documentId, change.getReplica(), () -> pusher.chain(p -> ingest.accept(p, documentId, change)))
                .map(serverSeq -> PushChangeResponse.newBuilder().setServerSeq(serverSeq).build());
    }

    @Override
    public Uni<PushChangeBatchResponse> pushChangeBatch(PushChangeBatchRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        List<Change> changes = request.getChangesList();
        Uni<Pusher> pusher = allowed(pusher(documentId), documentId, changes.size());
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
        long bytes;
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
                                .onFailure().recoverWithItem(0L)
                                .invoke(() -> metrics.backlog(bulk.documentId, bulk.bytes)))
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
        bulk.bytes += frame.getSerializedSize();
        Uni<Pusher> allowed = allowed(bulk.pusher, documentId, changes.size());
        return queue.submit(documentId, head.getReplica(), () -> acceptAll(allowed, documentId, changes, 0, seq -> { }))
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
     * The caller as a pusher on the document (commenter or above; what a commenter may push is
     * {@link com.villagecompute.wiretuner.api.comments.CommentRules}), resolved at once and remembered:
     * the call's place in the replica's queue is taken before this completes.
     */
    private Uni<Pusher> pusher(UUID documentId) {
        Uni<Pusher> pusher = grants.pusher(documentId, () -> caller(documentId, Role.COMMENTER)
                        .map(caller -> new Pusher(caller.grant().principal(), caller.participant(), caller.grant().role())))
                .memoize().indefinitely();
        pusher.subscribe().with(ignored -> { }, failure -> { });
        return pusher;
    }

    /**
     * The pusher once the account's and the document's rate limits have given {@code cost} changes,
     * checked at once, concurrently with the call's wait in its replica's queue.
     */
    private Uni<Pusher> allowed(Uni<Pusher> pusher, UUID documentId, int cost) {
        Uni<Pusher> allowed = pusher.call(p -> limits.check(p.principal().accountId(), documentId, cost))
                .memoize().indefinitely();
        allowed.subscribe().with(ignored -> { }, failure -> { });
        return allowed;
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
        // Up to 20 calls a second per replica: who the caller is on the document is remembered for the
        // grant TTL (2 s), like a pusher.
        return grants.<Standing>memo(documentId, "presence:" + Long.toUnsignedString(replica),
                        () -> caller(documentId, Role.VIEWER)
                                .chain(caller -> standing(documentId, replica, caller.grant(), caller.participant())))
                .chain(standing -> presence.update(standing.root(), documentId, replica,
                        filled(request.getPresence(), presenceOf(standing))))
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
                .map(rows -> {
                    Row row = rows.iterator().next();
                    metrics.stableLag(documentId, row.getLong(1), row.getLong(0));
                    return AckResponse.newBuilder().setStableSeq(row.getLong(0)).setCollectSeq(row.getLong(2))
                            .setCollectTimeMs(row.getLong(3)).build();
                })
                .call(response -> pool.preparedQuery(PUBLISHED).execute(Tuple.of(documentId, replica,
                        response.getStableSeq(), System.currentTimeMillis())));
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
                .setUncompressedSize(snapshot.uncompressedSize)
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
