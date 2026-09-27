package com.villagecompute.wiretuner.api.persistence;

import java.util.Arrays;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * Team font libraries (TXT-002's server half, V14): {@code team_font} rows joined with their blobs,
 * and the team's catalog version. A removed font is not read. Native SQL in the caller's reactive
 * session, so an upload's blob row, font row and version move in one transaction.
 */
@ApplicationScoped
public class TeamFontRepository {

    /** A font of a team's library with its blob's size and storage key. */
    public record Font(String sha256, UUID teamId, String fileName, String mediaType, byte[] faces, UUID uploadedBy,
            long uploadedMillis, long size, String storageKey) {

        @Override
        public boolean equals(Object other) {
            return other instanceof Font(var thatSha256, var thatTeamId, var thatFileName, var thatMediaType,
                    var thatFaces, var thatUploadedBy, var thatUploadedMillis, var thatSize, var thatStorageKey)
                    && Objects.equals(sha256, thatSha256)
                    && Objects.equals(teamId, thatTeamId)
                    && Objects.equals(fileName, thatFileName)
                    && Objects.equals(mediaType, thatMediaType)
                    && Arrays.equals(faces, thatFaces)
                    && Objects.equals(uploadedBy, thatUploadedBy)
                    && uploadedMillis == thatUploadedMillis
                    && size == thatSize
                    && Objects.equals(storageKey, thatStorageKey);
        }

        @Override
        public int hashCode() {
            return Objects.hash(sha256, teamId, fileName, mediaType, Arrays.hashCode(faces), uploadedBy, uploadedMillis, size, storageKey);
        }

        /** {@inheritDoc} Byte arrays show as their length only (they can be large or secret). */
        @Override
        public String toString() {
            return "Font[sha256=" + sha256
                    + ", teamId=" + teamId
                    + ", fileName=" + fileName
                    + ", mediaType=" + mediaType
                    + ", faces=" + faces.length + " bytes"
                    + ", uploadedBy=" + uploadedBy
                    + ", uploadedMillis=" + uploadedMillis
                    + ", size=" + size
                    + ", storageKey=" + storageKey + "]";
        }
    }

    static final String SELECT = """
            SELECT f.sha256, f.team_id, f.file_name, f.media_type, f.faces, f.uploaded_by,
                   cast(extract(epoch FROM f.uploaded_at) * 1000 AS bigint), b.size_bytes, b.storage_key
            FROM team_font f JOIN blob b ON b.sha256 = f.sha256
            WHERE f.removed_at IS NULL AND f.team_id = ?1
            """;

    static final String UPSERT = """
            INSERT INTO team_font (team_id, sha256, file_name, media_type, family, faces, uploaded_by)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT (team_id, sha256) DO UPDATE SET file_name = EXCLUDED.file_name,
                media_type = EXCLUDED.media_type, family = EXCLUDED.family, faces = EXCLUDED.faces,
                uploaded_by = EXCLUDED.uploaded_by, uploaded_at = now(), removed_at = NULL
            WHERE team_font.removed_at IS NOT NULL
            """;

    /** The team's font {@code sha256} unless removed, or null. */
    public Uni<Font> live(UUID teamId, String sha256) {
        return Panache.getSession().chain(session -> session.createNativeQuery(SELECT + " AND f.sha256 = ?2", Object[].class)
                .setParameter(1, teamId)
                .setParameter(2, sha256)
                .getResultList())
                .map(rows -> rows.isEmpty() ? null : toFont(rows.get(0)));
    }

    /** One page of the team's fonts, by family, file name and hash. */
    public Uni<List<Font>> page(UUID teamId, int offset, int limit) {
        return Panache.getSession().chain(session -> session.createNativeQuery(SELECT
                + " ORDER BY f.family, f.file_name, f.sha256", Object[].class)
                .setParameter(1, teamId)
                .setFirstResult(offset)
                .setMaxResults(limit)
                .getResultList())
                .map(rows -> rows.stream().map(TeamFontRepository::toFont).toList());
    }

    /**
     * Adds the font to the team's library, or brings a removed one back with the new upload's
     * details; true when the library changed (false: the font was already there, untouched).
     */
    public Uni<Boolean> add(UUID teamId, String sha256, String fileName, String mediaType, String family, byte[] faces,
            UUID uploadedBy) {
        return Panache.getSession().chain(session -> session.createNativeQuery(UPSERT)
                .setParameter(1, teamId)
                .setParameter(2, sha256)
                .setParameter(3, fileName)
                .setParameter(4, mediaType)
                .setParameter(5, family)
                .setParameter(6, faces)
                .setParameter(7, uploadedBy)
                .executeUpdate())
                .map(rows -> rows > 0);
    }

    /** Removes the font from the team's library; true when it was there. */
    public Uni<Boolean> remove(UUID teamId, String sha256) {
        return Panache.getSession().chain(session -> session.createNativeQuery(
                "UPDATE team_font SET removed_at = now() WHERE team_id = ?1 AND sha256 = ?2 AND removed_at IS NULL")
                .setParameter(1, teamId)
                .setParameter(2, sha256)
                .executeUpdate())
                .map(rows -> rows > 0);
    }

    /** Moves the team's catalog version on. */
    public Uni<Void> bump(UUID teamId) {
        return Panache.getSession().chain(session -> session.createNativeQuery(
                "UPDATE team SET font_library_version = font_library_version + 1 WHERE id = ?1")
                .setParameter(1, teamId)
                .executeUpdate())
                .replaceWithVoid();
    }

    /** The team's catalog version. */
    public Uni<Long> version(UUID teamId) {
        return Panache.getSession().chain(session -> session.createNativeQuery(
                "SELECT font_library_version FROM team WHERE id = ?1", Object.class)
                .setParameter(1, teamId)
                .getSingleResult())
                .map(value -> ((Number) value).longValue());
    }

    static Font toFont(Object[] r) {
        return new Font((String) r[0], (UUID) r[1], (String) r[2], (String) r[3], (byte[]) r[4], (UUID) r[5],
                ((Number) r[6]).longValue(), ((Number) r[7]).longValue(), (String) r[8]);
    }
}
