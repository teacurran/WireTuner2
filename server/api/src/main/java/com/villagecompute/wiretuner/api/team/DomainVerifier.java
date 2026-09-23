package com.villagecompute.wiretuner.api.team;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.grpc.CallerContext;

import io.smallrye.mutiny.Uni;
import io.vertx.core.dns.DnsClientOptions;
import io.vertx.mutiny.core.Vertx;
import io.vertx.mutiny.core.dns.DnsClient;

import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Workspace domain verification by DNS TXT record (docs/spec/security.adoc, Teams): the domain
 * counts once one of its TXT records is {@code wiretuner-verification=<token>}. Lookups go through
 * the non-blocking Vert.x DNS client to one configured resolver ({@code wt.dns.host}/{@code port},
 * a public resolver by default so a stale in-cluster cache cannot delay a verification). A lookup
 * that fails (no such domain, no answer, timeout) is simply "not verified".
 */
@ApplicationScoped
public class DomainVerifier {

    private static final Logger LOG = Logger.getLogger(DomainVerifier.class);

    static final String RECORD_PREFIX = "wiretuner-verification=";

    @Inject
    Vertx vertx;

    @ConfigProperty(name = "wt.dns.host")
    String host;

    @ConfigProperty(name = "wt.dns.port")
    int port;

    @ConfigProperty(name = "wt.dns.timeout-ms")
    long timeoutMs;

    DnsClient client;

    @PostConstruct
    void start() {
        client = vertx.createDnsClient(new DnsClientOptions().setHost(host).setPort(port).setQueryTimeout(timeoutMs));
    }

    /** The TXT record value the workspace publishes for a token. */
    static String record(String token) {
        return RECORD_PREFIX + token;
    }

    /** True when the domain publishes the token. */
    Uni<Boolean> verify(String domain, String token) {
        return client.resolveTXT(domain)
                .map(records -> records.contains(record(token)))
                .onFailure().recoverWithItem(failure -> {
                    LOG.debugf("TXT lookup for %s failed: %s", domain, failure.getMessage());
                    return false;
                })
                .emitOn(CallerContext.executor());
    }
}
