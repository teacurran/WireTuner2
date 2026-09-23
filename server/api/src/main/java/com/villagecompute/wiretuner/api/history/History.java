package com.villagecompute.wiretuner.api.history;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.sync.Protos;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.ChangeSummary;
import com.villagecompute.wiretuner.docs.v1.NamedNode;
import com.villagecompute.wiretuner.docs.v1.Session;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The history timeline and node history (SRV-011, COLLAB-020; history.adoc, Server): changes newest
 * first, grouped into sessions of one author (and one merged branch) with gaps under 10 minutes, and
 * the changes that named one node.
 *
 * <p>The log is read as one: the hot rows, then the cold segments below them. A cold change's time is
 * its own {@code wall_time_ms} (the hot log's server time is not in the segment), and its author and
 * merged branch come from the replica binding -- on the document, or, for a change a branch merge
 * replayed, on the branch ({@link #AUTHORS}). Node history reads the touched-node index
 * ({@code change_node}, {@link ChangeIndex}) and fetches only the changes it names. Each change row
 * carries up to 8 touched nodes with their names at the time ({@code node_name}; an unnamed node's
 * kind), and the registers it wrote ({@link ChangeIndex#attributes}). A query matches a change's
 * label, its author's name, or the name, at any time, of a node it touched.
 */
@ApplicationScoped
public class History {

    /** The session gap: a pause this long between one author's changes starts a new session. */
    static final long SESSION_GAP_MICROS = 10L * 60 * 1_000_000;

    /** A session of at most this many changes carries them without being expanded. */
    static final int SMALL_SESSION = 5;

    /** Touched nodes named per change row. */
    static final int NAMED_NODES = 8;

    /**
     * Hot rows, newest first. A replayed change's replica is bound on the branch it came from, not on
     * the parent, so its author is read there.
     */
    static final String ROWS = """
            SELECT c.server_seq, c.bytes, cast(extract(epoch FROM c.wall_time) * 1000000 AS bigint),
                   coalesce(cast(r.account_id AS text), ''), coalesce(a.display_name, ''),
                   coalesce(cast(c.merged_from_branch_id AS text), ''), coalesce(b.name, '')
            FROM change_log c
            LEFT JOIN replica r ON r.document_id = coalesce(c.merged_from_branch_id, c.document_id)
                                AND r.replica_id = c.replica_id
            LEFT JOIN account a ON a.id = r.account_id
            LEFT JOIN branch b ON b.document_id = c.merged_from_branch_id
            WHERE c.document_id = $1 AND c.server_seq < $2
            ORDER BY c.server_seq DESC LIMIT $3
            """;

    /** Hot rows by seq. */
    static final String ROWS_AT = ROWS.replace("c.server_seq < $2", "c.server_seq = ANY($2)");

    /** The cold segment with the newest changes below a seq. */
    static final String SEGMENT_BELOW = """
            SELECT object_key FROM cold_segment WHERE document_id = $1 AND from_seq < $2 ORDER BY from_seq DESC LIMIT 1
            """;

    /** The cold segments holding any of some seqs. */
    static final String SEGMENTS_AT = """
            SELECT DISTINCT s.object_key FROM cold_segment s JOIN unnest($2::bigint[]) AS q(seq)
                ON q.seq BETWEEN s.from_seq AND s.to_seq
            WHERE s.document_id = $1
            """;

    /**
     * Who each replica is: bound on the document, else on one of its branches (a replayed change), in
     * which case the branch is where the change was merged from.
     */
    static final String AUTHORS = """
            SELECT DISTINCT ON (r.replica_id) r.replica_id, coalesce(cast(r.account_id AS text), ''),
                   coalesce(a.display_name, ''),
                   CASE WHEN r.document_id = $1 THEN '' ELSE cast(r.document_id AS text) END, coalesce(b.name, '')
            FROM replica r
            LEFT JOIN account a ON a.id = r.account_id
            LEFT JOIN branch b ON b.document_id = r.document_id AND r.document_id <> $1
            WHERE r.replica_id = ANY($2)
              AND (r.document_id = $1 OR r.document_id IN (SELECT document_id FROM branch WHERE parent_document_id = $1))
            ORDER BY r.replica_id, r.document_id = $1 DESC
            """;

    static final String RETAINED = """
            SELECT LEAST(COALESCE((SELECT min(server_seq) FROM change_log WHERE document_id = $1), $2),
                         COALESCE((SELECT min(from_seq) FROM cold_segment WHERE document_id = $1), $2))
            """;

    /** The changes that named a node, newest first, below a seq. */
    static final String NODE_SEQS = """
            SELECT server_seq FROM change_node
            WHERE document_id = $1 AND node_replica = $2 AND node_counter = $3 AND server_seq < $4
            ORDER BY server_seq DESC LIMIT $5
            """;

    /**
     * The changes after $4 that named any of some nodes ($2 replicas, $3 counters), oldest first, at
     * most $5: the writes a page's changes may have lost to, or beaten.
     */
    static final String NODES_SEQS = """
            SELECT DISTINCT server_seq FROM change_node
            WHERE document_id = $1 AND (node_replica, node_counter) IN (SELECT * FROM unnest($2::bigint[], $3::bigint[]))
              AND server_seq > $4
            ORDER BY server_seq LIMIT $5
            """;

    /** Nodes whose name, at any time, contains the query. */
    static final String NAMED_LIKE = """
            SELECT DISTINCT node_replica, node_counter FROM node_name WHERE document_id = $1 AND strpos(lower(name), $2) > 0
            """;

    /** Each (node, seq)'s name and kind at that seq, in order; empty and 0 when never named. */
    static final String NAMES_AT = """
            SELECT coalesce(n.name, ''), coalesce(n.kind, 0)
            FROM unnest($2::bigint[], $3::bigint[], $4::bigint[]) WITH ORDINALITY AS p(r, c, s, i)
            LEFT JOIN LATERAL (SELECT name, kind FROM node_name
                               WHERE document_id = $1 AND node_replica = p.r AND node_counter = p.c AND server_seq <= p.s
                               ORDER BY server_seq DESC LIMIT 1) n ON true
            ORDER BY p.i
            """;

    /** One logged change as the timeline reads it. */
    record Logged(long serverSeq, Change change, long wallMicros, Participant author, String branchId, String branchName) {
    }

    /** A page of sessions (newest first) and the seq the next page starts below, 0 when this is the last. */
    public record Sessions(List<Session> sessions, long nextBefore) {
    }

    /** A page of node history: the changes, their authors in the same order, and where the next page starts (0: none). */
    public record NodeChanges(List<ChangeSummary> changes, List<Participant> authors, long nextBefore) {
    }

    /** Rows one ListHistory page reads at most; a session longer than that continues on the next page. */
    @ConfigProperty(name = "wt.history.scan", defaultValue = "5000")
    int scan;

    @Inject
    Pool pool;

    @Inject
    BlobStore store;

    /** The oldest retained server_seq, hot or cold ({@code head + 1} when there is none). */
    public Uni<Long> retainedFrom(UUID documentId, long head) {
        return pool.preparedQuery(RETAINED).execute(Tuple.of(documentId, head + 1)).map(rows -> rows.iterator().next().getLong(0));
    }

    /**
     * Up to {@code pageSize} sessions below {@code before}, of the changes that match {@code query}
     * (all when empty); the session starting at {@code expand} carries its changes whatever its size.
     */
    public Uni<Sessions> sessions(UUID documentId, long before, int pageSize, String query, long expand) {
        String needle = query.toLowerCase(Locale.ROOT);
        return namedLike(documentId, needle).chain(nodes -> below(documentId, before, scan).chain(rows -> {
            List<List<Logged>> groups = new ArrayList<>();
            List<Logged> group = null;
            Logged previous = null;
            for (Logged logged : rows) {
                if (!matches(logged, needle, nodes)) {
                    continue;
                }
                if (group == null || !sameSession(previous, logged)) {
                    group = new ArrayList<>();
                    groups.add(group);
                }
                group.add(logged);
                previous = logged;
            }
            boolean more = groups.size() > pageSize || rows.size() == scan;
            List<List<Logged>> shown = groups.size() > pageSize ? groups.subList(0, pageSize) : groups;
            List<Session> sessions = shown.stream().map(g -> session(g, expand)).toList();
            long next = more && !sessions.isEmpty() ? sessions.get(sessions.size() - 1).getFirstServerSeq() : 0;
            List<ChangeSummary> summaries = sessions.stream().flatMap(s -> s.getChangesList().stream()).toList();
            Set<Long> listed = new HashSet<>();
            summaries.forEach(summary -> listed.add(summary.getServerSeq()));
            List<Logged> page = shown.stream().flatMap(List::stream).filter(l -> listed.contains(l.serverSeq())).toList();
            return annotated(documentId, page, summaries).map(names -> new Sessions(sessions.stream()
                    .map(s -> s.toBuilder().clearChanges().addAllChanges(s.getChangesList().stream()
                            .map(c -> names.get(c.getServerSeq())).toList()).build())
                    .toList(), next));
        }));
    }

    /** Up to {@code pageSize} changes below {@code before} that named {@code node}, newest first, from the index. */
    public Uni<NodeChanges> nodeChanges(UUID documentId, OpId node, long before, int pageSize) {
        return pool.preparedQuery(NODE_SEQS).execute(Tuple.from(new Object[] {documentId, node.replica(), node.counter(),
                before, pageSize + 1})).chain(rows -> {
                    List<Long> seqs = new ArrayList<>();
                    rows.forEach(row -> seqs.add(row.getLong(0)));
                    List<Long> shown = seqs.size() > pageSize ? seqs.subList(0, pageSize) : seqs;
                    long next = seqs.size() > pageSize ? shown.get(shown.size() - 1) : 0;
                    return at(documentId, shown).chain(logged -> {
                        List<ChangeSummary> summaries = logged.stream().map(History::summary).toList();
                        return annotated(documentId, logged, summaries).map(names -> new NodeChanges(
                                summaries.stream().map(s -> names.get(s.getServerSeq())).toList(),
                                logged.stream().map(Logged::author).toList(), next));
                    });
                });
    }

    /** The nodes whose name, at any time, contains {@code needle}; none for an empty query. */
    private Uni<Set<OpId>> namedLike(UUID documentId, String needle) {
        if (needle.isEmpty()) {
            return Uni.createFrom().item(Set.of());
        }
        return pool.preparedQuery(NAMED_LIKE).execute(Tuple.of(documentId, needle)).map(rows -> {
            Set<OpId> nodes = new HashSet<>();
            rows.forEach(row -> nodes.add(new OpId(row.getLong(1), row.getLong(0))));
            return nodes;
        });
    }

    /** Up to {@code limit} changes below {@code before}, newest first: hot rows, then cold segments below them. */
    Uni<List<Logged>> below(UUID documentId, long before, int limit) {
        return pool.preparedQuery(ROWS).execute(Tuple.of(documentId, before, limit)).chain(rows -> {
            List<Logged> hot = new ArrayList<>(rows.rowCount());
            rows.forEach(row -> hot.add(logged(row)));
            if (hot.size() == limit) {
                return Uni.createFrom().item(hot);
            }
            long boundary = hot.isEmpty() ? before : hot.get(hot.size() - 1).serverSeq();
            return cold(documentId, boundary, limit - hot.size(), new ArrayList<>()).map(older -> {
                hot.addAll(older);
                return hot;
            });
        });
    }

    /** Cold changes below {@code before}, newest first, a segment at a time, added to {@code found} until it holds {@code want}. */
    private Uni<List<Logged>> cold(UUID documentId, long before, int want, List<Logged> found) {
        return pool.preparedQuery(SEGMENT_BELOW).execute(Tuple.of(documentId, before)).chain(rows -> {
            if (rows.rowCount() == 0) {
                return Uni.createFrom().item(found);
            }
            return segment(documentId, rows.iterator().next().getString(0)).chain(changes -> {
                List<Logged> older = new ArrayList<>(changes.stream().filter(c -> c.serverSeq() < before).toList());
                Collections.reverse(older);
                found.addAll(older.subList(0, Math.min(want - found.size(), older.size())));
                return found.size() == want ? Uni.createFrom().item(found)
                        : cold(documentId, changes.get(0).serverSeq(), want, found);
            });
        });
    }

    /** The changes at {@code seqs} (newest first), hot or cold; a seq neither holds is left out. */
    private Uni<List<Logged>> at(UUID documentId, List<Long> seqs) {
        Long[] wanted = seqs.toArray(Long[]::new);
        return pool.preparedQuery(ROWS_AT).execute(Tuple.of(documentId, wanted, wanted.length)).chain(rows -> {
            Map<Long, Logged> bySeq = new HashMap<>();
            rows.forEach(row -> {
                Logged logged = logged(row);
                bySeq.put(logged.serverSeq(), logged);
            });
            Long[] missing = seqs.stream().filter(seq -> !bySeq.containsKey(seq)).toArray(Long[]::new);
            Uni<Void> filled = missing.length == 0 ? Uni.createFrom().voidItem()
                    : pool.preparedQuery(SEGMENTS_AT).execute(Tuple.of(documentId, missing))
                            .onItem().transformToMulti(keys -> Multi.createFrom().iterable(keys))
                            .onItem().transformToUniAndConcatenate(key -> segment(documentId, key.getString(0)))
                            .invoke(changes -> changes.forEach(c -> bySeq.putIfAbsent(c.serverSeq(), c)))
                            .collect().last().replaceWithVoid();
            return filled.map(ignored -> seqs.stream().map(bySeq::get).filter(Objects::nonNull).toList());
        });
    }

    /** A cold segment's changes, oldest first, with their authors and merged branches. */
    private Uni<List<Logged>> segment(UUID documentId, String key) {
        return store.bytes(key).map(SegmentCodec::decode).chain(changes -> {
            Long[] replicas = changes.stream().map(c -> c.getChange().getReplica()).distinct().toArray(Long[]::new);
            return pool.preparedQuery(AUTHORS).execute(Tuple.of(documentId, replicas)).map(rows -> {
                Map<Long, Row> bound = new HashMap<>();
                rows.forEach(row -> bound.put(row.getLong(0), row));
                return changes.stream().map(change -> cold(change, bound.get(change.getChange().getReplica()))).toList();
            });
        });
    }

    /** A cold change as the timeline reads it; {@code binding} is its {@link #AUTHORS} row, null when unbound. */
    static Logged cold(SequencedChange sequenced, Row binding) {
        Change change = sequenced.getChange();
        Participant.Builder author = Participant.newBuilder();
        String branchId = "";
        String branchName = "";
        if (binding != null) {
            author.setUserId(binding.getString(1)).setDisplayName(binding.getString(2));
            branchId = binding.getString(3);
            branchName = binding.getString(4);
        }
        return new Logged(sequenced.getServerSeq(), change, change.getWallTimeMs() * 1000, author.build(), branchId,
                branchName);
    }

    /** {@code summaries} (of the changes {@code page}) by server_seq, named ({@link #named}) and with their lost attributes. */
    private Uni<Map<Long, ChangeSummary>> annotated(UUID documentId, List<Logged> page, List<ChangeSummary> summaries) {
        return named(documentId, summaries).chain(named -> lost(documentId, page).map(lost -> {
            lost.forEach((seq, attributes) -> named.put(seq, named.get(seq).toBuilder().addAllLostAttributes(attributes).build()));
            return named;
        }));
    }

    /**
     * The lost attributes of {@code page}'s changes ({@link LostWrites}), judged against the changes
     * that named the same nodes after the oldest causal past among them, at most a scan of them.
     */
    Uni<Map<Long, List<String>>> lost(UUID documentId, List<Logged> page) {
        Set<OpId> nodes = new LinkedHashSet<>();
        long base = Long.MAX_VALUE;
        for (Logged logged : page) {
            for (TouchedNodes.Named op : TouchedNodes.ops(logged.change())) {
                if (op.op().hasSet() || op.op().hasSetDeleted() || op.op().hasMove()) {
                    nodes.add(op.node());
                }
            }
            base = Math.min(base, logged.change().getBaseServerSeq());
        }
        if (nodes.isEmpty()) {
            return Uni.createFrom().item(Map.of());
        }
        List<LostWrites.Logged> changes = page.stream().map(l -> new LostWrites.Logged(l.serverSeq(), l.change())).toList();
        return pool.preparedQuery(NODES_SEQS).execute(Tuple.from(new Object[] {documentId,
                nodes.stream().map(OpId::replica).toArray(Long[]::new), nodes.stream().map(OpId::counter).toArray(Long[]::new),
                base, scan})).chain(rows -> {
                    List<Long> seqs = new ArrayList<>();
                    rows.forEach(row -> seqs.add(row.getLong(0)));
                    return at(documentId, seqs);
                }).map(context -> LostWrites.of(changes, context.stream()
                        .map(l -> new LostWrites.Logged(l.serverSeq(), l.change())).toList()));
    }

    /**
     * {@code summaries} by server_seq with every node's name at its change's seq: the name it was
     * given last, or its kind's when it has none.
     */
    private Uni<Map<Long, ChangeSummary>> named(UUID documentId, List<ChangeSummary> summaries) {
        List<Long> replicas = new ArrayList<>();
        List<Long> counters = new ArrayList<>();
        List<Long> seqs = new ArrayList<>();
        for (ChangeSummary summary : summaries) {
            for (NamedNode node : summary.getNodesList()) {
                replicas.add(node.getId().getReplica());
                counters.add(node.getId().getCounter());
                seqs.add(summary.getServerSeq());
            }
        }
        return pool.preparedQuery(NAMES_AT).execute(Tuple.of(documentId, replicas.toArray(Long[]::new),
                counters.toArray(Long[]::new), seqs.toArray(Long[]::new))).map(rows -> {
                    List<String> names = new ArrayList<>();
                    rows.forEach(row -> names.add(row.getString(0).isEmpty() ? ChangeIndex.kindName(row.getInteger(1))
                            : row.getString(0)));
                    Map<Long, ChangeSummary> bySeq = new HashMap<>();
                    int i = 0;
                    for (ChangeSummary summary : summaries) {
                        ChangeSummary.Builder named = summary.toBuilder();
                        for (int n = 0; n < summary.getNodesCount(); n++) {
                            named.setNodes(n, summary.getNodes(n).toBuilder().setName(names.get(i++)));
                        }
                        bySeq.put(summary.getServerSeq(), named.build());
                    }
                    return bySeq;
                });
    }

    private static Logged logged(Row row) {
        Participant author = Participant.newBuilder().setUserId(row.getString(3)).setDisplayName(row.getString(4)).build();
        return new Logged(row.getLong(0), Protos.change(row.getBuffer(1).getBytes()), row.getLong(2), author,
                row.getString(5), row.getString(6));
    }

    /** Whether the change's label or author name contains {@code needle}, or it touched one of {@code named}. */
    static boolean matches(Logged logged, String needle, Set<OpId> named) {
        return logged.change().getLabel().toLowerCase(Locale.ROOT).contains(needle)
                || logged.author().getDisplayName().toLowerCase(Locale.ROOT).contains(needle)
                || TouchedNodes.of(logged.change()).stream().anyMatch(named::contains);
    }

    /** Whether {@code older} continues the session {@code newer} is in (rows arrive newest first). */
    static boolean sameSession(Logged newer, Logged older) {
        return newer.author().getUserId().equals(older.author().getUserId())
                && Objects.equals(newer.branchId(), older.branchId())
                && newer.wallMicros() - older.wallMicros() < SESSION_GAP_MICROS;
    }

    /** A session of {@code group} (newest first). */
    static Session session(List<Logged> group, long expand) {
        Logged newest = group.get(0);
        Logged oldest = group.get(group.size() - 1);
        Set<OpId> nodes = new LinkedHashSet<>();
        group.forEach(logged -> nodes.addAll(TouchedNodes.of(logged.change())));
        Session.Builder session = Session.newBuilder()
                .setAuthor(newest.author())
                .setFirstServerSeq(oldest.serverSeq())
                .setLastServerSeq(newest.serverSeq())
                .setStartedAt(DocumentMessages.micros(oldest.wallMicros()))
                .setEndedAt(DocumentMessages.micros(newest.wallMicros()))
                .setChangeCount(group.size())
                .setNodeCount(nodes.size())
                .setMergedFromBranchId(newest.branchId())
                .setMergedFromBranchName(newest.branchName());
        if (group.size() <= SMALL_SESSION || oldest.serverSeq() == expand) {
            group.forEach(logged -> session.addChanges(summary(logged)));
        }
        return session.build();
    }

    /** One change's row: its label, time, op count, up to 8 of the nodes it named (names filled later) and its registers. */
    static ChangeSummary summary(Logged logged) {
        ChangeSummary.Builder summary = ChangeSummary.newBuilder()
                .setServerSeq(logged.serverSeq())
                .setLabel(logged.change().getLabel())
                .setWallTime(DocumentMessages.micros(logged.wallMicros()))
                .setOpCount(logged.change().getOpsCount())
                .addAllAttributes(ChangeIndex.attributes(logged.change()));
        TouchedNodes.of(logged.change()).stream().limit(NAMED_NODES)
                .forEach(node -> summary.addNodes(NamedNode.newBuilder().setId(node.toProto())));
        return summary.build();
    }
}
