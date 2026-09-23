package com.villagecompute.wiretuner.api.sync;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.Reactive;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.PresenceState;
import com.villagecompute.wiretuner.sync.v1.PresenceUpdate;
import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;
import com.villagecompute.wiretuner.sync.v1.UpdatePresenceRequest;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.vertx.VertxContextSupport;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.Request;

import jakarta.inject.Inject;

/**
 * SRV-012: presence is rate-limited and coalesced per replica, expires (a crashed client disappears
 * for the others within the TTL -- 3 s in tests -- plus the one-second sweep), follows the replay as a
 * snapshot, and carries a color from the 12-color palette that is stable per person and document.
 */
@QuarkusTest
class PresenceTest extends SyncTestSupport {

    @Inject
    PresenceStore store;

    @Inject
    Colors colors;

    @Inject
    Redis redis;

    static PresenceUpdate tool(String tool) {
        return PresenceUpdate.newBuilder().setTool(tool).setState(PresenceState.PRESENCE_STATE_ACTIVE).build();
    }

    void update(String user, UUID doc, long replica, PresenceUpdate presence) {
        blocking(user, null).updatePresence(UpdatePresenceRequest.newBuilder().setDocumentId(doc.toString())
                .setReplica(replica).setPresence(presence).build());
    }

    /** The next presence update Bob's subscription sees from {@code user}. */
    static PresenceUpdate from(Subscription s, UUID user) {
        return SubscribeTest.presenceOf(s, user);
    }

    @Test
    void updatesFasterThanTheIntervalAreCoalescedToTheNewest() throws InterruptedException {
        UUID doc = document(ALICE);
        share(doc, bob, "viewer");
        Subscription bobs = subscribe(BOB, null, doc, replicaId(), 0);
        bobs.next(FrameCase.PRESENCE);
        long replica = replicaId();
        update(ALICE, doc, replica, tool("a"));
        update(ALICE, doc, replica, tool("b"));
        update(ALICE, doc, replica, tool("c"));
        assertThat(from(bobs, alice).getTool()).isEqualTo("a");
        assertThat(from(bobs, alice).getTool()).isEqualTo("c");
        Thread.sleep(500);
        assertThat(bobs.frames.stream().filter(f -> f.hasPresenceUpdate())).isEmpty();

        // A GONE while an update waits cancels it: the participant does not come back.
        update(ALICE, doc, replica, tool("d"));
        update(ALICE, doc, replica, tool("e"));
        update(ALICE, doc, replica, PresenceUpdate.newBuilder().setState(PresenceState.PRESENCE_STATE_GONE).build());
        assertThat(from(bobs, alice).getTool()).isEqualTo("d");
        assertThat(from(bobs, alice).getState()).isEqualTo(PresenceState.PRESENCE_STATE_GONE);
        Thread.sleep(500);
        assertThat(bobs.frames.stream().filter(f -> f.hasPresenceUpdate())).isEmpty();
        bobs.cancel();
    }

    @Test
    void aCrashedClientDisappearsWithinTheTtl() {
        UUID doc = document(ALICE);
        share(doc, bob, "viewer");
        Subscription bobs = subscribe(BOB, null, doc, replicaId(), 0);
        bobs.next(FrameCase.PRESENCE);
        // A client whose stream the server never saw close: it sent presence, then nothing.
        update(ALICE, doc, replicaId(), tool("pen"));
        long sent = System.nanoTime();
        assertThat(from(bobs, alice).getTool()).isEqualTo("pen");
        PresenceUpdate gone = from(bobs, alice);
        long after = System.nanoTime() - sent;
        assertThat(gone.getState()).isEqualTo(PresenceState.PRESENCE_STATE_GONE);
        assertThat(gone.getUser().getUserId()).isEqualTo(alice.toString());
        assertThat(after).isGreaterThan(TimeUnit.SECONDS.toNanos(2)).isLessThan(TimeUnit.SECONDS.toNanos(6));
        // Its rate-limit slot is forgotten by a later sweep.
        await(() -> store.slots.isEmpty() || store.slots.keySet().stream().noneMatch(k -> k.document().equals(doc)));
        bobs.cancel();
    }

    @Test
    void anEntryAnotherNodeRemovedOrWithoutStateIsSkipped() {
        UUID doc = document(ALICE);
        run(() -> store.expire(doc));
        run(() -> store.expire(doc, "79"));
        run(() -> redis.send(Request.cmd(Command.ZADD).arg(PresenceStore.deadlines(doc)).arg(1).arg("77")));
        run(() -> redis.send(Request.cmd(Command.ZADD).arg(PresenceStore.deadlines(doc)).arg(System.currentTimeMillis() + 60_000)
                .arg("78")));
        assertThat(Reactive.tx(() -> store.snapshot(doc)).getParticipantsList()).isEmpty();
        run(() -> store.expire(doc));
        assertThat(run(() -> redis.send(Request.cmd(Command.ZSCORE).arg(PresenceStore.deadlines(doc)).arg("77")))).isNull();
    }

    @Test
    void twelvePeopleGetTwelveColorsAndTheThirteenthWraps() {
        UUID doc = document(ALICE);
        List<Integer> seen = new ArrayList<>();
        List<UUID> people = new ArrayList<>();
        for (int i = 0; i < 14; i++) {
            UUID person = UUID.randomUUID();
            exec("INSERT INTO account (id, subject) VALUES (?, ?)", person, "color-" + person);
            people.add(person);
            seen.add(Reactive.tx(() -> colors.of(doc, person)));
        }
        assertThat(seen).containsExactly(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0, 1);
        // Returning keeps the color; a freed index is taken by the next newcomer.
        assertThat(Reactive.tx(() -> colors.of(doc, people.get(5)))).isEqualTo(5);
        UUID other = document(ALICE);
        exec("INSERT INTO document_member (document_id, account_id, role, color_index) VALUES (?, ?, 'viewer', 0)", other,
                people.get(0));
        exec("INSERT INTO document_member (document_id, account_id, role, color_index) VALUES (?, ?, 'viewer', 2)", other,
                people.get(1));
        share(other, people.get(2), "editor");
        assertThat(Reactive.tx(() -> colors.of(other, people.get(2)))).isEqualTo(1);
        assertThat(value("SELECT role FROM document_member WHERE document_id = ? AND account_id = ?", other, people.get(2)))
                .isEqualTo("editor");
        assertThat(Reactive.tx(() -> colors.of(other, people.get(3)))).isEqualTo(3);
    }

    @Test
    void theGoneOfAnExpiredEntryNamesOnlyWhoLeft() {
        PresenceUpdate last = tool("pen").toBuilder().setUser(Participant.newBuilder().setUserId("u")).setColorIndex(4)
                .setBranchId("b").build();
        PresenceUpdate gone = PresenceStore.gone(last);
        assertThat(gone.getTool()).isEmpty();
        assertThat(gone.getUser().getUserId()).isEqualTo("u");
        assertThat(gone.getColorIndex()).isEqualTo(4);
        assertThat(gone.getBranchId()).isEqualTo("b");
        assertThat(gone.getState()).isEqualTo(PresenceState.PRESENCE_STATE_GONE);
    }

    static <T> T run(java.util.function.Supplier<io.smallrye.mutiny.Uni<T>> work) {
        try {
            return VertxContextSupport.subscribeAndAwait(work::get);
        } catch (Throwable t) {
            throw new IllegalStateException(t);
        }
    }
}
