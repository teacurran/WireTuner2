package com.villagecompute.wiretuner.api.observability;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Supplier;

import io.micrometer.core.instrument.DistributionSummary;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Tags;
import io.micrometer.core.instrument.Timer;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The WireTuner metrics of docs/spec/server.adoc (Observability), exported by Micrometer's Prometheus
 * registry on {@code /q/metrics} beside Quarkus's own per-RPC gRPC metrics
 * ({@code grpc_server_processing_duration_seconds} and friends, one series per service and method).
 * Per-document series carry a {@code document} tag; the gauges of a document are registered with its
 * first subscription on this node and removed with its last, so an idle document costs nothing.
 */
@ApplicationScoped
public class WtMetrics {

    static final String DOCUMENT = "document";
    static final String SUBSCRIPTIONS = "wt.subscriptions.open";
    static final String STABLE_LAG = "wt.stable.lag.seq";

    @Inject
    MeterRegistry registry;

    private final Map<UUID, AtomicInteger> subscriptions = new ConcurrentHashMap<>();
    private final Map<UUID, AtomicLong> stableLags = new ConcurrentHashMap<>();

    /** Registers the in-flight push gauge over the queue's size. */
    public void pushInflight(Supplier<Number> active) {
        registry.gauge("wt.push.inflight", Tags.empty(), active, s -> s.get().doubleValue());
    }

    /** A change was accepted into the document's log. */
    public void accepted(UUID document) {
        registry.counter("wt.changes.accepted", DOCUMENT, document.toString()).increment();
    }

    /** A push arrived ahead of its predecessor. */
    public void seqGap() {
        registry.counter("wt.seq.gap").increment();
    }

    /** A call was refused by the rate limiter. */
    public void rateLimited() {
        registry.counter("wt.rate.limited").increment();
    }

    /** One accepted change's ingest time, from the call's turn in its replica's queue to the commit. */
    public void ingest(long nanos) {
        Timer.builder("wt.ingest").publishPercentileHistogram().register(registry).record(nanos, TimeUnit.NANOSECONDS);
    }

    /** One search query's time. */
    public void search(long nanos) {
        Timer.builder("wt.search").publishPercentileHistogram().register(registry).record(nanos, TimeUnit.NANOSECONDS);
    }

    /** The encoded size of one bulk upload ({@code PushChanges}) into the document. */
    public void backlog(UUID document, long bytes) {
        DistributionSummary.builder("wt.backlog").baseUnit("bytes").tag(DOCUMENT, document.toString())
                .register(registry).record(bytes);
    }

    /** A subscription opened on the document. */
    public void subscribed(UUID document) {
        subscriptions.computeIfAbsent(document, d -> registry.gauge(SUBSCRIPTIONS, Tags.of(DOCUMENT, d.toString()),
                new AtomicInteger())).incrementAndGet();
    }

    /** A subscription on the document ended; the last one removes the document's gauges. */
    public void unsubscribed(UUID document) {
        subscriptions.computeIfPresent(document, (d, open) -> {
            if (open.decrementAndGet() > 0) {
                return open;
            }
            remove(SUBSCRIPTIONS, d);
            if (stableLags.remove(d) != null) {
                remove(STABLE_LAG, d);
            }
            return null;
        });
    }

    /** The document's GC health after an Ack: head minus stable. */
    public void stableLag(UUID document, long head, long stable) {
        stableLags.computeIfAbsent(document, d -> registry.gauge(STABLE_LAG, Tags.of(DOCUMENT, d.toString()),
                new AtomicLong())).set(head - stable);
    }

    private void remove(String name, UUID document) {
        registry.find(name).tag(DOCUMENT, document.toString()).meters().forEach(registry::remove);
    }
}
