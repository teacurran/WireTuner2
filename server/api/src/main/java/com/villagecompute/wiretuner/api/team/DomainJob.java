package com.villagecompute.wiretuner.api.team;

import java.time.Instant;

import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.jobs.JobLocks;
import com.villagecompute.wiretuner.api.persistence.WorkspaceDomain;
import com.villagecompute.wiretuner.api.persistence.WorkspaceDomainRepository;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The hourly Domains job (SEC-002; docs/spec/server.adoc, Jobs): re-verifies every workspace
 * domain's DNS TXT record through {@link DomainVerifier}. A claimed domain whose record has appeared
 * becomes verified, unless another team verified it first. A verified domain whose record is missing
 * (or whose lookup fails) {@value #MISSES_TO_DROP} runs in a row loses its verification, so one DNS
 * outage does not end auto-admit and require-SSO; a found record resets the count.
 */
@ApplicationScoped
public class DomainJob {

    private static final Logger LOG = Logger.getLogger(DomainJob.class);

    static final int MISSES_TO_DROP = 3;

    @Inject
    WorkspaceDomainRepository domains;

    @Inject
    DomainVerifier verifier;

    @Inject
    JobLocks locks;

    @Scheduled(identity = "domains", every = "${wt.jobs.domains.every:1h}", delayed = "${wt.jobs.domains.delay:1m}",
            concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("domains", this::reverify).replaceWithVoid();
    }

    /** Looks every domain up once, in one transaction. */
    Uni<Void> reverify() {
        return Panache.withTransaction(() -> domains.listAll()
                .flatMap(all -> Multi.createFrom().iterable(all)
                        .onItem().transformToUniAndConcatenate(this::check)
                        .collect().last()))
                .replaceWithVoid();
    }

    private Uni<Void> check(WorkspaceDomain domain) {
        String name = domain.id.domain();
        return verifier.verify(name, domain.verificationToken).chain(found -> {
            domain.checkedAt = Instant.now();
            if (!found) {
                return missed(domain);
            }
            domain.failedChecks = 0;
            if (domain.verifiedAt != null) {
                return Uni.createFrom().voidItem();
            }
            return domains.findVerified(name).invoke(other -> {
                if (other == null) {
                    domain.verifiedAt = domain.checkedAt;
                    LOG.infof("domain %s verified for team %s", name, domain.id.teamId());
                }
            }).replaceWithVoid();
        });
    }

    private static Uni<Void> missed(WorkspaceDomain domain) {
        if (domain.verifiedAt != null && ++domain.failedChecks >= MISSES_TO_DROP) {
            LOG.warnf("domain %s of team %s lost its verification: no TXT record in %d runs", domain.id.domain(),
                    domain.id.teamId(), domain.failedChecks);
            domain.verifiedAt = null;
            domain.failedChecks = 0;
        }
        return Uni.createFrom().voidItem();
    }
}
