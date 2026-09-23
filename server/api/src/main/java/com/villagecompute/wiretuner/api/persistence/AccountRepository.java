package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Accounts by id or Keycloak subject. */
@ApplicationScoped
public class AccountRepository implements PanacheRepositoryBase<Account, UUID> {

    public Uni<Account> findBySubject(String subject) {
        return find("subject", subject).firstResult();
    }
}
