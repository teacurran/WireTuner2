package com.villagecompute.wiretuner.api.persistence;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * The library's reads (SRV-009), plain SQL: one row shape for every document the library shows,
 * with its owner and branch parent resolved in the same query, and the visibility rule that keeps
 * List and Search from ever returning a document the caller cannot open.
 *
 * <p>{@link #VISIBLE} is the SQL form of {@code DocumentRoles.effectiveRole(...) != NONE}: the
 * personal owner, an explicit {@code document_member} row (not a color-only {@code none} row), team
 * owner or admin, a team member of a live team, or a used share link that still grants. The service still asks
 * {@code DocumentRoles} for each returned row's {@code caller_role}, so the two cannot drift
 * without a test noticing.
 */
@ApplicationScoped
public class LibraryRepository {

    /** One document as the library shows it. Timestamps are epoch microseconds; nullable ones may be null. */
    public record DocumentRow(UUID id, UUID ownerAccountId, UUID teamId, UUID folderId, String name, String kind,
            int featureLevel, long headSeq, long createdAtMicros, long updatedAtMicros, Long trashedAtMicros,
            String thumbnailBlob, Long thumbnailAtMicros, boolean template, boolean library, UUID createdByAccountId,
            UUID documentOwnerId, UUID parentDocumentId) {

        /** The space: the owning account for a personal document, else the team. */
        public UUID spaceId() {
            return teamId == null ? ownerAccountId : teamId;
        }
    }

    /** What {@link #page} lists. */
    public enum Scope {
        FOLDER, TRASH, TEMPLATES, SHARED_WITH_ME
    }

    /**
     * One page request: the caller, the space (ignored for SHARED_WITH_ME), the folder for FOLDER
     * (null = root), and the keyset position after which to start ({@code afterName}, {@code afterId}).
     */
    public record PageQuery(UUID accountId, Scope scope, UUID spaceId, UUID folderId, String afterName, UUID afterId,
            int limit) {
    }

    /** A search hit: the document, its combined rank, its name, and whether the name itself matched. */
    public record Hit(UUID documentId, float rank, String name, boolean nameMatched) {
    }

    /** One line of a search record that matched, with its highlight from ts_headline. */
    public record MatchLine(String line, String headline, boolean substring, boolean word) {
    }

    static final String COLUMNS = """
            d.id, d.owner_account_id, d.team_id, d.folder_id, d.name, d.kind, d.feature_level, d.head_seq,
            cast(extract(epoch FROM d.created_at) * 1000000 AS bigint),
            cast(extract(epoch FROM d.updated_at) * 1000000 AS bigint),
            cast(extract(epoch FROM d.trashed_at) * 1000000 AS bigint),
            d.thumbnail_blob,
            cast(extract(epoch FROM d.thumbnail_at) * 1000000 AS bigint),
            d.is_template, d.is_library, d.created_by_account_id,
            coalesce(d.owner_account_id,
                     (SELECT m.account_id FROM document_member m WHERE m.document_id = d.id AND m.role = 'owner')),
            (SELECT b.parent_document_id FROM branch b WHERE b.document_id = d.id)
            """;

    /** Team owners and admins always; members while the team is live. {@code ?1} is the account. */
    static final String TEAM_ACCESS = """
            EXISTS (SELECT 1 FROM team_member tm JOIN team t ON t.id = tm.team_id
                    WHERE tm.team_id = d.team_id AND tm.account_id = ?1
                      AND (tm.role IN ('owner', 'admin') OR (tm.role = 'member' AND t.deleted_at IS NULL)))
            """;

    static final String NAMED_ACCESS = """
            (EXISTS (SELECT 1 FROM document_member dm WHERE dm.document_id = d.id AND dm.account_id = ?1
                     AND dm.role <> 'none')
             OR EXISTS (SELECT 1 FROM share_link l JOIN share_link_use u ON u.share_link_id = l.id
                        WHERE l.document_id = d.id AND u.account_id = ?1 AND l.revoked_at IS NULL
                          AND (NOT l.revoke_on_expiry OR l.expires_at IS NULL OR l.expires_at > now())))
            """;

    /** Documents account {@code ?1} can open. */
    static final String VISIBLE = "(d.owner_account_id = ?1 OR " + TEAM_ACCESS + " OR " + NAMED_ACCESS + ")";

    static final String NOT_BRANCH = "NOT EXISTS (SELECT 1 FROM branch br WHERE br.document_id = d.id)";

    /** An existing document. No visibility filter: callers check the role first, which also proves it exists. */
    public Uni<DocumentRow> row(UUID documentId) {
        return Panache.getSession().chain(session -> session
                .createNativeQuery("SELECT " + COLUMNS + " FROM document d WHERE d.id = ?1", Object[].class)
                .setParameter(1, documentId)
                .getSingleResult())
                .map(LibraryRepository::toRow);
    }

    /** One page of visible documents, by (name, id), at most {@code limit} rows. */
    public Uni<List<DocumentRow>> page(PageQuery query) {
        List<Object> params = new ArrayList<>();
        params.add(query.accountId());
        StringBuilder sql = new StringBuilder("SELECT ").append(COLUMNS).append(" FROM document d WHERE ")
                .append(NOT_BRANCH).append(" AND ");
        sql.append(switch (query.scope()) {
            case SHARED_WITH_ME -> "d.trashed_at IS NULL AND d.owner_account_id IS DISTINCT FROM ?1 AND NOT "
                    + TEAM_ACCESS + " AND " + NAMED_ACCESS;
            case TRASH -> inSpace(params, query.spaceId()) + " AND d.trashed_at IS NOT NULL AND " + VISIBLE;
            case TEMPLATES -> inSpace(params, query.spaceId()) + " AND d.trashed_at IS NULL AND d.is_template AND "
                    + VISIBLE;
            case FOLDER -> inSpace(params, query.spaceId()) + " AND d.trashed_at IS NULL AND "
                    + inFolder(params, query.folderId()) + " AND " + VISIBLE;
        });
        params.add(query.afterName());
        params.add(query.afterId());
        sql.append(" AND (d.name, d.id) > (cast(?").append(params.size() - 1).append(" AS text), cast(?")
                .append(params.size()).append(" AS uuid)) ORDER BY d.name, d.id LIMIT ").append(query.limit());
        return Panache.getSession().chain(session -> {
            var q = session.createNativeQuery(sql.toString(), Object[].class);
            for (int i = 0; i < params.size(); i++) {
                q.setParameter(i + 1, params.get(i));
            }
            return q.getResultList();
        }).map(rows -> rows.stream().map(LibraryRepository::toRow).toList());
    }

    private static String inFolder(List<Object> params, UUID folderId) {
        if (folderId == null) {
            return "d.folder_id IS NULL";
        }
        params.add(folderId);
        return "d.folder_id = ?" + params.size();
    }

    private static String inSpace(List<Object> params, UUID spaceId) {
        params.add(spaceId);
        int n = params.size();
        return "(d.owner_account_id = ?" + n + " OR d.team_id = ?" + n + ")";
    }

    /**
     * Visible live documents of the space matching the query (docs/spec/server.adoc, Search): the
     * live name or a names line by substring or word similarity (pg_trgm), the body or the names by
     * word ({@code websearch_to_tsquery('simple', ...)}). Ranked by the text ranks plus the best
     * word similarity, paged by (rank desc, id) after the given position.
     */
    public Uni<List<Hit>> search(UUID accountId, UUID spaceId, String query, float afterRank, UUID afterId, int limit) {
        String sql = """
                WITH q AS (SELECT websearch_to_tsquery('simple', cast(?3 AS text)) AS tsq,
                                  cast(?3 AS text) AS raw, cast(?4 AS text) AS pattern),
                hits AS (
                  SELECT d.id AS id, d.name AS name,
                         (d.name ILIKE q.pattern OR q.raw <%% d.name) AS name_matched,
                         cast(coalesce(ts_rank(s.body, q.tsq), 0) + coalesce(ts_rank(s.names_body, q.tsq), 0)
                              + greatest(word_similarity(q.raw, d.name), coalesce(word_similarity(q.raw, s.names), 0))
                              AS real) AS rank
                  FROM document d CROSS JOIN q LEFT JOIN document_search s ON s.document_id = d.id
                  WHERE (d.owner_account_id = ?2 OR d.team_id = ?2) AND d.trashed_at IS NULL
                    AND %s AND %s
                    AND (d.name ILIKE q.pattern OR q.raw <%% d.name
                         OR s.names ILIKE q.pattern OR q.raw <%% s.names
                         OR s.body @@ q.tsq OR s.names_body @@ q.tsq))
                SELECT id, rank, name, name_matched FROM hits
                WHERE rank < cast(?5 AS real) OR (rank = cast(?5 AS real) AND id > cast(?6 AS uuid))
                ORDER BY rank DESC, id LIMIT %d
                """.formatted(NOT_BRANCH, VISIBLE, limit);
        return Panache.getSession().chain(session -> session.createNativeQuery(sql, Object[].class)
                .setParameter(1, accountId)
                .setParameter(2, spaceId)
                .setParameter(3, query)
                .setParameter(4, "%" + likeEscape(query) + "%")
                .setParameter(5, afterRank)
                .setParameter(6, afterId)
                .getResultList())
                .map(rows -> rows.stream()
                        .map(r -> new Hit((UUID) r[0], ((Number) r[1]).floatValue(), (String) r[2], (Boolean) r[3]))
                        .toList());
    }

    /**
     * The lines of a document's search record (names, then body text) that match the query, each
     * with {@code ts_headline}'s highlight of its text after the field prefix, and whether it
     * matched as a substring and as words.
     */
    public Uni<List<MatchLine>> matchLines(UUID documentId, String query) {
        String sql = """
                WITH q AS (SELECT websearch_to_tsquery('simple', cast(?2 AS text)) AS tsq, lower(cast(?2 AS text)) AS raw),
                lines AS (
                  SELECT l.line, l.n, substr(l.line, strpos(l.line, ':') + 1) AS body
                  FROM document_search s,
                       unnest(string_to_array(s.names || E'\\n' || s.body_text, E'\\n')) WITH ORDINALITY AS l(line, n)
                  WHERE s.document_id = ?1 AND strpos(l.line, ':') > 0)
                SELECT lines.line,
                       ts_headline('simple', lines.body, q.tsq, 'StartSel=<b>, StopSel=</b>, MaxFragments=2'),
                       strpos(lower(lines.body), q.raw) > 0,
                       to_tsvector('simple', lines.body) @@ q.tsq
                FROM lines CROSS JOIN q
                WHERE strpos(lower(lines.body), q.raw) > 0 OR to_tsvector('simple', lines.body) @@ q.tsq
                ORDER BY lines.n
                """;
        return Panache.getSession().chain(session -> session.createNativeQuery(sql, Object[].class)
                .setParameter(1, documentId)
                .setParameter(2, query)
                .getResultList())
                .map(rows -> rows.stream()
                        .map(r -> new MatchLine((String) r[0], (String) r[1], (Boolean) r[2], (Boolean) r[3]))
                        .toList());
    }

    /** Escapes LIKE's wildcards (and its escape character) so a query matches literally. */
    static String likeEscape(String query) {
        return query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }

    static DocumentRow toRow(Object[] r) {
        return new DocumentRow((UUID) r[0], (UUID) r[1], (UUID) r[2], (UUID) r[3], (String) r[4], (String) r[5],
                ((Number) r[6]).intValue(), ((Number) r[7]).longValue(), ((Number) r[8]).longValue(),
                ((Number) r[9]).longValue(), longOrNull(r[10]), (String) r[11], longOrNull(r[12]), (Boolean) r[13],
                (Boolean) r[14], (UUID) r[15], (UUID) r[16], (UUID) r[17]);
    }

    static Long longOrNull(Object value) {
        return value == null ? null : ((Number) value).longValue();
    }
}
