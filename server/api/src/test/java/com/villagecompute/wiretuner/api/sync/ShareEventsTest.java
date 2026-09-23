package com.villagecompute.wiretuner.api.sync;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.docs.v1.InviteRequest;
import com.villagecompute.wiretuner.docs.v1.RemoveMemberRequest;
import com.villagecompute.wiretuner.docs.v1.SetRoleRequest;
import com.villagecompute.wiretuner.docs.v1.ShareServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.TransferOwnershipRequest;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;
import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;
import com.villagecompute.wiretuner.api.PerfReport;
import com.villagecompute.wiretuner.api.PerfTest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/**
 * SRV-010 on live sessions: sharing changes reach the document's subscriptions as document events --
 * {@code MembersChanged} for everyone, {@code RoleChanged} / {@code AccessRemoved} for the person
 * concerned only -- and a downgrade takes effect on that person's next change.
 */
@QuarkusTest
class ShareEventsTest extends SyncTestSupport {

    @GrpcClient("share")
    ShareServiceGrpc.ShareServiceBlockingStub share;

    ShareServiceGrpc.ShareServiceBlockingStub by(String user) {
        return TestUsers.as(share, user);
    }

    long push(String user, UUID doc, long replica, long seq) {
        return blocking(user, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                .setChange(change(replica, seq)).build()).getServerSeq();
    }

    static DocumentEvent event(Subscription s, DocumentEvent.EventCase kind) {
        while (true) {
            DocumentEvent event = s.next(FrameCase.EVENT).getEvent();
            if (event.getEventCase() == kind) {
                return event;
            }
        }
    }

    @Test
    void aDowngradeReachesTheSessionAndRejectsTheNextChange() {
        downgrade();
    }

    /** The perf run: the RoleChanged reaches the session within a second (SRV-010). */
    @PerfTest
    void aDowngradeReachesTheSessionWithinASecond() {
        long elapsed = downgrade();
        PerfReport.measured("Role change to a live session (SRV-010)",
                String.format(Locale.ROOT, "%.0f ms", elapsed / 1e6), "< 1000 ms",
                elapsed < TimeUnit.MILLISECONDS.toNanos(1000));
        assertThat(elapsed).isLessThan(TimeUnit.MILLISECONDS.toNanos(1000));
    }

    private long downgrade() {
        UUID doc = document(ALICE);
        by(ALICE).invite(InviteRequest.newBuilder().setDocumentId(doc.toString()).setAccountId(bob.toString())
                .setRole(DocumentRole.DOCUMENT_ROLE_EDITOR).build());
        by(ALICE).invite(InviteRequest.newBuilder().setDocumentId(doc.toString()).setAccountId(carol.toString())
                .setRole(DocumentRole.DOCUMENT_ROLE_VIEWER).build());
        long replica = replicaId();
        Subscription bobs = subscribe(BOB, null, doc, replica, 0);
        bobs.next(FrameCase.PRESENCE);
        Subscription carols = subscribe(CAROL, null, doc, replicaId(), 0);
        carols.next(FrameCase.PRESENCE);
        // Bob's push decision is memoised for 2 s from here on.
        assertThat(push(BOB, doc, replica, 1)).isEqualTo(1);

        long started = System.nanoTime();
        by(ALICE).setRole(SetRoleRequest.newBuilder().setDocumentId(doc.toString()).setAccountId(bob.toString())
                .setRole(DocumentRole.DOCUMENT_ROLE_VIEWER).build());
        DocumentEvent changed = event(bobs, DocumentEvent.EventCase.ROLE_CHANGED);
        long elapsed = System.nanoTime() - started;
        assertThat(changed.getRoleChanged().getRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER);
        assertThat(changed.getRoleChanged().getActor().getUserId()).isEqualTo(alice.toString());
        assertFails(() -> push(BOB, doc, replica, 2), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);

        // Carol hears that the members changed, and nothing about Bob's role.
        DocumentEvent members = event(carols, DocumentEvent.EventCase.MEMBERS_CHANGED);
        assertThat(members.getMembersChanged().getActor().getUserId()).isEqualTo(alice.toString());
        long end = System.nanoTime() + Duration.ofMillis(300).toNanos();
        while (System.nanoTime() < end) {
            ServerFrame frame = carols.frames.poll();
            assertThat(frame == null || !frame.getEvent().hasRoleChanged()).isTrue();
        }
        carols.cancel();
        bobs.cancel();
        return elapsed;
    }

    @Test
    void aFrameForOneAccountFromAnotherNodeReachesOnlyItsSessions() {
        UUID doc = document(ALICE);
        share(doc, bob, "viewer");
        Subscription alices = subscribe(ALICE, null, doc, replicaId(), 0);
        alices.next(FrameCase.PRESENCE);
        Subscription bobs = subscribe(BOB, null, doc, replicaId(), 0);
        bobs.next(FrameCase.PRESENCE);
        byte[] frame = ServerFrame.newBuilder().setEvent(DocumentEvent.newBuilder().setRoleChanged(
                com.villagecompute.wiretuner.sync.v1.RoleChanged.newBuilder().setRole(DocumentRole.DOCUMENT_ROLE_EDITOR)))
                .build().toByteArray();
        byte[] payload = new byte[SyncBus.HEADER + frame.length];
        payload[0] = 7;
        System.arraycopy(SyncBus.uuidBytes(bob), 0, payload, 16, 16);
        System.arraycopy(frame, 0, payload, SyncBus.HEADER, frame.length);
        redis.send(io.vertx.mutiny.redis.client.Request.cmd(io.vertx.mutiny.redis.client.Command.PUBLISH)
                .arg(SyncBus.PREFIX + doc).arg(io.vertx.mutiny.core.buffer.Buffer.buffer(payload))).await().atMost(WAIT);
        assertThat(event(bobs, DocumentEvent.EventCase.ROLE_CHANGED).getRoleChanged().getRole())
                .isEqualTo(DocumentRole.DOCUMENT_ROLE_EDITOR);
        long end = System.nanoTime() + Duration.ofMillis(300).toNanos();
        while (System.nanoTime() < end) {
            ServerFrame seen = alices.frames.poll();
            assertThat(seen == null || !seen.getEvent().hasRoleChanged()).isTrue();
        }
        alices.cancel();
        bobs.cancel();
    }

    @jakarta.inject.Inject
    io.vertx.mutiny.redis.client.Redis redis;

    @Test
    void removedAccessEndsTheSubscription() {
        UUID doc = document(ALICE);
        by(ALICE).invite(InviteRequest.newBuilder().setDocumentId(doc.toString()).setAccountId(bob.toString())
                .setRole(DocumentRole.DOCUMENT_ROLE_EDITOR).build());
        Subscription bobs = subscribe(BOB, null, doc, replicaId(), 0);
        bobs.next(FrameCase.PRESENCE);
        by(ALICE).removeMember(RemoveMemberRequest.newBuilder().setDocumentId(doc.toString())
                .setAccountId(bob.toString()).build());
        DocumentEvent removed = event(bobs, DocumentEvent.EventCase.ACCESS_REMOVED);
        assertThat(removed.getAccessRemoved().getActor().getUserId()).isEqualTo(alice.toString());
        bobs.done.orTimeout(WAIT.toMillis(), TimeUnit.MILLISECONDS).join();
        assertThat(bobs.done).isCompleted();
    }

    @Test
    void aTransferMovesTheDocumentForEveryone() {
        UUID doc = document(ALICE);
        by(ALICE).invite(InviteRequest.newBuilder().setDocumentId(doc.toString()).setAccountId(bob.toString())
                .setRole(DocumentRole.DOCUMENT_ROLE_EDITOR).build());
        Subscription alices = subscribe(ALICE, null, doc, replicaId(), 0);
        alices.next(FrameCase.PRESENCE);
        by(ALICE).transferOwnership(TransferOwnershipRequest.newBuilder().setDocumentId(doc.toString())
                .setNewOwnerAccountId(bob.toString()).build());
        assertThat(event(alices, DocumentEvent.EventCase.ROLE_CHANGED).getRoleChanged().getRole())
                .isEqualTo(DocumentRole.DOCUMENT_ROLE_EDITOR);
        assertThat(event(alices, DocumentEvent.EventCase.MOVED).getMoved().getSpaceId()).isEqualTo(bob.toString());
        alices.cancel();
    }
}
