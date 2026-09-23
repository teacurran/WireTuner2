package com.villagecompute.wiretuner.api.sync;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.auth.CallMetadata;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.sync.ChangeIngest.Pusher;
import com.villagecompute.wiretuner.sync.v1.Participant;

import io.smallrye.mutiny.Uni;

/** SRV-005: push authorisations are remembered per token, device and document for their time to live. */
class PushGrantsTest {

    final AtomicInteger resolved = new AtomicInteger();

    final Supplier<Uni<Pusher>> resolve = () -> Uni.createFrom().item(() -> {
        resolved.incrementAndGet();
        return new Pusher(new Principal(UUID.randomUUID(), "s", null, "password", null, "r"), Participant.getDefaultInstance());
    });

    static PushGrants grants(Duration ttl) {
        PushGrants grants = new PushGrants();
        grants.ttl = ttl;
        grants.callMetadata = new CallMetadata();
        grants.callMetadata.authorization("Bearer token");
        grants.callMetadata.deviceId("device");
        return grants;
    }

    @Test
    void aLiveGrantIsReusedForTheSameTokenDeviceAndDocument() {
        PushGrants grants = grants(Duration.ofHours(1));
        UUID doc = UUID.randomUUID();
        Pusher first = grants.pusher(doc, resolve).await().indefinitely();
        assertThat(grants.pusher(doc, resolve).await().indefinitely()).isSameAs(first);
        assertThat(resolved).hasValue(1);
        grants.pusher(UUID.randomUUID(), resolve).await().indefinitely();
        grants.callMetadata.authorization("Bearer refreshed");
        grants.pusher(doc, resolve).await().indefinitely();
        assertThat(resolved).hasValue(3);
        grants.purge();
        assertThat(grants.size()).isEqualTo(3);
    }

    @Test
    void anExpiredGrantIsResolvedAgainAndPurged() {
        PushGrants grants = grants(Duration.ZERO);
        UUID doc = UUID.randomUUID();
        grants.pusher(doc, resolve).await().indefinitely();
        grants.pusher(doc, resolve).await().indefinitely();
        assertThat(resolved).hasValue(2);
        grants.purge();
        assertThat(grants.size()).isZero();
    }
}
