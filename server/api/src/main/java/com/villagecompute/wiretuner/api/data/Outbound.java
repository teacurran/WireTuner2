package com.villagecompute.wiretuner.api.data;

import java.net.URI;
import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.observability.WtMetrics;

import io.grpc.Status;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The guards every upstream request of the data service passes, in order (data-merge.adoc, Server):
 * the host is in the scope's allowlist ({@code HOST_NOT_ALLOWED} with the team's admins otherwise,
 * before anything connects); a credential goes only to its own host; one token from the rate limits;
 * the credential's header; then {@link Egress} with its SSRF guard. Also the start and end of a call:
 * the editor check, the concurrency caps, and the audit row and metrics written when it ends.
 */
@ApplicationScoped
public class Outbound {

    private static final Logger LOG = Logger.getLogger(Outbound.class);

    static final String OK = "OK";
    static final String CANCELLED = "CANCELLED";

    @Inject
    Scopes scopes;

    @Inject
    AllowedHostRepository hosts;

    @Inject
    DataLimits limits;

    @Inject
    CredentialVault vault;

    @Inject
    Egress egress;

    @Inject
    FetchAuditRepository audit;

    @Inject
    WtMetrics metrics;

    /** An editor's call on the document, admitted under the concurrency caps. */
    Uni<Run> start(UUID documentId, String kind) {
        return Panache.withTransaction(() -> scopes.document(documentId))
                .map(caller -> {
                    Run run = new Run(caller, documentId, kind);
                    run.lease = limits.admit(caller.scope(), caller.accountId());
                    return run;
                });
    }

    /** Opens the named credential of the run's scope into the run; nothing for an empty name. */
    Uni<Void> credential(Run run, String name) {
        if (name.isEmpty()) {
            return Uni.createFrom().voidItem();
        }
        return vault.open(run.scope(), name).invoke(opened -> run.credential = opened).replaceWithVoid();
    }

    /** One upstream request through every guard. */
    Uni<Egress.Reply> send(Run run, String method, URI url, Map<String, String> headers, byte[] body, Duration timeout,
            long cap) {
        String key = HostNames.key(url);
        if (run.host.isEmpty()) {
            run.host = key;
            run.path = url.getRawPath().isEmpty() ? "/" : url.getRawPath();
        }
        return hosts.contains(run.scope(), key).chain(allowed -> {
            if (!allowed) {
                return run.scope().isTeam()
                        ? scopes.adminNames(run.scope().teamId()).chain(admins -> Uni.createFrom()
                                .<Egress.Reply>failure(StatusExceptions.hostNotAllowed(key, admins)))
                        : Uni.createFrom().failure(StatusExceptions.hostNotAllowed(key));
            }
            CredentialVault.Opened credential = run.credential;
            if (credential != null && !credential.stored().host().equals(key)) {
                return Uni.createFrom().failure(StatusExceptions.hostRefused(key, "the credential " + credential.stored().name()
                        + " is only sent to " + credential.stored().host()));
            }
            Uni<Map<String, String>> withCredential = credential == null ? Uni.createFrom().item(headers)
                    : vault.header(run.scope(), credential, run.pins).map(header -> {
                        Map<String, String> all = new LinkedHashMap<>(headers);
                        all.put(header.getKey(), header.getValue());
                        return all;
                    });
            return limits.take(run.scope(), run.caller.accountId())
                    .chain(() -> withCredential)
                    .chain(all -> egress.send(new Egress.Request(method, url, all, body, timeout, cap), run.pins))
                    .invoke(reply -> {
                        run.pages++;
                        run.bytes += reply.body().length;
                    });
        });
    }

    /** The unary call, with its audit row written before it answers. */
    <T> Uni<T> audited(Run run, Uni<T> call) {
        return call.onItemOrFailure().call((item, failure) -> finish(run, failure, false))
                .onCancellation().call(() -> finish(run, null, true));
    }

    /** The stream, with its audit row written when it completes, fails or is cancelled. */
    <T> Multi<T> audited(Run run, Multi<T> call) {
        return call.onCompletion().call(() -> finish(run, null, false))
                .onFailure().call(failure -> finish(run, failure, false))
                .onCancellation().call(() -> finish(run, null, true));
    }

    /** Releases the run's caps and writes its audit row and metrics, once. */
    Uni<Void> finish(Run run, Throwable failure, boolean cancelled) {
        if (!run.finished.compareAndSet(false, true)) {
            return Uni.createFrom().voidItem();
        }
        run.lease.release();
        String status = cancelled ? CANCELLED : failure == null ? OK : status(failure);
        metrics.dataFetch(run.kind, status, run.bytes);
        FetchAuditRepository.Entry entry = new FetchAuditRepository.Entry(UUID.randomUUID(), run.scope(), run.documentId,
                run.sourceCounter, run.sourceReplica, run.caller.accountId(), null, run.host, run.path, run.kind,
                run.startedAt, Instant.now(), status, run.pages, run.records, run.bytes);
        return audit.insert(entry).onFailure().invoke(e -> LOG.warnf(e, "fetch audit row for %s not written", run.documentId))
                .onFailure().recoverWithNull();
    }

    /** An error's audit status: its WireTuner reason, else its gRPC code. */
    static String status(Throwable failure) {
        return StatusExceptions.reasonOf(failure).orElseGet(() -> Status.fromThrowable(failure).getCode().name());
    }
}
