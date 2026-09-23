package com.villagecompute.wiretuner.api.publish;

import java.nio.ByteBuffer;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.blob.BlobStore;

import io.quarkus.runtime.ShutdownEvent;
import io.quarkus.runtime.StartupEvent;
import io.smallrye.mutiny.Uni;
import io.vertx.core.http.HttpMethod;
import io.vertx.mutiny.core.Vertx;
import io.vertx.mutiny.core.buffer.Buffer;
import io.vertx.mutiny.core.http.HttpServer;
import io.vertx.mutiny.core.http.HttpServerRequest;
import io.vertx.mutiny.core.http.HttpServerResponse;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;

/**
 * The pub origin (WEB-012; publish-html.adoc, Server): a plain HTTP server of its own, on
 * {@code wt.publish.origin.host}:{@code wt.publish.origin.port}, behind the {@code pub.<host>} name --
 * a separate origin from the app and the API, so a published page can never read their state or call
 * the API with a viewer's credentials. It sets no cookies and reads none.
 *
 * <p>{@code GET /d/<document>/<path>} serves the file of the document's current publish, streamed from
 * object storage with the manifest's media type, {@code Cache-Control: private, max-age=0,
 * must-revalidate} and the blob hash as a strong {@code ETag} ({@code If-None-Match} answers 304);
 * the root serves {@code index.html}, {@code /d/<document>} redirects to it. Every response carries a
 * script-free {@code Content-Security-Policy} in a sandbox, {@code nosniff} and
 * {@code Referrer-Policy: no-referrer}. A path that is not a safe bundle path is 400; no current
 * publish, a trashed document or an unknown file is 404.
 *
 * <p>Access: a publish open to anyone with the link is served without authentication. A members-only
 * publish answers 403 for now: its sign-in hand-off (a session cookie on this origin after a redirect
 * through the API) needs the security review the page asks for and is deferred.
 */
@ApplicationScoped
public class PubOrigin {

    private static final Logger LOG = Logger.getLogger(PubOrigin.class);

    static final String CSP = "sandbox allow-same-origin; default-src 'self' data: blob:; script-src 'none'";
    static final String CACHE = "private, max-age=0, must-revalidate";

    static final String FILE = """
            SELECT f.sha256, f.media_type, b.size_bytes, b.storage_key, p.access
            FROM publish p JOIN document d ON d.id = p.document_id AND d.trashed_at IS NULL
            JOIN publish_file f ON f.publish_id = p.id AND f.path = $2
            JOIN blob b ON b.sha256 = f.sha256
            WHERE p.document_id = $1 AND p.is_current
            """;

    @ConfigProperty(name = "wt.publish.origin.host", defaultValue = "0.0.0.0")
    String host;

    @ConfigProperty(name = "wt.publish.origin.port", defaultValue = "8090")
    int port;

    @Inject
    Vertx vertx;

    @Inject
    Pool pool;

    @Inject
    BlobStore store;

    HttpServer server;

    void start(@Observes StartupEvent event) {
        server = vertx.createHttpServer().requestHandler(this::handle).listenAndAwait(port, host);
        LOG.infof("pub origin listening on %s:%d", host, server.actualPort());
    }

    void stop(@Observes ShutdownEvent event) {
        server.closeAndAwait();
    }

    void handle(HttpServerRequest request) {
        HttpServerResponse response = request.response();
        response.putHeader("Content-Security-Policy", CSP)
                .putHeader("X-Content-Type-Options", "nosniff")
                .putHeader("Referrer-Policy", "no-referrer");
        boolean head = request.method() == HttpMethod.HEAD;
        if (!head && request.method() != HttpMethod.GET) {
            response.putHeader("Allow", "GET, HEAD").setStatusCode(405).endAndForget();
            return;
        }
        PubPaths.Parsed parsed = PubPaths.parse(request.path());
        if (parsed.status() == PubPaths.MOVED) {
            response.putHeader("Location", request.path() + "/").setStatusCode(PubPaths.MOVED).endAndForget();
            return;
        }
        if (parsed.status() != PubPaths.OK) {
            response.setStatusCode(parsed.status()).endAndForget();
            return;
        }
        serve(request, response, parsed.document(), parsed.path(), head)
                .subscribe().with(ignored -> { }, failure -> failed(response, failure));
    }

    private Uni<Void> serve(HttpServerRequest request, HttpServerResponse response, UUID document, String path,
            boolean head) {
        return pool.preparedQuery(FILE).execute(Tuple.of(document, path)).chain(rows -> {
            if (rows.rowCount() == 0) {
                return response.setStatusCode(404).end();
            }
            Row row = rows.iterator().next();
            if (!PublishGrpcService.ANYONE.equals(row.getString(4))) {
                return response.setStatusCode(403).end("This link is for people with access to the document.");
            }
            String etag = "\"" + row.getString(0) + "\"";
            response.putHeader("ETag", etag).putHeader("Cache-Control", CACHE);
            if (etag.equals(request.getHeader("If-None-Match"))) {
                return response.setStatusCode(304).end();
            }
            response.putHeader("Content-Type", row.getString(1))
                    .putHeader("Content-Length", Long.toString(row.getLong(2)));
            if (head) {
                return response.end();
            }
            return store.get(row.getString(3))
                    .onItem().transformToUniAndConcatenate(chunk -> response.write(Buffer.buffer(bytes(chunk))))
                    .collect().last()
                    .chain(() -> response.end());
        });
    }

    /** A 500 when nothing was sent yet; a reset stream when the failure came mid-body. */
    private static void failed(HttpServerResponse response, Throwable failure) {
        LOG.warnf(failure, "serving a published file failed");
        Uni.createFrom().item(() -> response.setStatusCode(500)).chain(HttpServerResponse::end)
                .onFailure().invoke((Runnable) response::reset)
                .subscribe().with(LOG::trace, LOG::trace);
    }

    static byte[] bytes(ByteBuffer chunk) {
        byte[] out = new byte[chunk.remaining()];
        chunk.get(out);
        return out;
    }
}
