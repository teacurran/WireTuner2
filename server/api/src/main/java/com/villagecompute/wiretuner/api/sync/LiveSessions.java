package com.villagecompute.wiretuner.api.sync;

import java.time.Duration;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.Request;
import io.vertx.mutiny.redis.client.Response;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Who has a live subscription on which document, across nodes: the digest mails a mention only to
 * someone without one (COLLAB-031), and role changes that concern many people are computed only for
 * the ones who are watching (COLLAB-011). Each document has a sorted set {@code live:<doc>} in Valkey
 * whose members are {@code <account>:<node>} scored with the time they lapse; a node adds its member
 * with an account's first subscription on the document, renews it every {@code wt.sessions.renew}
 * (20 s) for {@code wt.sessions.ttl} (60 s), and removes it with the last, so a crashed node's
 * entries lapse within the TTL.
 */
@ApplicationScoped
public class LiveSessions {

    private static final Logger LOG = Logger.getLogger(LiveSessions.class);

    static final String PREFIX = "live:";

    record Key(UUID document, UUID account) {
    }

    @ConfigProperty(name = "wt.sessions.ttl", defaultValue = "60S")
    Duration ttl;

    @Inject
    Redis redis;

    @Inject
    SyncBus bus;

    /** This node's subscriptions per (document, account). */
    final Map<Key, Integer> local = new ConcurrentHashMap<>();

    /** This node's subscriptions of the account on the document (tests; the field is behind the CDI proxy). */
    int localCount(UUID document, UUID account) {
        return local.getOrDefault(new Key(document, account), 0);
    }

    /** Requests per Valkey round trip. */
    static final int BATCH = 500;

    private String node() {
        return HexFormat.of().formatHex(bus.node);
    }

    /** A subscription opened: the account's first on the document here announces it (without waiting for Valkey). */
    public void open(UUID document, UUID account) {
        Key key = new Key(document, account);
        if (local.merge(key, 1, Integer::sum) == 1) {
            add(List.of(key)).subscribe().with(LOG::trace, LOG::warn);
        }
    }

    /** A subscription ended: the account's last on the document here withdraws it. */
    public void close(UUID document, UUID account) {
        Key key = new Key(document, account);
        if (local.merge(key, -1, Integer::sum) > 0) {
            return;
        }
        local.remove(key, 0);
        redis.send(Request.cmd(Command.ZREM).arg(PREFIX + document).arg(account + ":" + node()))
                .subscribe().with(LOG::trace, LOG::warn);
    }

    /** The accounts with a live subscription on the document, on any node. */
    public Uni<Set<UUID>> accounts(UUID document) {
        return accounts(List.of(document)).map(all -> all.get(document));
    }

    /** Whether the account has a live subscription on the document, on any node. */
    public Uni<Boolean> live(UUID document, UUID account) {
        return accounts(document).map(accounts -> accounts.contains(account));
    }

    /** The live accounts of each document, {@value #BATCH} documents per round trip. */
    public Uni<Map<UUID, Set<UUID>>> accounts(List<UUID> documents) {
        String now = Long.toString(System.currentTimeMillis());
        Map<UUID, Set<UUID>> out = new ConcurrentHashMap<>();
        return Multi.createFrom().iterable(documents).group().intoLists().of(BATCH)
                .onItem().transformToUniAndConcatenate(group -> redis.batch(group.stream()
                        .map(document -> Request.cmd(Command.ZRANGEBYSCORE).arg(PREFIX + document).arg(now).arg("+inf"))
                        .toList()).invoke(responses -> {
                            for (int i = 0; i < group.size(); i++) {
                                out.put(group.get(i), members(responses.get(i)));
                            }
                        }))
                .collect().last()
                .map(ignored -> out);
    }

    private static Set<UUID> members(Response members) {
        Set<UUID> accounts = new HashSet<>();
        for (Response member : members) {
            String value = member.toString();
            accounts.add(UUID.fromString(value.substring(0, value.indexOf(':'))));
        }
        return accounts;
    }

    /** Renews this node's entries and drops lapsed ones. */
    @Scheduled(every = "${wt.sessions.renew:20S}", delayed = "${wt.sessions.renew:20S}")
    Uni<Void> renew() {
        return add(new ArrayList<>(local.keySet()));
    }

    private Uni<Void> add(List<Key> keys) {
        long now = System.currentTimeMillis();
        String until = Long.toString(now + ttl.toMillis());
        String node = node();
        return Multi.createFrom().iterable(keys).group().intoLists().of(BATCH)
                .onItem().transformToUniAndConcatenate(group -> {
                    List<Request> writes = new ArrayList<>();
                    for (Key key : group) {
                        String set = PREFIX + key.document();
                        writes.add(Request.cmd(Command.ZADD).arg(set).arg(until).arg(key.account() + ":" + node));
                        writes.add(Request.cmd(Command.ZREMRANGEBYSCORE).arg(set).arg("-inf").arg(Long.toString(now)));
                        writes.add(Request.cmd(Command.PEXPIRE).arg(set).arg(Long.toString(2 * ttl.toMillis())));
                    }
                    return redis.batch(writes);
                })
                .collect().last()
                .replaceWithVoid();
    }
}
