package com.villagecompute.wiretuner.api.observability;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.grpc.CallerContext;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.Request;
import io.vertx.mutiny.redis.client.Response;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Server-side rate limits per account and per document (docs/spec/security.adoc, Tokens and
 * transport; SRV-014): two token buckets in Valkey, refilled continuously at a rate per second up to
 * a burst, taken from atomically by one script so a call either takes from both buckets or from
 * neither. A call that would overdraw a bucket fails with {@code RESOURCE_EXHAUSTED / RATE_LIMITED}
 * and a {@code RetryInfo} delay: the time until the emptier bucket holds the call's cost again.
 * Clocks are Valkey's ({@code TIME}), so API nodes need not agree on the time.
 *
 * <p>Every RPC costs 1 against the caller's account (and against the document when it names one);
 * a push costs one per change. The defaults sit well above the ingest target (2,000 changes per
 * second on one document) so only abuse meets them.
 */
@ApplicationScoped
public class RateLimiter {

    /** KEYS: the buckets. ARGV: cost, then (rate per second, burst) per bucket. Returns the wait in ms (0 = taken). */
    static final String SCRIPT = """
            local t = redis.call('TIME')
            local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
            local cost = tonumber(ARGV[1])
            local wait = 0
            local levels = {}
            for i, key in ipairs(KEYS) do
              local rate = tonumber(ARGV[2 * i]) / 1000
              local burst = tonumber(ARGV[2 * i + 1])
              local state = redis.call('HMGET', key, 'tokens', 'at')
              local level = tonumber(state[1]) or burst
              local at = tonumber(state[2]) or now
              level = math.min(burst, level + math.max(0, now - at) * rate)
              levels[i] = level
              if level < cost then
                wait = math.max(wait, math.ceil((cost - level) / rate))
              end
            end
            if wait == 0 then
              for i, key in ipairs(KEYS) do
                local rate = tonumber(ARGV[2 * i]) / 1000
                redis.call('HSET', key, 'tokens', tostring(levels[i] - cost), 'at', now)
                redis.call('PEXPIRE', key, math.ceil(tonumber(ARGV[2 * i + 1]) / rate) + 1000)
              end
            end
            return wait
            """;

    @ConfigProperty(name = "wt.limits.account.rate", defaultValue = "5000")
    double accountRate;

    @ConfigProperty(name = "wt.limits.account.burst", defaultValue = "20000")
    double accountBurst;

    @ConfigProperty(name = "wt.limits.document.rate", defaultValue = "5000")
    double documentRate;

    @ConfigProperty(name = "wt.limits.document.burst", defaultValue = "20000")
    double documentBurst;

    @Inject
    Redis redis;

    @Inject
    WtMetrics metrics;

    /** Tokens a node takes from Valkey at once for one (account, document) pair. */
    static final int CHUNK = 32;
    /** How long a node may spend a lease before it lapses (unspent tokens are lost). */
    static final long LEASE_NANOS = 1_000_000_000L;

    /** A node-local lease of tokens for one (account, document) pair. */
    static final class Allowance {
        double tokens;
        long expiresAt;
        Uni<Void> refill;

        /** The refill in flight ended (granted or refused): the next shortfall starts another. */
        synchronized void refillEnded() {
            refill = null;
        }

        /** A lease came in: {@code granted} tokens to spend until {@code until} (System.nanoTime). */
        synchronized void lease(long granted, long until) {
            tokens = granted;
            expiresAt = until;
        }
    }

    record Pair(UUID account, UUID document) {
    }

    final Map<Pair, Allowance> allowances = new ConcurrentHashMap<>();

    public static String accountKey(UUID account) {
        return "rl:a:" + account;
    }

    public static String documentKey(UUID document) {
        return "rl:d:" + document;
    }

    /**
     * Takes {@code cost} from the account's bucket and, when {@code document} is not null, the document's.
     * Tokens are leased from Valkey {@value #CHUNK} at a time per (account, document) and spent locally for
     * up to a second, so a pipelined window of pushes costs one Valkey round trip, not 32; a lease the
     * buckets cannot give falls back to the exact cost before refusing.
     */
    public Uni<Void> check(UUID account, UUID document, int cost) {
        Allowance allowance = allowances.computeIfAbsent(new Pair(account, document), pair -> new Allowance());
        Uni<Void> refill;
        synchronized (allowance) {
            if (allowance.expiresAt - System.nanoTime() > 0 && allowance.tokens >= cost) {
                allowance.tokens -= cost;
                return Uni.createFrom().voidItem();
            }
            if (allowance.refill == null) {
                allowance.refill = lease(allowance, account, document, cost).memoize().indefinitely();
            }
            refill = allowance.refill;
        }
        // A refill another call started completes on that call's context; carry on on this one's, where
        // the caller's reactive session lives.
        return refill.emitOn(CallerContext.executor()).chain(() -> check(account, document, cost));
    }

    /** Leases a chunk (or, failing that, the exact cost) into the allowance; refused when neither fits. */
    private Uni<Void> lease(Allowance allowance, UUID account, UUID document, int cost) {
        long chunk = Math.max(cost, CHUNK);
        return take(account, document, chunk)
                .chain(wait -> wait == 0 ? Uni.createFrom().item(chunk)
                        : take(account, document, cost).map(exact -> exact == 0 ? (long) cost : -exact))
                .onTermination().invoke(allowance::refillEnded)
                .chain(granted -> {
                    if (granted < 0) {
                        metrics.rateLimited();
                        return Uni.createFrom().failure(StatusExceptions.rateLimited(Duration.ofMillis(-granted)));
                    }
                    allowance.lease(granted, System.nanoTime() + LEASE_NANOS);
                    return Uni.createFrom().voidItem();
                });
    }

    /** One script run: takes {@code cost} from the buckets, or answers the wait in ms (0 = taken). */
    Uni<Long> take(UUID account, UUID document, long cost) {
        Bucket accountBucket = new Bucket(accountKey(account), accountRate, accountBurst);
        return wait(document == null ? List.of(accountBucket)
                : List.of(accountBucket, new Bucket(documentKey(document), documentRate, documentBurst)), cost);
    }

    /** A token bucket: its Valkey key, its refill rate per second and its capacity. */
    public record Bucket(String key, double ratePerSecond, double burst) {
    }

    /**
     * Takes {@code cost} from every bucket or from none, without leasing (the data service's buckets,
     * DATA-008, are far below the lease size): refused with {@code RESOURCE_EXHAUSTED / RATE_LIMITED}
     * and the wait until the emptiest bucket holds the cost again.
     */
    public Uni<Void> takeExact(List<Bucket> buckets, long cost) {
        return wait(buckets, cost).chain(wait -> {
            if (wait == 0) {
                return Uni.createFrom().voidItem();
            }
            metrics.rateLimited();
            return Uni.createFrom().failure(StatusExceptions.rateLimited(Duration.ofMillis(wait)));
        });
    }

    private Uni<Long> wait(List<Bucket> buckets, long cost) {
        Request eval = Request.cmd(Command.EVAL).arg(SCRIPT).arg(buckets.size());
        buckets.forEach(bucket -> eval.arg(bucket.key()));
        eval.arg(cost);
        buckets.forEach(bucket -> eval.arg(bucket.ratePerSecond()).arg(bucket.burst()));
        return redis.send(eval).map(Response::toLong);
    }

    /** Leases this node holds (tests). */
    int leases() {
        return allowances.size();
    }

    /** Forgets lapsed leases. */
    @Scheduled(every = "10s")
    void purge() {
        long now = System.nanoTime();
        allowances.values().removeIf(allowance -> allowance.expiresAt - now <= 0);
    }
}
