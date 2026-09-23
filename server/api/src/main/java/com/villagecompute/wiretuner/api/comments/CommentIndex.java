package com.villagecompute.wiretuner.api.comments;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.villagecompute.wiretuner.api.comments.CommentOps.CommentOp;
import com.villagecompute.wiretuner.api.comments.CommentOps.CreateThread;
import com.villagecompute.wiretuner.api.comments.CommentOps.ElementWrite;
import com.villagecompute.wiretuner.api.comments.CommentOps.Id;
import com.villagecompute.wiretuner.api.comments.CommentOps.Mentioned;
import com.villagecompute.wiretuner.api.comments.CommentOps.NewComments;
import com.villagecompute.wiretuner.api.comments.CommentOps.NodeOp;
import com.villagecompute.wiretuner.api.comments.CommentOps.Reaction;
import com.villagecompute.wiretuner.api.comments.CommentOps.Resolve;
import com.villagecompute.wiretuner.api.comments.CommentOps.ThreadWrite;
import com.villagecompute.wiretuner.api.comments.CommentOps.Typed;
import com.villagecompute.wiretuner.api.comments.CommentRules.Known;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository;
import com.villagecompute.wiretuner.api.sync.ChangeIngest.Pusher;
import com.villagecompute.wiretuner.api.sync.DocumentEvents;
import com.villagecompute.wiretuner.sync.v1.CommentEvent;
import com.villagecompute.wiretuner.sync.v1.CommentEventKind;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.RowSet;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The server's record of comments (COLLAB-030; comments.adoc, Server; D-050), kept from the ops the
 * ingest parses: threads with their opener and {@code resolved}, comments with their author,
 * {@code deleted} and a preview, and the notifications they cause -- mentions (a {@code team:} member
 * expanding to the team's members with access), replies to the thread's opener and earlier repliers,
 * and the opener's thread being resolved -- each pushed at once as a {@code CommentEvent} to the
 * recipient's sessions on the document. The role rule reads the same record before the write
 * ({@link #check}); the record learns the change after it ({@link #index}), before the change is fanned
 * out. Every statement is idempotent, so a retried change that was accepted before repairs a record
 * that missed it.
 *
 * <p>Plain SQL on the reactive pool: the ingest path runs outside the caller's Hibernate session.
 * Registers written by last-writer-wins compare op ids with the replica as unsigned ({@code # MIN}
 * flips the sign bit).
 */
@ApplicationScoped
public class CommentIndex {

    static final String MIN = "(-9223372036854775807 - 1)";

    /** Newer than the stored stamp {@code (counter, replica)} of a last-writer-wins register. */
    static String newer(String counter, String replica, String c, String r) {
        return "((" + counter + " # " + MIN + ") < (" + c + " # " + MIN + ") OR (" + counter + " = " + c + " AND ("
                + replica + " # " + MIN + ") < (" + r + " # " + MIN + ")))";
    }

    /** Account {@code a.id} can open document {@code d}. */
    static final String CAN_OPEN = LibraryRepository.VISIBLE.replace("?1", "a.id");

    static final String THREADS = """
            SELECT t.node_counter, t.node_replica, t.opener_account_id FROM comment_thread t
            JOIN unnest($2::bigint[], $3::bigint[]) AS k(c, r) ON t.node_counter = k.c AND t.node_replica = k.r
            WHERE t.document_id = $1
            """;

    static final String AUTHORS = """
            SELECT c.element_counter, c.element_replica, c.author_account_id FROM comment c
            JOIN unnest($2::bigint[], $3::bigint[]) AS k(c, r) ON c.element_counter = k.c AND c.element_replica = k.r
            WHERE c.document_id = $1
            """;

    static final String INSERT_THREAD = """
            INSERT INTO comment_thread (document_id, node_counter, node_replica, opener_account_id, created_seq)
            VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING
            """;

    static final String INSERT_COMMENTS = """
            INSERT INTO comment (document_id, thread_counter, thread_replica, element_counter, element_replica,
                                 author_account_id, server_seq)
            SELECT $1, $2, $3, k.c, k.r, $4, $5 FROM unnest($6::bigint[], $7::bigint[]) AS k(c, r)
            ON CONFLICT DO NOTHING RETURNING element_counter, element_replica
            """;

    /** Reply notifications for new comments $5/$6 of thread $2/$3 by $4: its opener and earlier authors who can open it. */
    static final String REPLIES = """
            WITH e AS (SELECT * FROM unnest($5::bigint[], $6::bigint[]) AS e(c, r)),
            a AS (SELECT author_account_id AS id FROM comment
                  WHERE document_id = $1 AND thread_counter = $2 AND thread_replica = $3
                    AND (element_counter, element_replica) NOT IN (SELECT c, r FROM e)
                  UNION SELECT opener_account_id FROM comment_thread
                  WHERE document_id = $1 AND node_counter = $2 AND node_replica = $3)
            INSERT INTO comment_notification (id, account_id, document_id, thread_counter, thread_replica,
                                              comment_counter, comment_replica, kind, author_account_id)
            SELECT gen_random_uuid(), a.id, $1, $2, $3, e.c, e.r, 'reply', $4 FROM a, e, document d
            WHERE d.id = $1 AND a.id IS NOT NULL AND a.id <> $4 AND %s
            ON CONFLICT DO NOTHING RETURNING account_id, comment_counter, comment_replica
            """.formatted(CAN_OPEN);

    /**
     * Mention notifications for comment $4/$5 of thread $2/$3 by $6: the accounts and teams named in
     * $7 that can open the document, once per recipient and comment in 24 hours.
     */
    static final String MENTIONS = """
            WITH m AS (SELECT unnest($7::text[]) AS v),
            a AS (SELECT cast(v AS uuid) AS id FROM m
                  WHERE v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                  UNION SELECT tm.account_id FROM m JOIN team_member tm ON v = 'team:' || tm.team_id)
            INSERT INTO comment_notification (id, account_id, document_id, thread_counter, thread_replica,
                                              comment_counter, comment_replica, kind, author_account_id)
            SELECT gen_random_uuid(), a.id, $1, $2, $3, $4, $5, 'mention', $6 FROM a, document d
            WHERE d.id = $1 AND a.id <> $6 AND %s
              AND NOT EXISTS (SELECT 1 FROM comment_notification n WHERE n.account_id = a.id AND n.document_id = $1
                              AND n.comment_counter = $4 AND n.comment_replica = $5 AND n.kind = 'mention'
                              AND n.created_at > now() - interval '24 hours')
            RETURNING account_id, comment_counter, comment_replica
            """.formatted(CAN_OPEN);

    /** Writes {@code resolved} by last-writer-wins; a flip to true notifies the opener (not the resolver). */
    static final String RESOLVE = """
            WITH old AS (SELECT resolved FROM comment_thread
                         WHERE document_id = $1 AND node_counter = $2 AND node_replica = $3),
            upd AS (UPDATE comment_thread t SET resolved = $4, resolved_counter = $5, resolved_replica = $6
                    WHERE t.document_id = $1 AND t.node_counter = $2 AND t.node_replica = $3
                      AND %s
                    RETURNING t.opener_account_id)
            INSERT INTO comment_notification (id, account_id, document_id, thread_counter, thread_replica,
                                              comment_counter, comment_replica, kind, author_account_id)
            SELECT gen_random_uuid(), upd.opener_account_id, $1, $2, $3, $5, $6, 'resolved', $7 FROM upd, old
            WHERE $4 AND NOT old.resolved AND upd.opener_account_id <> $7
            ON CONFLICT DO NOTHING RETURNING account_id, comment_counter, comment_replica
            """.formatted(newer("t.resolved_counter", "t.resolved_replica", "$5", "$6"));

    static final String DELETE = """
            UPDATE comment SET deleted = $4, deleted_counter = $5, deleted_replica = $6
            WHERE document_id = $1 AND element_counter = $2 AND element_replica = $3 AND %s
            """.formatted(newer("deleted_counter", "deleted_replica", "$5", "$6"));

    static final String PREVIEW = """
            UPDATE comment SET preview = $4
            WHERE document_id = $1 AND element_counter = $2 AND element_replica = $3 AND preview = ''
            """;

    /** The digest quotes at most this many characters of a comment (comments.adoc, Server). */
    static final int PREVIEW_CHARS = 200;

    /** A change's comment ops and what the server knew of the threads and comments they name. */
    public record Checked(List<CommentOp> ops, Known known) {
    }

    /** A change that concerns no comment: nothing to look up, check or record (the ingest's common case). */
    static final Checked NOTHING = new Checked(List.of(), new Known(Map.of(), Map.of()));

    /** One notification to push: to whom, about which thread and comment, why. */
    record Note(UUID account, Id thread, Id comment, CommentEventKind kind) {
    }

    @Inject
    Pool pool;

    @Inject
    DocumentEvents events;

    /**
     * Looks up the threads and comments the change names and applies the role rule
     * ({@link CommentRules}): {@code ROLE_INSUFFICIENT} when the caller may not make it.
     */
    public Uni<Checked> check(Pusher pusher, UUID documentId, List<CommentOp> ops) {
        if (ops.isEmpty()) {
            return Uni.createFrom().item(NOTHING);
        }
        List<Id> targets = new ArrayList<>();
        List<Id> elements = new ArrayList<>();
        for (CommentOp op : ops) {
            switch (op) {
                case NodeOp node -> targets.add(node.target());
                case ThreadWrite write -> targets.add(write.target());
                case Resolve resolve -> targets.add(resolve.target());
                case ElementWrite write -> {
                    targets.add(write.target());
                    elements.add(write.element());
                }
                case NewComments added -> targets.add(added.target());
                case Reaction reaction -> targets.add(reaction.target());
                default -> {
                    // Creations name no existing node; typing and mentions ride on an ElementWrite.
                }
            }
        }
        return ids(THREADS, documentId, targets).chain(openers -> ids(AUTHORS, documentId, elements)
                .map(authors -> {
                    Known known = new Known(openers, authors);
                    CommentRules.check(pusher.role(), pusher.principal().accountId(), ops, known);
                    return new Checked(ops, known);
                }));
    }

    /** Runs a lookup of (counter, replica, account) rows by id; no query for no ids. */
    private Uni<Map<Id, UUID>> ids(String sql, UUID documentId, List<Id> ids) {
        Map<Id, UUID> found = new HashMap<>();
        return Multi.createFrom().iterable(ids.isEmpty() ? List.<List<Id>>of() : List.of(ids))
                .onItem().transformToUniAndConcatenate(all -> pool.preparedQuery(sql).execute(Tuple.of(documentId,
                        counters(all), replicas(all))))
                .onItem().transformToIterable(rows -> rows)
                .invoke(row -> found.put(new Id(row.getLong(0), row.getLong(1)), row.getUUID(2)))
                .collect().last()
                .map(ignored -> found);
    }

    /**
     * Records what an accepted change did to comments and pushes the notifications it caused. Ops on a
     * node that is not a known thread (an editor's no-op) are skipped.
     */
    public Uni<Void> index(Pusher pusher, UUID documentId, long serverSeq, Checked checked) {
        if (checked.ops().isEmpty()) {
            return Uni.createFrom().voidItem();
        }
        Map<Id, UUID> threads = new HashMap<>(checked.known().openers());
        UUID author = pusher.principal().accountId();
        return Multi.createFrom().iterable(checked.ops())
                .onItem().transformToUniAndConcatenate(op -> apply(documentId, serverSeq, author, threads, op))
                .onItem().transformToIterable(notes -> notes)
                .onItem().transformToUniAndConcatenate(note -> events.publishTo(documentId, note.account(), DocumentEvent
                        .newBuilder().setComment(CommentEvent.newBuilder()
                                .setThread(note.thread().opId())
                                .setComment(note.comment().elementId())
                                .setAuthor(pusher.author())
                                .setKind(note.kind()))
                        .build()))
                .collect().last()
                .replaceWithVoid();
    }

    private Uni<List<Note>> apply(UUID documentId, long serverSeq, UUID author, Map<Id, UUID> threads, CommentOp op) {
        return switch (op) {
            case CreateThread create -> {
                threads.put(create.thread(), author);
                yield pool.preparedQuery(INSERT_THREAD).execute(Tuple.of(documentId, create.thread().counter(),
                        create.thread().replica(), author, serverSeq)).replaceWith(List.<Note>of());
            }
            case NewComments added when threads.containsKey(added.target()) -> comments(documentId, serverSeq, author,
                    added);
            case Typed typed when threads.containsKey(typed.target()) -> pool.preparedQuery(PREVIEW).execute(Tuple.of(
                    documentId, typed.element().counter(), typed.element().replica(), preview(typed.chars())))
                    .replaceWith(List.<Note>of());
            case Mentioned mentioned when threads.containsKey(mentioned.target()) -> mentions(documentId, author,
                    mentioned.target(), mentioned.element(), mentioned.mentions());
            case Resolve resolve when threads.containsKey(resolve.target()) -> pool.preparedQuery(RESOLVE)
                    .execute(Tuple.from(new Object[] {documentId, resolve.target().counter(), resolve.target().replica(),
                            resolve.resolved(), resolve.op().counter(), resolve.op().replica(), author}))
                    .map(rows -> notes(rows, resolve.target(), CommentEventKind.COMMENT_EVENT_KIND_RESOLVED));
            case ElementWrite write when write.deleted() != null && threads.containsKey(write.target()) -> pool
                    .preparedQuery(DELETE).execute(Tuple.from(new Object[] {documentId, write.element().counter(),
                            write.element().replica(), write.deleted(), write.op().counter(), write.op().replica()}))
                    .replaceWith(List.<Note>of());
            default -> Uni.createFrom().item(List.<Note>of());
        };
    }

    /** Inserts new comments; the ones actually new notify mentions and the thread's earlier participants. */
    private Uni<List<Note>> comments(UUID documentId, long serverSeq, UUID author, NewComments added) {
        Id thread = added.target();
        return pool.preparedQuery(INSERT_COMMENTS).execute(Tuple.from(new Object[] {documentId, thread.counter(),
                thread.replica(), author, serverSeq, counters(added.elements()), replicas(added.elements())}))
                .chain(rows -> {
                    List<Id> fresh = new ArrayList<>();
                    rows.forEach(row -> fresh.add(new Id(row.getLong(0), row.getLong(1))));
                    Uni<List<Note>> replies = pool.preparedQuery(REPLIES).execute(Tuple.from(new Object[] {documentId,
                            thread.counter(), thread.replica(), author, counters(fresh), replicas(fresh)}))
                            .map(inserted -> notes(inserted, thread, CommentEventKind.COMMENT_EVENT_KIND_REPLY));
                    List<Uni<List<Note>>> all = new ArrayList<>();
                    all.add(replies);
                    for (Id element : fresh) {
                        // The role rule made every new comment name its author, so each has its values.
                        List<String> named = added.comments().get(added.elements().indexOf(element)).getMentionsList();
                        all.add(mentions(documentId, author, thread, element, named));
                    }
                    return Multi.createFrom().iterable(all).onItem().transformToUniAndConcatenate(uni -> uni)
                            .onItem().transformToIterable(notes -> notes).collect().asList();
                });
    }

    private Uni<List<Note>> mentions(UUID documentId, UUID author, Id thread, Id element, List<String> named) {
        return pool.preparedQuery(MENTIONS).execute(Tuple.from(new Object[] {documentId, thread.counter(),
                thread.replica(), element.counter(), element.replica(), author, named.toArray(String[]::new)}))
                .map(rows -> notes(rows, thread, CommentEventKind.COMMENT_EVENT_KIND_MENTION));
    }

    /** Notifications from rows of (account, comment counter, comment replica). */
    static List<Note> notes(RowSet<Row> rows, Id thread, CommentEventKind kind) {
        List<Note> notes = new ArrayList<>();
        rows.forEach(row -> notes.add(new Note(row.getUUID(0), thread, new Id(row.getLong(1), row.getLong(2)), kind)));
        return notes;
    }

    static String preview(String chars) {
        return chars.codePoints().limit(PREVIEW_CHARS)
                .collect(StringBuilder::new, StringBuilder::appendCodePoint, StringBuilder::append).toString();
    }

    static Long[] counters(List<Id> ids) {
        return ids.stream().map(Id::counter).toArray(Long[]::new);
    }

    static Long[] replicas(List<Id> ids) {
        return ids.stream().map(Id::replica).toArray(Long[]::new);
    }
}
