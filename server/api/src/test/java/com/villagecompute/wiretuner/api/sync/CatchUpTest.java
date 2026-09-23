package com.villagecompute.wiretuner.api.sync;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.HexFormat;
import java.util.Iterator;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.SnapshotCompression;
import com.villagecompute.wiretuner.doc.v1.SnapshotHeader;
import com.villagecompute.wiretuner.sync.v1.ErrorReason;
import com.villagecompute.wiretuner.sync.v1.FetchChangesRequest;
import com.villagecompute.wiretuner.sync.v1.FetchChangesResponse;
import com.villagecompute.wiretuner.sync.v1.FetchSnapshotRequest;
import com.villagecompute.wiretuner.sync.v1.FetchSnapshotResponse;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangesRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangesResponse;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.SubscribeRequest;

import io.grpc.Status;
import io.grpc.stub.ClientCallStreamObserver;
import io.grpc.stub.ClientResponseObserver;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/** SRV-006: catch-up downloads, snapshots, and bulk upload with resumption. */
@QuarkusTest
class CatchUpTest extends SyncTestSupport {

    @Inject
    BlobStore store;

    void push(UUID doc, Change change) {
        blocking(ALICE, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString()).setChange(change).build());
    }

    List<FetchChangesResponse> fetch(String user, UUID doc, long after, long until) {
        List<FetchChangesResponse> frames = new ArrayList<>();
        blocking(user, null).fetchChanges(FetchChangesRequest.newBuilder().setDocumentId(doc.toString())
                .setAfterServerSeq(after).setUntilServerSeq(until).build()).forEachRemaining(frames::add);
        return frames;
    }

    static List<Long> seqs(List<FetchChangesResponse> frames) {
        return frames.stream().flatMap(f -> f.getChangesList().stream()).map(SequencedChange::getServerSeq).toList();
    }

    // ------------------------------------------------------------------------------ FetchChanges

    @Test
    void fetchChangesStreamsARangeInFrames() {
        UUID doc = document(ALICE);
        share(doc, bob, "viewer");
        long replica = replicaId();
        for (int seq = 1; seq <= 300; seq++) {
            push(doc, change(replica, seq));
        }
        List<FetchChangesResponse> all = fetch(BOB, doc, 0, 0);
        assertThat(all).extracting(FetchChangesResponse::getChangesCount).containsExactly(256, 44);
        assertThat(all).extracting(FetchChangesResponse::getHeadSeq).containsOnly(300L);
        assertThat(seqs(all)).hasSize(300).startsWith(1L).endsWith(300L);
        assertThat(all.get(0).getChanges(0).getChange()).isEqualTo(change(replica, 1));

        assertThat(seqs(fetch(BOB, doc, 10, 12))).containsExactly(11L, 12L);
        assertThat(seqs(fetch(BOB, doc, 298, 999))).containsExactly(299L, 300L);
        assertThat(fetch(BOB, doc, 300, 0)).isEmpty();
        assertFails(() -> fetch(DAVE, doc, 0, 0), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
    }

    @Test
    void fetchChangesPacksLargeChangesByBytes() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        for (int seq = 1; seq <= 4; seq++) {
            push(doc, sized(replica, seq, 400 * 1024));
        }
        assertThat(fetch(ALICE, doc, 0, 0)).extracting(FetchChangesResponse::getChangesCount).containsExactly(2, 2);
    }

    @Test
    void aCompactedRangeIsHistoryUnavailable() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        for (int seq = 1; seq <= 6; seq++) {
            push(doc, change(replica, seq));
        }
        exec("DELETE FROM change_log WHERE document_id = ? AND server_seq <= 2", doc);
        assertFails(() -> fetch(ALICE, doc, 0, 0), Status.Code.FAILED_PRECONDITION, ErrorReasons.HISTORY_UNAVAILABLE);
        assertThat(seqs(fetch(ALICE, doc, 2, 0))).containsExactly(3L, 4L, 5L, 6L);
        exec("DELETE FROM change_log WHERE document_id = ? AND server_seq = 5", doc);
        assertFails(() -> fetch(ALICE, doc, 2, 0), Status.Code.FAILED_PRECONDITION, ErrorReasons.HISTORY_UNAVAILABLE);
    }

    // ----------------------------------------------------------------------------- FetchSnapshot

    @Test
    void fetchSnapshotStreamsTheHeaderThenChunks() {
        UUID doc = document(ALICE);
        byte[] object = new byte[2 * 1024 * 1024 + 123];
        for (int i = 0; i < object.length; i++) {
            object[i] = (byte) (i * 31);
        }
        String key = "snapshots/" + doc + "/7";
        store.put(key, object, "application/zstd").await().indefinitely();
        String hash = "ab".repeat(32);
        exec("INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, node_count)"
                + " VALUES (?, 7, ?, ?, ?, 42)", doc, key, hash, object.length);
        exec("INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, node_count)"
                + " VALUES (?, 9, 'missing', ?, 1, 1)", doc, hash);

        List<FetchSnapshotResponse> frames = new ArrayList<>();
        blocking(ALICE, null).fetchSnapshot(FetchSnapshotRequest.newBuilder().setDocumentId(doc.toString())
                .setAtOrBeforeServerSeq(8).build()).forEachRemaining(frames::add);
        SnapshotHeader header = frames.get(0).getFrame().getHeader();
        assertThat(header.getServerSeq()).isEqualTo(7);
        assertThat(header.getStateHash().toByteArray()).isEqualTo(HexFormat.of().parseHex(hash));
        assertThat(header.getCompression()).isEqualTo(SnapshotCompression.SNAPSHOT_COMPRESSION_ZSTD);
        assertThat(header.getCompressedSize()).isEqualTo(object.length);
        assertThat(header.getChunkCount()).isEqualTo(3);
        assertThat(header.getNodeCount()).isEqualTo(42);
        List<ByteString> chunks = frames.subList(1, frames.size()).stream().map(f -> f.getFrame().getChunk()).toList();
        assertThat(chunks).extracting(ByteString::size).containsExactly(1024 * 1024, 1024 * 1024, 123);
        assertThat(ByteString.copyFrom(chunks).toByteArray()).isEqualTo(object);

        assertFails(() -> blocking(ALICE, null).fetchSnapshot(FetchSnapshotRequest.newBuilder()
                        .setDocumentId(doc.toString()).setAtOrBeforeServerSeq(6).build()).forEachRemaining(f -> { }),
                Status.Code.FAILED_PRECONDITION, ErrorReasons.HISTORY_UNAVAILABLE);
        Iterator<FetchSnapshotResponse> newest = blocking(ALICE, null).fetchSnapshot(FetchSnapshotRequest.newBuilder()
                .setDocumentId(doc.toString()).build());
        assertThat(newest.next().getFrame().getHeader().getServerSeq()).isEqualTo(9);
    }

    // ------------------------------------------------------------------------------ PushChanges

    /** A client stream of PushChanges; {@link #cancel} drops it mid-upload. */
    static final class Upload implements ClientResponseObserver<PushChangesRequest, PushChangesResponse> {
        final CompletableFuture<PushChangesResponse> response = new CompletableFuture<>();
        ClientCallStreamObserver<PushChangesRequest> call;

        @Override
        public void beforeStart(ClientCallStreamObserver<PushChangesRequest> requestStream) {
            call = requestStream;
        }

        @Override
        public void onNext(PushChangesResponse value) {
            response.complete(value);
        }

        @Override
        public void onError(Throwable t) {
            response.completeExceptionally(t);
        }

        @Override
        public void onCompleted() {
            response.complete(null);
        }

        void send(UUID doc, List<Change> changes) {
            call.onNext(PushChangesRequest.newBuilder().setDocumentId(doc.toString()).addAllChanges(changes).build());
        }

        PushChangesResponse finish() throws Exception {
            call.onCompleted();
            return response.get(30, TimeUnit.SECONDS);
        }

        void cancel() {
            call.cancel("forced disconnect", null);
        }
    }

    Upload upload(String user) {
        Upload upload = new Upload();
        async(user, null).pushChanges(upload);
        return upload;
    }

    /** Frames of at most 1 MiB. */
    static List<List<Change>> frames(List<Change> changes) {
        List<List<Change>> frames = new ArrayList<>();
        List<Change> frame = new ArrayList<>();
        int bytes = 0;
        for (Change change : changes) {
            if (!frame.isEmpty() && bytes + change.getSerializedSize() + 16 > ChangeRules.MAX_FRAME_BYTES) {
                frames.add(frame);
                frame = new ArrayList<>();
                bytes = 0;
            }
            frame.add(change);
            bytes += change.getSerializedSize() + 16;
        }
        frames.add(frame);
        return frames;
    }

    /** The replica's last accepted seq as a fresh subscription's Welcome reports it. */
    long lastAccepted(UUID doc, long replica) {
        Subscription s = subscribe(ALICE, null, SubscribeRequest.newBuilder().setDocumentId(doc.toString())
                .setReplica(replica).setAfterServerSeq(Long.MAX_VALUE).build());
        long last = s.next().getWelcome().getLastAcceptedSeq();
        s.cancel();
        return last;
    }

    @Test
    void aLargeBacklogUploadsAcrossForcedDisconnects() throws Exception {
        UUID doc = document(ALICE);
        long replica = replicaId();
        List<Change> backlog = new ArrayList<>();
        long total = 0;
        for (int seq = 1; total < 50L * 1024 * 1024; seq++) {
            Change change = sized(replica, seq, 60 * 1024);
            backlog.add(change);
            total += change.getSerializedSize();
        }
        List<List<Change>> frames = frames(backlog);
        long started = System.nanoTime();
        int disconnects = 0;
        long resumeAfter = 0;
        PushChangesResponse done = null;
        while (done == null) {
            Upload upload = upload(ALICE);
            int sent = 0;
            for (List<Change> frame : frames) {
                if (frame.get(frame.size() - 1).getSeq() <= resumeAfter) {
                    continue;
                }
                upload.send(doc, frame);
                sent++;
                if (disconnects < 3 && sent == frames.size() / 5) {
                    break;
                }
            }
            if (disconnects < 3) {
                Thread.sleep(300);
                upload.cancel();
                disconnects++;
                // Resume a few changes early: already-accepted changes are silently acked.
                resumeAfter = Math.max(0, lastAccepted(doc, replica) - 3);
            } else {
                done = upload.finish();
            }
        }
        long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
        System.out.printf("SRV-006: %d changes, %d MiB in %d frames across %d disconnects in %d ms%n", backlog.size(),
                total >> 20, frames.size(), disconnects, elapsedMs);
        assertThat(done.hasRejected()).isFalse();
        assertThat(done.getLastAcceptedSeq()).isEqualTo(backlog.size());
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", doc)).isEqualTo(backlog.size());
        assertThat(column("SELECT seq FROM change_log WHERE document_id = ? ORDER BY server_seq", doc))
                .isEqualTo(backlog.stream().map(Change::getSeq).toList());
        assertThat(count("SELECT head_seq FROM document WHERE id = ?", doc)).isEqualTo(backlog.size());
    }

    @Test
    void aRejectionEndsTheUploadWithTheAcceptedPrefix() throws Exception {
        UUID doc = document(ALICE);
        long replica = replicaId();
        Upload upload = upload(ALICE);
        upload.send(doc, List.of(change(replica, 1), change(replica, 2)));
        upload.send(doc, List.of(change(replica, 3), change(replica, 5), change(replica, 6)));
        PushChangesResponse response = upload.finish();
        assertThat(response.getLastAcceptedSeq()).isEqualTo(3);
        assertThat(response.getRejected().getSeq()).isEqualTo(5);
        assertThat(response.getRejected().getReason()).isEqualTo(ErrorReason.ERROR_REASON_SEQ_GAP);
    }

    @Test
    void framesMustNameOneDocumentAndStayWithinOneMebibyte() throws Exception {
        UUID doc = document(ALICE);
        long replica = replicaId();
        Upload mixed = upload(ALICE);
        mixed.send(doc, List.of(change(replica, 1)));
        mixed.send(document(ALICE), List.of(change(replica, 2)));
        PushChangesResponse response = mixed.finish();
        assertThat(response.getLastAcceptedSeq()).isEqualTo(1);
        assertThat(response.getRejected().getReason()).isEqualTo(ErrorReason.ERROR_REASON_VALIDATION_FAILED);

        Upload oversized = upload(ALICE);
        oversized.send(doc, List.of(sized(replica, 2, 600 * 1024), sized(replica, 3, 600 * 1024)));
        PushChangesResponse big = oversized.finish();
        assertThat(big.getLastAcceptedSeq()).isEqualTo(1);
        assertThat(big.getRejected().getSeq()).isEqualTo(2);

        Upload alone = upload(ALICE);
        alone.send(doc, List.of(sized(replica, 2, 2 * 1024 * 1024)));
        assertThat(alone.finish().getLastAcceptedSeq()).isEqualTo(2);
    }

    @Test
    void aReaderIsRejectedAndAnEmptyUploadAcceptsNothing() throws Exception {
        UUID doc = document(ALICE);
        share(doc, bob, "viewer");
        Upload reader = upload(BOB);
        reader.send(doc, List.of(change(replicaId(), 1)));
        PushChangesResponse response = reader.finish();
        assertThat(response.getLastAcceptedSeq()).isZero();
        assertThat(response.getRejected().getReason()).isEqualTo(ErrorReason.ERROR_REASON_ROLE_INSUFFICIENT);

        assertThat(upload(ALICE).finish()).isEqualTo(PushChangesResponse.getDefaultInstance());
    }

    @Test
    void anAnonymousUploadFails() throws Exception {
        UUID doc = document(ALICE);
        Upload upload = new Upload();
        com.villagecompute.wiretuner.sync.v1.SyncServiceGrpc.newStub(channel).pushChanges(upload);
        upload.send(doc, List.of(change(replicaId(), 1)));
        upload.call.onCompleted();
        Throwable failure = null;
        try {
            upload.response.get(10, TimeUnit.SECONDS);
        } catch (java.util.concurrent.ExecutionException e) {
            failure = e.getCause();
        }
        assertThat(failure).isInstanceOf(io.grpc.StatusRuntimeException.class);
        assertThat(((io.grpc.StatusRuntimeException) failure).getStatus().getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
    }
}
