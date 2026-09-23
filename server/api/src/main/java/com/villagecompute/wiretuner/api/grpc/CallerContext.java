package com.villagecompute.wiretuner.api.grpc;

import java.util.concurrent.Executor;

import io.vertx.core.Context;
import io.vertx.core.Vertx;

/**
 * Hops back onto the calling Vert.x context. Clients with their own event loops (the S3 SDK's
 * Netty loop, the DNS client) complete elsewhere; the reactive Hibernate session a caller chains
 * onto belongs to the call's context, so results are re-emitted there.
 */
public final class CallerContext {

    private CallerContext() {
    }

    /** The current Vert.x context as an executor, or a direct executor when called outside one (plain tests). */
    public static Executor executor() {
        Context context = Vertx.currentContext();
        return context == null ? Runnable::run : command -> context.runOnContext(ignored -> command.run());
    }
}
