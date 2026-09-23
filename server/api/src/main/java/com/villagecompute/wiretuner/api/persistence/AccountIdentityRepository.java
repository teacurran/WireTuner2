package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
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

    /**
     * Links the identity unless it is linked already (pipelined first calls race to do this). The
     * number of rows inserted: 1, or 0 when another call linked it first.
     */
    public Uni<Integer> insertIfAbsent(AccountIdentity identity) {
        // Flush first: the account row the identity references may still be pending in the session.
        return Panache.getSession().chain(session -> session.flush().chain(() -> session.createNativeQuery("""
                        INSERT INTO account_identity (account_id, provider, provider_subject, email, email_verified,
                                                      is_relay, linked_at)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT (provider, provider_subject) DO NOTHING
                        """)
                .setParameter(1, identity.accountId)
                .setParameter(2, identity.id.provider())
                .setParameter(3, identity.id.providerSubject())
                .setParameter(4, identity.email)
                .setParameter(5, identity.emailVerified)
                .setParameter(6, identity.relay)
                .setParameter(7, identity.linkedAt)
                .executeUpdate()));
    }
}
