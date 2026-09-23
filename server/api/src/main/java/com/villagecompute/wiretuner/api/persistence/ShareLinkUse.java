package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** Records that an account opened a share link, which makes the link's role part of its effective role. */
@Entity
@Table(name = "share_link_use")
public class ShareLinkUse {

    @EmbeddedId
    public ShareLinkUseId id;

    @Column(name = "used_at", nullable = false)
    public Instant usedAt = Instant.now();
}
