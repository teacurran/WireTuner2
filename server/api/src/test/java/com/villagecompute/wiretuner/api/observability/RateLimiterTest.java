package com.villagecompute.wiretuner.api.observability;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeBatchRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeBatchResponse;
import com.villagecompute.wiretuner.sync.v1.SyncServiceGrpc;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.vertx.VertxContextSupport;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.Request;

import jakarta.inject.Inject;

/**
 * SRV-014: the token buckets in Valkey, per account and per document, refuse with
 * {@code RESOURCE_EXHAUSTED / RATE_LIMITED} and a {@code RetryInfo} delay, lease tokens in chunks,
 * and fall back to the exact cost near the limit.
 */
@QuarkusTest
class RateLimiterTest extends ServiceTestSupport {

    /** A last-refill time far in the future: the bucket does not refill while the test looks at it. */
    static final String FROZEN = "99999999999999";

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("sync")
    SyncServiceGrpc.SyncServiceBlockingStub sync;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    @Inject
    RateLimiter limiter;

    @Inject
    Redis redis;

    static <T> T run(java.util.function.Supplier<Uni<T>> work) {
        try {
            return VertxContextSupport.subscribeAndAwait(work::get);
        } catch (RuntimeException e) {
            throw e;
        } catch (Throwable t) {
            throw new IllegalStateException(t);
        }
    }

    void bucket(String key, long tokens) {
        run(() -> redis.send(Request.cmd(Command.HSET).arg(key).arg("tokens").arg(tokens).arg("at").arg(FROZEN)));
    }

    void drop(String key) {
        run(() -> redis.send(Request.cmd(Command.DEL).arg(key)));
    }

    UUID document() {
        UUID id = uuid7();
        UUID space = TestUsers.accountId(account, ALICE);
        as(docs, ALICE).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(space.toString())
                .setName("Limits").build());
        return id;
    }

    @Test
    void anEmptyDocumentBucketRefusesWithRetryInfo() {
        UUID doc = document();
        bucket(RateLimiter.documentKey(doc), -100_000);
        GetRequest get = GetRequest.newBuilder().setDocumentId(doc.toString()).build();
        StatusRuntimeException refused = failure(() -> as(docs, ALICE).get(get));
        assertThat(refused.getStatus().getCode()).isEqualTo(Status.Code.RESOURCE_EXHAUSTED);
        assertThat(StatusExceptions.reasonOf(refused)).contains(ErrorReasons.RATE_LIMITED);
        // 100,001 tokens at 5,000 per second.
        assertThat(StatusExceptions.retryDelayOf(refused).orElseThrow()).isBetween(Duration.ofSeconds(19),
                Duration.ofSeconds(21));

        // A batch push is refused as a whole, at its first change.
        long replica = replicaId();
        PushChangeBatchResponse batch = as(sync, ALICE).pushChangeBatch(PushChangeBatchRequest.newBuilder()
                .setDocumentId(doc.toString()).addChanges(change(replica, 1, "a")).addChanges(change(replica, 2, "b")).build());
        assertThat(batch.getServerSeqsList()).isEmpty();
        assertThat(batch.getRejected().getReason().name()).isEqualTo("ERROR_REASON_RATE_LIMITED");

        drop(RateLimiter.documentKey(doc));
        assertThat(as(docs, ALICE).get(get).getDocument().getId()).isEqualTo(doc.toString());
    }

    @Test
    void nearTheLimitTheExactCostIsTaken() {
        UUID doc = document();
        bucket(RateLimiter.documentKey(doc), 5);
        as(docs, ALICE).get(GetRequest.newBuilder().setDocumentId(doc.toString()).build());
        String left = run(() -> redis.send(Request.cmd(Command.HGET).arg(RateLimiter.documentKey(doc)).arg("tokens")))
                .toString();
        assertThat(Double.parseDouble(left)).isEqualTo(4.0);
        drop(RateLimiter.documentKey(doc));
    }

    @Test
    void anAccountBucketAloneLimitsCallsWithoutADocument() throws InterruptedException {
        UUID someone = UUID.randomUUID();
        bucket(RateLimiter.accountKey(someone), -5_000);
        StatusRuntimeException refused = failure(() -> run(() -> limiter.check(someone, null, 1)));
        assertThat(StatusExceptions.reasonOf(refused)).contains(ErrorReasons.RATE_LIMITED);
        drop(RateLimiter.accountKey(someone));
        run(() -> limiter.check(someone, null, 1));
        run(() -> limiter.check(someone, null, 1));
        limiter.purge();
        assertThat(limiter.leases()).isPositive();
        Thread.sleep(1_100);
        limiter.purge();
        assertThat(limiter.leases()).isZero();
    }
    /** The allowance's own lock guards a lease and the end of a refill (S2445: no lock on a parameter). */
    @Test
    void anAllowanceTakesALeaseAndEndsARefillUnderItsOwnLock() {
        RateLimiter.Allowance allowance = new RateLimiter.Allowance();
        allowance.refill = Uni.createFrom().voidItem();
        allowance.lease(32, 1_234L);
        assertThat(allowance.tokens).isEqualTo(32.0);
        assertThat(allowance.expiresAt).isEqualTo(1_234L);
        assertThat(allowance.refill).isNotNull();
        allowance.refillEnded();
        assertThat(allowance.refill).isNull();
        assertThat(allowance.tokens).isEqualTo(32.0);
    }
}
