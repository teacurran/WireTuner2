package com.villagecompute.wiretuner.api.jobs;

import java.util.function.Supplier;

import org.jboss.logging.Logger;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * One node per job (docs/spec/server.adoc, Jobs): a scheduled job runs while holding a Postgres
 * advisory lock named after it, taken with {@code pg_try_advisory_xact_lock} in a transaction of its
 * own that stays open for the run; a node that cannot take it skips the run.
 */
@ApplicationScoped
public class JobLocks {

    private static final Logger LOG = Logger.getLogger(JobLocks.class);

    static final String TRY_LOCK = "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))";

    @Inject
    Pool pool;

    /** Runs {@code work} under the job's lock; true when it ran, false when another node holds the lock. */
    public Uni<Boolean> exclusively(String job, Supplier<Uni<Void>> work) {
        return pool.withTransaction(connection -> connection.preparedQuery(TRY_LOCK).execute(Tuple.of("job:" + job))
                .chain(rows -> {
                    boolean held = rows.iterator().next().getBoolean(0);
                    LOG.debugf("job %s: lock %s", job, held ? "taken" : "held elsewhere, skipping");
                    return held ? work.get().replaceWith(true) : Uni.createFrom().item(false);
                }));
    }
}
