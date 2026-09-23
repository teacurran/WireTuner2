package com.villagecompute.wiretuner.api.history;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.sync.Protos;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.ChangeSummary;
import com.villagecompute.wiretuner.docs.v1.NamedNode;
import com.villagecompute.wiretuner.docs.v1.Session;
import com.villagecompute.wiretuner.sync.v1.Participant;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The history timeline and node history from the retained hot log (SRV-011; history.adoc,
 * Specification): changes newest first, grouped into sessions of one author (and one merged branch)
 * with gaps under 10 minutes, and the changes that named one node. Only the hot log is read, so the
 * retention window ({@code retained_from_seq}) is its oldest row. As built, COLLAB-020's refinements
 * are not here: node names at the time and register attributes are left empty, a query matches
 * labels and author names only, and node history scans the log rather than an index.
 */
@ApplicationScoped
public class History {

    /** The session gap: a pause this long between one author's changes starts a new session. */
    static final long SESSION_GAP_MICROS = 10L * 60 * 1_000_000;

    /** A session of at most this many changes carries them without being expanded. */
    static final int SMALL_SESSION = 5;

    static final String ROWS = """
            SELECT c.server_seq, c.bytes, cast(extract(epoch FROM c.wall_time) * 1000000 AS bigint),
                   coalesce(cast(r.account_id AS text), ''), coalesce(a.display_name, ''),
                   coalesce(cast(c.merged_from_branch_id AS text), ''), coalesce(b.name, '')
            FROM change_log c
            LEFT JOIN replica r ON r.document_id = c.document_id AND r.replica_id = c.replica_id
            LEFT JOIN account a ON a.id = r.account_id
            LEFT JOIN branch b ON b.document_id = c.merged_from_branch_id
            WHERE c.document_id = $1 AND c.server_seq < $2
            ORDER BY c.server_seq DESC LIMIT $3
            """;

    static final String RETAINED = "SELECT COALESCE(min(server_seq), $2) FROM change_log WHERE document_id = $1";

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

    /** Rows one node-history query reads before looking further back. */
    @ConfigProperty(name = "wt.history.node-scan", defaultValue = "256")
    int nodeScan;

    @Inject
    Pool pool;

    /** The oldest retained server_seq ({@code head + 1} when the hot log is empty). */
    public Uni<Long> retainedFrom(UUID documentId, long head) {
        return pool.preparedQuery(RETAINED).execute(Tuple.of(documentId, head + 1)).map(rows -> rows.iterator().next().getLong(0));
    }

    /**
     * Up to {@code pageSize} sessions below {@code before}, of the changes whose label or author
     * matches {@code query} (all when empty); the session starting at {@code expand} carries its
     * changes whatever its size.
     */
    public Uni<Sessions> sessions(UUID documentId, long before, int pageSize, String query, long expand) {
        String needle = query.toLowerCase(Locale.ROOT);
        return pool.preparedQuery(ROWS).execute(Tuple.of(documentId, before, scan)).map(rows -> {
            List<List<Logged>> groups = new ArrayList<>();
            List<Logged> group = null;
            Logged previous = null;
            for (Row row : rows) {
                Logged logged = logged(row);
                if (!matches(logged, needle)) {
                    continue;
                }
                if (group == null || !sameSession(previous, logged)) {
                    group = new ArrayList<>();
                    groups.add(group);
                }
                group.add(logged);
                previous = logged;
            }
            boolean more = groups.size() > pageSize || rows.rowCount() == scan;
            List<List<Logged>> shown = groups.size() > pageSize ? groups.subList(0, pageSize) : groups;
            List<Session> sessions = shown.stream().map(g -> session(g, expand)).toList();
            long next = more && !sessions.isEmpty() ? sessions.get(sessions.size() - 1).getFirstServerSeq() : 0;
            return new Sessions(sessions, next);
        });
    }

    /** Up to {@code pageSize} changes below {@code before} that named {@code node}, newest first. */
    public Uni<NodeChanges> nodeChanges(UUID documentId, OpId node, long before, int pageSize) {
        return nodeChanges(documentId, node, before, pageSize, new NodeChanges(new ArrayList<>(), new ArrayList<>(), 0));
    }

    private Uni<NodeChanges> nodeChanges(UUID documentId, OpId node, long before, int pageSize, NodeChanges found) {
        return pool.preparedQuery(ROWS).execute(Tuple.of(documentId, before, nodeScan)).chain(rows -> {
            long last = before;
            for (Row row : rows) {
                Logged logged = logged(row);
                last = logged.serverSeq();
                if (TouchedNodes.of(logged.change()).contains(node)) {
                    found.changes().add(summary(logged));
                    found.authors().add(logged.author());
                    if (found.changes().size() == pageSize) {
                        return Uni.createFrom().item(new NodeChanges(found.changes(), found.authors(), last));
                    }
                }
            }
            return rows.rowCount() < nodeScan ? Uni.createFrom().item(found)
                    : nodeChanges(documentId, node, last, pageSize, found);
        });
    }

    private static Logged logged(Row row) {
        Participant author = Participant.newBuilder().setUserId(row.getString(3)).setDisplayName(row.getString(4)).build();
        return new Logged(row.getLong(0), Protos.change(row.getBuffer(1).getBytes()), row.getLong(2), author,
                row.getString(5), row.getString(6));
    }

    static boolean matches(Logged logged, String needle) {
        return logged.change().getLabel().toLowerCase(Locale.ROOT).contains(needle)
                || logged.author().getDisplayName().toLowerCase(Locale.ROOT).contains(needle);
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

    /** One change's row: its label, time, op count and up to 8 of the nodes it named (without names). */
    static ChangeSummary summary(Logged logged) {
        ChangeSummary.Builder summary = ChangeSummary.newBuilder()
                .setServerSeq(logged.serverSeq())
                .setLabel(logged.change().getLabel())
                .setWallTime(DocumentMessages.micros(logged.wallMicros()))
                .setOpCount(logged.change().getOpsCount());
        TouchedNodes.of(logged.change()).stream().limit(8)
                .forEach(node -> summary.addNodes(NamedNode.newBuilder().setId(node.toProto())));
        return summary.build();
    }
}
