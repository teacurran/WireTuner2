package com.villagecompute.wiretuner.api.comments;

import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.jobs.JobLocks;
import com.villagecompute.wiretuner.api.sync.LiveSessions;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The Comment digest job (COLLAB-031; comments.adoc, Server): every 5 minutes, on one node, one mail
 * per (account, document) listing the mentions of the account there that are older than
 * {@code wt.comments.digest-delay} (10 minutes), unseen and not yet mailed, when the account has no
 * live session on the document and has not turned off <em>Email me when I'm mentioned</em> (the synced
 * preference {@value #PREFERENCE}, on by default). Each mention is quoted by its thread's opening line,
 * its author and a {@code wiretuner://doc/<document>/thread/<counter>-<replica>} link, and marked
 * {@code emailed_at}. Mentions a week old are no longer considered.
 */
@ApplicationScoped
public class CommentDigestJob {

    /** The synced preference id of <em>Email me when I'm mentioned</em>. */
    public static final String PREFERENCE = "sync.email_mentions";

    static final String DUE = """
            SELECT n.id, n.account_id, n.document_id, n.thread_counter, n.thread_replica, acc.email, d.name,
                   coalesce(au.display_name, ''),
                   coalesce((SELECT c.preview FROM comment c WHERE c.document_id = n.document_id
                             AND c.thread_counter = n.thread_counter AND c.thread_replica = n.thread_replica
                             ORDER BY c.element_counter, (c.element_replica # %s) LIMIT 1), '')
            FROM comment_notification n JOIN account acc ON acc.id = n.account_id
                 JOIN document d ON d.id = n.document_id
                 LEFT JOIN account au ON au.id = n.author_account_id
            WHERE n.kind = 'mention' AND n.seen_at IS NULL AND n.emailed_at IS NULL
              AND n.created_at <= now() - make_interval(secs => $1) AND n.created_at > now() - interval '7 days'
              AND acc.email <> '' AND d.trashed_at IS NULL
              AND coalesce(acc.preferences #>> '{values,%s,boolValue}', 'true') <> 'false'
            ORDER BY n.account_id, n.document_id, n.created_at, n.id
            """.formatted(CommentIndex.MIN, PREFERENCE);

    static final String EMAILED = "UPDATE comment_notification SET emailed_at = now() WHERE id = ANY($1)";

    @ConfigProperty(name = "wt.comments.digest-delay", defaultValue = "10M")
    Duration delay;

    @Inject
    JobLocks locks;

    @Inject
    Pool pool;

    @Inject
    LiveSessions sessions;

    @Inject
    CommentMailer mailer;

    /** The mentions of one account in one document. */
    record Digest(UUID account, UUID document, String email, String documentName, List<UUID> ids,
            List<CommentMailer.Mention> mentions) {
    }

    record Key(UUID account, UUID document) {
    }

    @Scheduled(identity = "comment-digest", every = "${wt.jobs.comment-digest.every:5m}",
            delayed = "${wt.jobs.comment-digest.delay:2m}", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("comment-digest", this::digest).replaceWithVoid();
    }

    /** One run: every due digest mailed, unless its account is on the document right now. */
    Uni<Void> digest() {
        return pool.preparedQuery(DUE).execute(Tuple.of((double) delay.toSeconds()))
                .map(rows -> {
                    Map<Key, Digest> digests = new LinkedHashMap<>();
                    for (Row row : rows) {
                        UUID account = row.getUUID(1);
                        UUID document = row.getUUID(2);
                        Digest digest = digests.computeIfAbsent(new Key(account, document), key -> new Digest(account,
                                document, row.getString(5), row.getString(6), new ArrayList<>(), new ArrayList<>()));
                        digest.ids().add(row.getUUID(0));
                        digest.mentions().add(new CommentMailer.Mention(row.getString(7),
                                row.getString(8).lines().findFirst().orElse(""),
                                link(document, row.getLong(3), row.getLong(4))));
                    }
                    return List.copyOf(digests.values());
                })
                .chain(digests -> Multi.createFrom().iterable(digests)
                        .onItem().transformToUniAndConcatenate(this::send)
                        .collect().last())
                .replaceWithVoid();
    }

    private Uni<Void> send(Digest digest) {
        return sessions.live(digest.document(), digest.account()).chain(live -> live ? Uni.createFrom().voidItem()
                : mailer.digest(digest.email(), digest.documentName(), digest.mentions())
                        .chain(() -> pool.preparedQuery(EMAILED).execute(Tuple.of(digest.ids().toArray(UUID[]::new))))
                        .replaceWithVoid());
    }

    /** The thread's link in the app (links.adoc): {@code wiretuner://doc/<document>/thread/<counter>-<replica>}. */
    static String link(UUID document, long counter, long replica) {
        return "wiretuner://doc/" + document + "/thread/" + Long.toUnsignedString(counter) + "-"
                + Long.toUnsignedString(replica);
    }
}
