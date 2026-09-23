package com.villagecompute.wiretuner.api.persistence;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Blobs by sha256 (hex). */
@ApplicationScoped
public class BlobRepository implements PanacheRepositoryBase<Blob, String> {

    /**
     * Records a stored blob unless a row for the hash exists already (two uploads of the same
     * content may finish together; the first row wins and keeps its tag and time). Returns the row.
     */
    public Uni<Blob> insertIfAbsent(String sha256, long size, String mediaType, String storageKey, String tag) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO blob (sha256, size_bytes, media_type, storage_key, tag)
                        VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT (sha256) DO NOTHING
                        """)
                .setParameter(1, sha256)
                .setParameter(2, size)
                .setParameter(3, mediaType)
                .setParameter(4, storageKey)
                .setParameter(5, tag)
                .executeUpdate())
                .chain(() -> findById(sha256));
    }
}
