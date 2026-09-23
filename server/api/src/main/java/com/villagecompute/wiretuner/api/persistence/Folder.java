package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** A folder in a space (an account XOR a team); folders carry no roles of their own. */
@Entity
@Table(name = "folder")
public class Folder {

    @Id
    public UUID id;

    @Column(name = "owner_account_id")
    public UUID ownerAccountId;

    @Column(name = "team_id")
    public UUID teamId;

    /** The parent folder; null = the space's root. */
    @Column(name = "parent_folder_id")
    public UUID parentFolderId;

    @Column(nullable = false)
    public String name;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();
}
