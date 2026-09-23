package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Folders by id, and the subfolders of a folder (or of a space's root). */
@ApplicationScoped
public class FolderRepository implements PanacheRepositoryBase<Folder, UUID> {

    /** Subfolders of {@code parentId} (null = the root) in the space, by name. */
    public Uni<List<Folder>> listChildren(UUID spaceId, UUID parentId) {
        if (parentId == null) {
            return list("(ownerAccountId = ?1 or teamId = ?1) and parentFolderId is null", Sort.by("name", "id"), spaceId);
        }
        return list("parentFolderId = ?1", Sort.by("name", "id"), parentId);
    }
}
