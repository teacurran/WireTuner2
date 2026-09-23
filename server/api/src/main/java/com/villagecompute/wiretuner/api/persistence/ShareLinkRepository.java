package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Share links by token hash, and the links an account has used on a document. */
@ApplicationScoped
public class ShareLinkRepository implements PanacheRepositoryBase<ShareLink, UUID> {

    public Uni<ShareLink> findByTokenHash(String tokenHash) {
        return find("tokenHash", tokenHash).firstResult();
    }

    /** Every link on the document the account has opened, live or not; the caller filters. */
    public Uni<List<ShareLink>> listUsedBy(UUID documentId, UUID accountId) {
        return list("select l from ShareLink l, ShareLinkUse u"
                + " where u.id.shareLinkId = l.id and l.documentId = ?1 and u.id.accountId = ?2"
                + " order by l.createdAt", documentId, accountId);
    }
}
