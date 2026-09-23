package com.villagecompute.wiretuner.api.persistence;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;

import jakarta.enterprise.context.ApplicationScoped;

/** Blobs by sha256 (hex). */
@ApplicationScoped
public class BlobRepository implements PanacheRepositoryBase<Blob, String> {
}
