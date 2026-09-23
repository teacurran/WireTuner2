package com.villagecompute.wiretuner.api.sync;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import org.junit.jupiter.api.Test;

import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.MoreExecutors;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeResponse;
import com.villagecompute.wiretuner.sync.v1.SyncServiceGrpc;

import com.villagecompute.wiretuner.api.TestUsers;

import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.quarkus.test.junit.QuarkusTest;

/**
 * SRV-004's load test: many replicas pushing pipelined unary calls (a window of 32 each, as the
 * client does) into one document on one node. Asserts at least 2,000 accepted changes per second
 * and a dense, gap-free {@code server_seq}; prints the measured rate.
 */
@QuarkusTest
class IngestLoadTest extends SyncTestSupport {

    static final int REPLICAS = 8;
    static final int PER_REPLICA = 2_500;
    static final int WINDOW = 32;
    static final double TARGET_PER_SECOND = 2_000;
    static final int PORT = 8081;

    @Test
    void twoThousandChangesPerSecondOnOneDocument() throws Exception {
        UUID doc = document(ALICE);
        UUID device = UUID.randomUUID();
        // One connection per client, as real clients have: a connection is served by one event loop.
        List<ManagedChannel> channels = new ArrayList<>();
        List<SyncServiceGrpc.SyncServiceFutureStub> stubs = new ArrayList<>();
        for (int r = 0; r < REPLICAS; r++) {
            ManagedChannel connection = ManagedChannelBuilder.forAddress("localhost", PORT).usePlaintext().build();
            channels.add(connection);
            SyncServiceGrpc.SyncServiceFutureStub stub = TestUsers.as(SyncServiceGrpc.newFutureStub(connection), ALICE, device);
            warmUp(stub);
            stubs.add(stub);
        }
        CountDownLatch done = new CountDownLatch(REPLICAS * PER_REPLICA);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        List<Thread> pushers = new ArrayList<>();
        long started = System.nanoTime();
        for (int r = 0; r < REPLICAS; r++) {
            long replica = replicaId();
            SyncServiceGrpc.SyncServiceFutureStub stub = stubs.get(r);
            Thread pusher = Thread.ofVirtual().start(() -> {
                Semaphore window = new Semaphore(WINDOW);
                for (int seq = 1; seq <= PER_REPLICA && failure.get() == null; seq++) {
                    window.acquireUninterruptibly();
                    Futures.addCallback(stub.pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                            .setChange(change(replica, seq)).build()), new FutureCallback<PushChangeResponse>() {
                                @Override
                                public void onSuccess(PushChangeResponse result) {
                                    window.release();
                                    done.countDown();
                                }

                                @Override
                                public void onFailure(Throwable t) {
                                    failure.compareAndSet(null, t);
                                    window.release();
                                    done.countDown();
                                }
                            }, MoreExecutors.directExecutor());
                }
            });
            pushers.add(pusher);
        }
        for (Thread pusher : pushers) {
            pusher.join();
        }
        assertThat(done.await(120, TimeUnit.SECONDS)).isTrue();
        double seconds = (System.nanoTime() - started) / 1e9;
        channels.forEach(ManagedChannel::shutdownNow);
        assertThat(failure.get()).isNull();
        int total = REPLICAS * PER_REPLICA;
        double rate = total / seconds;
        System.out.printf("SRV-004 load: %d changes from %d replicas (window %d) on one document in %.2f s = %.0f changes/s%n",
                total, REPLICAS, WINDOW, seconds, rate);

        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", doc)).isEqualTo(total);
        assertThat(count("SELECT max(server_seq) FROM change_log WHERE document_id = ?", doc)).isEqualTo(total);
        assertThat(count("SELECT min(server_seq) FROM change_log WHERE document_id = ?", doc)).isEqualTo(1);
        assertThat(count("SELECT head_seq FROM document WHERE id = ?", doc)).isEqualTo(total);
        assertThat(count("""
                SELECT count(*) FROM (SELECT replica_id, seq, row_number() OVER (PARTITION BY replica_id ORDER BY server_seq) n
                FROM change_log WHERE document_id = ?) t WHERE seq <> n
                """, doc)).as("every replica's changes in seq order").isZero();
        assertThat(rate).isGreaterThanOrEqualTo(TARGET_PER_SECOND);
    }

    /** A few hundred pushes on another document so the connection, the JIT and the pools are warm. */
    private void warmUp(SyncServiceGrpc.SyncServiceFutureStub stub) throws Exception {
        UUID doc = document(ALICE);
        long replica = replicaId();
        // A connected channel first: grpc-java may start calls it buffered while connecting in any order.
        stub.pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString()).setChange(change(replica, 1)).build())
                .get(30, TimeUnit.SECONDS);
        List<com.google.common.util.concurrent.ListenableFuture<PushChangeResponse>> calls = new ArrayList<>();
        for (int seq = 2; seq <= 500; seq++) {
            calls.add(stub.pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                    .setChange(change(replica, seq)).build()));
            if (calls.size() == WINDOW) {
                for (var call : calls) {
                    call.get(30, TimeUnit.SECONDS);
                }
                calls.clear();
            }
        }
        for (var call : calls) {
            call.get(30, TimeUnit.SECONDS);
        }
    }
}
