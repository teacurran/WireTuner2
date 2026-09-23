package com.villagecompute.wiretuner.api.sync;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.BeforeEach;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.GroupProps;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;
import com.villagecompute.wiretuner.sync.v1.SubscribeRequest;
import com.villagecompute.wiretuner.sync.v1.SyncServiceGrpc;

import io.grpc.Channel;
import io.grpc.stub.ClientCallStreamObserver;
import io.grpc.stub.ClientResponseObserver;
import io.quarkus.grpc.GrpcClient;

/** Documents, callers and subscriptions for the sync tests. */
abstract class SyncTestSupport extends ServiceTestSupport {

    static final Duration WAIT = Duration.ofSeconds(10);

    @GrpcClient("sync")
    Channel channel;

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    UUID alice;
    UUID bob;
    UUID carol;

    @BeforeEach
    void accounts() {
        alice = TestUsers.accountId(account, TestUsers.ALICE);
        bob = TestUsers.accountId(account, TestUsers.BOB);
        carol = TestUsers.accountId(account, TestUsers.CAROL);
    }

    /** Waits up to {@link #WAIT} for the condition. */
    static void await(java.util.function.BooleanSupplier condition) {
        long end = System.nanoTime() + WAIT.toNanos();
        while (!condition.getAsBoolean()) {
            assertThat(System.nanoTime()).as("condition within " + WAIT).isLessThan(end);
            try {
                Thread.sleep(50);
            } catch (InterruptedException e) {
                throw new IllegalStateException(e);
            }
        }
    }

    /** A new personal document of {@code user}, with no changes. */
    UUID document(String user) {
        UUID id = uuid7();
        UUID space = TestUsers.accountId(account, user);
        TestUsers.as(docs, user).create(CreateRequest.newBuilder()
                .setDocumentId(id.toString()).setSpaceId(space.toString()).setName("Sync").build());
        return id;
    }

    SyncServiceGrpc.SyncServiceBlockingStub blocking(String user, UUID device) {
        return TestUsers.as(SyncServiceGrpc.newBlockingStub(channel), user, device);
    }

    SyncServiceGrpc.SyncServiceFutureStub future(String user, UUID device) {
        return TestUsers.as(SyncServiceGrpc.newFutureStub(channel), user, device);
    }

    SyncServiceGrpc.SyncServiceStub async(String user, UUID device) {
        return TestUsers.as(SyncServiceGrpc.newStub(channel), user, device);
    }

    /** A change of {@code ops} no-ops. */
    static Change change(long replica, long seq) {
        return change(replica, seq, "Edit " + seq);
    }

    /** A change of about {@code bytes} bytes: CreateNode ops with 1 KiB positions. */
    static Change sized(long replica, long seq, int bytes) {
        Change.Builder change = Change.newBuilder().setReplica(replica).setSeq(seq).setStartCounter(seq * 1000)
                .setWallTimeMs(1).setLabel("Bulk " + seq);
        Op create = Op.newBuilder().setCreate(CreateNode.newBuilder()
                .setParent(OpId.newBuilder().setCounter(2))
                .setPosition(ByteString.copyFrom(new byte[1000]))
                .setProps(NodeProps.newBuilder().setGroup(GroupProps.getDefaultInstance()))).build();
        for (int i = 0; i < bytes / 1024; i++) {
            change.addOps(create);
        }
        return change.build();
    }

    Subscription subscribe(String user, UUID device, UUID document, long replica, long after) {
        return subscribe(user, device, SubscribeRequest.newBuilder()
                .setDocumentId(document.toString()).setReplica(replica).setAfterServerSeq(after).build());
    }

    Subscription subscribe(String user, UUID device, SubscribeRequest request) {
        Subscription subscription = new Subscription();
        async(user, device).subscribe(request, subscription);
        return subscription;
    }

    /** One Subscribe stream: every frame in a queue, the terminal status in {@link #done}. */
    static final class Subscription implements ClientResponseObserver<SubscribeRequest, ServerFrame> {
        final BlockingQueue<ServerFrame> frames = new LinkedBlockingQueue<>();
        final CompletableFuture<Void> done = new CompletableFuture<>();
        private ClientCallStreamObserver<SubscribeRequest> call;

        @Override
        public void beforeStart(ClientCallStreamObserver<SubscribeRequest> requestStream) {
            this.call = requestStream;
        }

        @Override
        public void onNext(ServerFrame frame) {
            frames.add(frame);
        }

        @Override
        public void onError(Throwable t) {
            done.completeExceptionally(t);
        }

        @Override
        public void onCompleted() {
            done.complete(null);
        }

        /** The next frame; fails the test after {@link #WAIT}. */
        ServerFrame next() {
            try {
                ServerFrame frame = frames.poll(WAIT.toMillis(), TimeUnit.MILLISECONDS);
                if (frame == null && done.isCompletedExceptionally()) {
                    throw new AssertionError("the subscription failed", done.exceptionNow());
                }
                assertThat(frame).as("a frame within " + WAIT).isNotNull();
                return frame;
            } catch (InterruptedException e) {
                throw new IllegalStateException(e);
            }
        }

        /** The next frame of the given case, skipping pongs and anything else. */
        ServerFrame next(ServerFrame.FrameCase kind) {
            while (true) {
                ServerFrame frame = next();
                if (frame.getFrameCase() == kind) {
                    return frame;
                }
            }
        }

        /** The next {@code n} changes, skipping other frames. */
        List<SequencedChange> changes(int n) {
            List<SequencedChange> changes = new ArrayList<>();
            while (changes.size() < n) {
                changes.add(next(ServerFrame.FrameCase.CHANGE).getChange());
            }
            return changes;
        }

        /** No change arrives within {@code quiet}. */
        void assertNoChange(Duration quiet) {
            long end = System.nanoTime() + quiet.toNanos();
            try {
                while (System.nanoTime() < end) {
                    ServerFrame frame = frames.poll(end - System.nanoTime(), TimeUnit.NANOSECONDS);
                    assertThat(frame == null || !frame.hasChange()).as("unexpected " + frame).isTrue();
                }
            } catch (InterruptedException e) {
                throw new IllegalStateException(e);
            }
        }

        void cancel() {
            call.cancel("test drops the stream", null);
        }
    }
}
