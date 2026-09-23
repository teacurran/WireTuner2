package com.villagecompute.wiretuner.api;

import java.util.function.Supplier;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.vertx.VertxContextSupport;
import io.smallrye.mutiny.Uni;

/** Runs reactive Panache work from a JUnit thread: on a Vert.x context, in one transaction, awaited. */
public final class Reactive {

    private Reactive() {
    }

    public static <T> T tx(Supplier<Uni<T>> work) {
        try {
            return VertxContextSupport.subscribeAndAwait(() -> Panache.withTransaction(work));
        } catch (Throwable t) {
            throw t instanceof RuntimeException re ? re : new IllegalStateException(t);
        }
    }
}
