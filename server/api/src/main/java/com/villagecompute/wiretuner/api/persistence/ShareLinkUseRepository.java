package com.villagecompute.wiretuner.api.persistence;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;

import jakarta.enterprise.context.ApplicationScoped;

/** Which accounts opened which share links. */
@ApplicationScoped
public class ShareLinkUseRepository implements PanacheRepositoryBase<ShareLinkUse, ShareLinkUseId> {
}
