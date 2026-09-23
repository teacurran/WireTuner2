package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Linked sign-in methods per account. */
@ApplicationScoped
public class AccountIdentityRepository implements PanacheRepositoryBase<AccountIdentity, AccountIdentityId> {

    public Uni<List<AccountIdentity>> listForAccount(UUID accountId) {
        return list("accountId", Sort.by("linkedAt"), accountId);
    }
}
