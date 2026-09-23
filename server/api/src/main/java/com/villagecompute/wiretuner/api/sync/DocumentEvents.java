package com.villagecompute.wiretuner.api.sync;

import java.util.UUID;
import java.util.function.Function;

import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Document events on live subscriptions ({@code ServerFrame.event}, docs/spec/sync-protocol.adoc):
 * what DocumentService (and later ShareService and BranchService) tells every session on a
 * document when something other than its content changes. Built inside the RPC's transaction,
 * published after it commits.
 */
@ApplicationScoped
public class DocumentEvents {

    @Inject
    Participants participants;

    @Inject
    SyncBus bus;

    /** The event with the acting account as its actor; runs on the caller's reactive session. */
    public Uni<DocumentEvent> event(UUID actor, Function<Participant, DocumentEvent> build) {
        return participants.of(actor).map(build);
    }

    /** Sends the event to every subscription on the document, on every node. */
    public Uni<Void> publish(UUID documentId, DocumentEvent event) {
        return bus.publish(documentId, ServerFrame.newBuilder().setEvent(event).build());
    }
}
