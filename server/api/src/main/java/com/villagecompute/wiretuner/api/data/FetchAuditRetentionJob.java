package com.villagecompute.wiretuner.api.data;

import java.time.Duration;
import java.time.Instant;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.jobs.JobLocks;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/** Fetch audit retention (DATA-008; server.adoc, Jobs): daily, drops audit rows that started over 90 days ago. */
@ApplicationScoped
public class FetchAuditRetentionJob {

    private static final Logger LOG = Logger.getLogger(FetchAuditRetentionJob.class);

    @ConfigProperty(name = "wt.data.audit-retention", defaultValue = "90D")
    Duration retention;

    @Inject
    FetchAuditRepository audit;

    @Inject
    JobLocks locks;

    @Scheduled(identity = "fetch-audit-retention", every = "${wt.jobs.fetch-audit.every:24h}",
            delayed = "${wt.jobs.fetch-audit.delay:5m}", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("fetch-audit-retention", () -> purge(Instant.now()).replaceWithVoid()).replaceWithVoid();
    }

    /** Deletes the rows older than the retention at {@code now}; returns how many. */
    Uni<Integer> purge(Instant now) {
        return audit.deleteStartedBefore(now.minus(retention))
                .invoke(count -> LOG.infof("dropped %d fetch audit rows older than %s", count, retention));
    }
}
