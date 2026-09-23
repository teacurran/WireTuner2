package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** {@code cold_segment} rows, plain SQL: written by the compactor, read by fetch when a range is cold. */
@ApplicationScoped
public class ColdSegmentRepository {

    public record ColdSegment(UUID documentId, long fromSeq, long toSeq, String objectKey, long compressedSize) {
    }

    public Uni<Integer> insert(ColdSegment segment) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO cold_segment (document_id, from_seq, to_seq, object_key, compressed_size)
                        VALUES (?1, ?2, ?3, ?4, ?5)
                        """)
                .setParameter(1, segment.documentId())
                .setParameter(2, segment.fromSeq())
                .setParameter(3, segment.toSeq())
                .setParameter(4, segment.objectKey())
                .setParameter(5, segment.compressedSize())
                .executeUpdate());
    }

    public Uni<List<ColdSegment>> listForDocument(UUID documentId) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        SELECT document_id, from_seq, to_seq, object_key, compressed_size
                        FROM cold_segment WHERE document_id = ?1 ORDER BY from_seq
                        """, Object[].class)
                .setParameter(1, documentId)
                .getResultList())
                .map(rows -> rows.stream().map(ColdSegmentRepository::toSegment).toList());
    }

    private static ColdSegment toSegment(Object[] row) {
        return new ColdSegment((UUID) row[0], ((Number) row[1]).longValue(), ((Number) row[2]).longValue(),
                (String) row[3], ((Number) row[4]).longValue());
    }
}
