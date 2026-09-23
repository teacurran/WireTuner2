package com.villagecompute.wiretuner.api.sync;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;

import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/** Live sessions across nodes: an account is live on a document from its first subscription to its last. */
@QuarkusTest
class LiveSessionsTest extends SyncTestSupport {

    @Inject
    LiveSessions sessions;

    boolean live(UUID doc) {
        return sessions.live(doc, alice).await().atMost(WAIT);
    }

    @Test
    void anAccountIsLiveWhileAnyOfItsSubscriptionsIs() {
        UUID doc = document(ALICE);
        assertThat(live(doc)).isFalse();
        Subscription first = subscribe(ALICE, null, doc, replicaId(), 0);
        first.next(FrameCase.PRESENCE);
        Subscription second = subscribe(ALICE, null, doc, replicaId(), 0);
        second.next(FrameCase.PRESENCE);
        await(() -> live(doc));
        assertThat(sessions.localCount(doc, alice)).isEqualTo(2);

        first.cancel();
        await(() -> sessions.localCount(doc, alice) == 1);
        sessions.renew().await().atMost(WAIT);
        assertThat(live(doc)).isTrue();

        second.cancel();
        await(() -> !live(doc));
        assertThat(sessions.localCount(doc, alice)).isZero();
        assertThat(sessions.accounts(List.of()).await().atMost(WAIT)).isEmpty();
    }

    @Test
    void anEntryLapsesWhenItsNodeStopsRenewing() {
        UUID doc = document(ALICE);
        UUID other = UUID.randomUUID();
        redis.send(io.vertx.mutiny.redis.client.Request.cmd(io.vertx.mutiny.redis.client.Command.ZADD)
                .arg(LiveSessions.PREFIX + doc).arg(Long.toString(System.currentTimeMillis() - 1000))
                .arg(other + ":gone")).await().atMost(WAIT);
        assertThat(sessions.accounts(doc).await().atMost(WAIT)).doesNotContain(other);
    }

    @Inject
    io.vertx.mutiny.redis.client.Redis redis;
}
