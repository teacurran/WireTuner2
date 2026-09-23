package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Accounts by id or Keycloak subject. */
@ApplicationScoped
public class AccountRepository implements PanacheRepositoryBase<Account, UUID> {

    public Uni<Account> findBySubject(String subject) {
        return find("subject", subject).firstResult();
    }

    /**
     * Inserts the account unless one with its subject exists: the first calls of a new person race to
     * create the row, and the loser's insert waits for the winner's and then does nothing. The number
     * of rows inserted.
     */
    public Uni<Integer> insertIfAbsent(Account account) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO account (id, subject, email, display_name, created_at)
                        VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT (subject) DO NOTHING
                        """)
                .setParameter(1, account.id)
                .setParameter(2, account.subject)
                .setParameter(3, account.email)
                .setParameter(4, account.displayName)
                .setParameter(5, account.createdAt)
                .executeUpdate());
    }
}
