package com.villagecompute.wiretuner.api.data;

import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.jobs.JobLocks;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Credential key rotation (DATA-005; server.adoc, Jobs): re-wraps the data key of every
 * {@code data_credential} row wrapped with another master key than the current one. Rotating is
 * putting a new key first in {@code WT_DATA_MASTER_KEY}, keeping the old one after it until this job
 * has run; the secrets' ciphertext is never touched. Runs at start-up (after a delay) and daily, and
 * is idempotent: with every row under the current key it does nothing.
 */
@ApplicationScoped
public class CredentialRotationJob {

    private static final Logger LOG = Logger.getLogger(CredentialRotationJob.class);

    static final int BATCH = 100;

    @Inject
    CredentialRepository credentials;

    @Inject
    MasterKeys keys;

    @Inject
    JobLocks locks;

    @Scheduled(identity = "credential-rotation", every = "${wt.jobs.credential-rotation.every:24h}",
            delayed = "${wt.jobs.credential-rotation.delay:2m}", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("credential-rotation", () -> rotate().replaceWithVoid()).replaceWithVoid();
    }

    /** Re-wraps rows in batches until none is left under another key; returns how many were re-wrapped. */
    Uni<Integer> rotate() {
        Envelope envelope = keys.envelope();
        return credentials.wrappedWithOtherKey(envelope.currentKeyId(), BATCH).chain(rows -> {
            if (rows.isEmpty()) {
                return Uni.createFrom().item(0);
            }
            Uni<Integer> done = Uni.createFrom().item(0);
            for (CredentialRepository.Rotatable row : rows) {
                done = done.chain(count -> credentials.rewrap(row.id(), row.sealed().keyId(), envelope.rewrap(row.sealed()))
                        .map(written -> count + written));
            }
            return done.invoke(count -> LOG.infof("re-wrapped %d credential keys under %s", count, envelope.currentKeyId()))
                    .chain(count -> rotate().map(more -> count + more));
        });
    }
}
