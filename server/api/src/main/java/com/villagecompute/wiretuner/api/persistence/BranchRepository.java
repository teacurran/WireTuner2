package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * {@code branch} rows (SRV-011; branches.adoc, Data model), plain SQL in the caller's reactive
 * session: a branch row is read with its document's head and the last change's author and time,
 * which no entity mapping would give in one query.
 */
@ApplicationScoped
public class BranchRepository {

    /** A branch as {@code BranchService} reports it; times are epoch microseconds. */
    public record BranchRow(UUID branchId, UUID parentId, String name, long forkSeq, long mergedBranchSeq,
            long mergedParentSeq, String state, String createdBy, long createdAtMicros, long headSeq,
            UUID lastAuthorId, String lastAuthorName, Long lastChangeAtMicros) {
    }

    static final String COLUMNS = """
            b.document_id, b.parent_document_id, b.name, b.fork_seq, b.merged_branch_seq, b.merged_parent_seq,
            b.state, coalesce(cast(b.created_by_account_id AS text), ''), cast(extract(epoch FROM b.created_at) * 1000000 AS bigint), d.head_seq,
            l.account_id, l.display_name, cast(extract(epoch FROM l.wall_time) * 1000000 AS bigint)
            FROM branch b JOIN document d ON d.id = b.document_id
            LEFT JOIN LATERAL (
                SELECT r.account_id, a.display_name, c.wall_time FROM change_log c
                LEFT JOIN replica r ON r.document_id = c.document_id AND r.replica_id = c.replica_id
                LEFT JOIN account a ON a.id = r.account_id
                WHERE c.document_id = b.document_id ORDER BY c.server_seq DESC LIMIT 1) l ON true
            """;

    /** A select of {@link #COLUMNS}; callers add the join and filter. */
    static final String SELECT_ROWS = "SELECT " + COLUMNS;

    public Uni<Integer> insert(UUID branchId, UUID parentId, String name, long forkSeq, UUID createdBy) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO branch (document_id, parent_document_id, fork_seq, name, created_by_account_id)
                        VALUES (?1, ?2, ?3, ?4, ?5)
                        """)
                .setParameter(1, branchId)
                .setParameter(2, parentId)
                .setParameter(3, forkSeq)
                .setParameter(4, name)
                .setParameter(5, createdBy)
                .executeUpdate());
    }

    /** The branch, or null when the document is not a branch. */
    public Uni<BranchRow> find(UUID branchId) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery(SELECT_ROWS + " WHERE b.document_id = ?1", Object[].class)
                .setParameter(1, branchId)
                .getSingleResultOrNull())
                .map(row -> row == null ? null : toRow(row));
    }

    /** The parent of a branch; null when the document is not a branch. */
    public Uni<UUID> parentOf(UUID documentId) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery("SELECT parent_document_id FROM branch WHERE document_id = ?1", UUID.class)
                .setParameter(1, documentId)
                .getSingleResultOrNull());
    }

    /** The ids of a document's branches, trashed ones included. */
    public Uni<List<UUID>> branchesOf(UUID parentId) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery("SELECT document_id FROM branch WHERE parent_document_id = ?1 ORDER BY document_id",
                        UUID.class)
                .setParameter(1, parentId)
                .getResultList());
    }

    /**
     * The parent's live (not trashed) branches, newest first, archived ones only when asked, after
     * the cursor ({@code afterMicros}, {@code afterId}; {@code Long.MAX_VALUE} for the first page).
     */
    public Uni<List<BranchRow>> list(UUID parentId, boolean includeArchived, long afterMicros, UUID afterId, int limit) {
        return Panache.getSession().chain(session -> session.createNativeQuery(SELECT_ROWS + """
                         WHERE b.parent_document_id = ?1 AND d.trashed_at IS NULL AND (?2 OR b.state <> 'archived')
                           AND (cast(extract(epoch FROM b.created_at) * 1000000 AS bigint), b.document_id) < (?3, ?4)
                         ORDER BY b.created_at DESC, b.document_id DESC LIMIT ?5
                        """, Object[].class)
                .setParameter(1, parentId)
                .setParameter(2, includeArchived)
                .setParameter(3, afterMicros)
                .setParameter(4, afterId)
                .setParameter(5, limit)
                .getResultList())
                .map(rows -> rows.stream().map(BranchRepository::toRow).toList());
    }

    /**
     * The live branches of the live documents of space {@code spaceId} that account {@code accountId}
     * can open (the library window, COLLAB-016), newest first, archived and merged ones only when
     * asked, after the cursor as {@link #list}.
     */
    public Uni<List<BranchRow>> listInSpace(UUID accountId, UUID spaceId, boolean includeArchived, long afterMicros,
            UUID afterId, int limit) {
        return Panache.getSession().chain(session -> session.createNativeQuery(SELECT_ROWS
                        + " JOIN document p ON p.id = b.parent_document_id"
                        + " WHERE (p.owner_account_id = ?2 OR p.team_id = ?2) AND p.trashed_at IS NULL AND d.trashed_at IS NULL"
                        + " AND (?3 OR b.state <> 'archived') AND " + LibraryRepository.PARENT_VISIBLE + """
                         AND (cast(extract(epoch FROM b.created_at) * 1000000 AS bigint), b.document_id) < (?4, ?5)
                         ORDER BY b.created_at DESC, b.document_id DESC LIMIT ?6
                        """, Object[].class)
                .setParameter(1, accountId)
                .setParameter(2, spaceId)
                .setParameter(3, includeArchived)
                .setParameter(4, afterMicros)
                .setParameter(5, afterId)
                .setParameter(6, limit)
                .getResultList())
                .map(rows -> rows.stream().map(BranchRepository::toRow).toList());
    }

    public Uni<Integer> rename(UUID branchId, String name) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery("UPDATE branch SET name = ?2 WHERE document_id = ?1")
                .setParameter(1, branchId)
                .setParameter(2, name)
                .executeUpdate());
    }

    public Uni<Integer> setState(UUID branchId, String state) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery("UPDATE branch SET state = ?2 WHERE document_id = ?1")
                .setParameter(1, branchId)
                .setParameter(2, state)
                .executeUpdate());
    }

    /** Records a merge: the branch seq replayed through, the parent seq it landed at, and the resulting state. */
    public Uni<Integer> merged(UUID branchId, long branchSeq, long parentSeq, String state) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        UPDATE branch SET merged_branch_seq = ?2, merged_parent_seq = ?3, state = ?4, merged_at = now()
                        WHERE document_id = ?1
                        """)
                .setParameter(1, branchId)
                .setParameter(2, branchSeq)
                .setParameter(3, parentSeq)
                .setParameter(4, state)
                .executeUpdate());
    }

    private static BranchRow toRow(Object[] row) {
        return new BranchRow((UUID) row[0], (UUID) row[1], (String) row[2], ((Number) row[3]).longValue(),
                ((Number) row[4]).longValue(), ((Number) row[5]).longValue(), (String) row[6], (String) row[7],
                ((Number) row[8]).longValue(), ((Number) row[9]).longValue(), (UUID) row[10], (String) row[11],
                row[12] == null ? null : ((Number) row[12]).longValue());
    }
}
