package com.villagecompute.wiretuner.api.sync;

import java.util.UUID;

import com.villagecompute.wiretuner.api.persistence.AccountRepository;
import com.villagecompute.wiretuner.sync.v1.Participant;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * A person as collaborators see them ({@code sync.v1.Participant}): the account id and its display
 * name at the time of sending. Runs on the caller's reactive session. The role is filled only in
 * presence, where it is the participant's role on the document; a change's author and an event's
 * actor carry none.
 */
@ApplicationScoped
public class Participants {

    @Inject
    AccountRepository accounts;

    public Uni<Participant> of(UUID accountId) {
        return accounts.findById(accountId).map(account -> Participant.newBuilder()
                .setUserId(accountId.toString())
                .setDisplayName(account.displayName)
                .build());
    }
}
