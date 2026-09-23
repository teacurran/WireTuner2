package com.villagecompute.wiretuner.api.data;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.observability.RateLimiter;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The data service's abuse limits (data-merge.adoc, Rate limits and audit; DATA-008). Every upstream
 * request -- each page of a Fetch, a FetchAsset, a Proxy, an OAuth token request excepted -- takes one
 * token from the document's team bucket (600 a minute, burst 100) and from the caller's account bucket
 * (120 a minute, burst 20) in Valkey, through the SRV-014 limiter's script; refused is
 * {@code RESOURCE_EXHAUSTED / RATE_LIMITED} with {@code RetryInfo}. Concurrent calls are capped at 16 per
 * team and 4 per account, counted on this node.
 */
@ApplicationScoped
public class DataLimits {

    @ConfigProperty(name = "wt.data.limits.team.per-minute", defaultValue = "600")
    double teamPerMinute;

    @ConfigProperty(name = "wt.data.limits.team.burst", defaultValue = "100")
    double teamBurst;

    @ConfigProperty(name = "wt.data.limits.account.per-minute", defaultValue = "120")
    double accountPerMinute;

    @ConfigProperty(name = "wt.data.limits.account.burst", defaultValue = "20")
    double accountBurst;

    @ConfigProperty(name = "wt.data.concurrency.team", defaultValue = "16")
    int teamConcurrency;

    @ConfigProperty(name = "wt.data.concurrency.account", defaultValue = "4")
    int accountConcurrency;

    @Inject
    RateLimiter limiter;

    final Map<String, AtomicInteger> active = new ConcurrentHashMap<>();

    static final Duration BUSY_RETRY = Duration.ofSeconds(1);

    public static String teamKey(UUID team) {
        return "rl:dt:" + team;
    }

    public static String accountKey(UUID account) {
        return "rl:da:" + account;
    }

    /** One upstream request's token from the scope's team bucket (team documents) and the caller's bucket. */
    public Uni<Void> take(DataScope scope, UUID caller) {
        RateLimiter.Bucket account = new RateLimiter.Bucket(accountKey(caller), accountPerMinute / 60, accountBurst);
        return limiter.takeExact(scope.isTeam()
                ? List.of(new RateLimiter.Bucket(teamKey(scope.teamId()), teamPerMinute / 60, teamBurst), account)
                : List.of(account), 1);
    }

    /** A running call's place under the concurrency caps; release it once, when the call ends. */
    public final class Lease {
        private final List<String> keys;

        Lease(List<String> keys) {
            this.keys = keys;
        }

        public void release() {
            keys.forEach(key -> active.get(key).decrementAndGet());
        }
    }

    /** Admits a call under the caps, or refuses it with {@code RATE_LIMITED} and a one-second retry. */
    public Lease admit(DataScope scope, UUID caller) {
        String account = "a:" + caller;
        if (scope.isTeam()) {
            String team = "t:" + scope.teamId();
            if (!enter(team, teamConcurrency)) {
                throw StatusExceptions.rateLimited(BUSY_RETRY);
            }
            if (!enter(account, accountConcurrency)) {
                active.get(team).decrementAndGet();
                throw StatusExceptions.rateLimited(BUSY_RETRY);
            }
            return new Lease(List.of(team, account));
        }
        if (!enter(account, accountConcurrency)) {
            throw StatusExceptions.rateLimited(BUSY_RETRY);
        }
        return new Lease(List.of(account));
    }

    private boolean enter(String key, int cap) {
        AtomicInteger count = active.computeIfAbsent(key, k -> new AtomicInteger());
        if (count.incrementAndGet() > cap) {
            count.decrementAndGet();
            return false;
        }
        return true;
    }
}
