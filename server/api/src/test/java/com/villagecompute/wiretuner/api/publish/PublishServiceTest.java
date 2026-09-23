package com.villagecompute.wiretuner.api.publish;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.PerfReport;
import com.villagecompute.wiretuner.api.PerfTest;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.sync.SyncTestSupport;
import com.villagecompute.wiretuner.publish.v1.CreatePublishRequest;
import com.villagecompute.wiretuner.publish.v1.DeletePublishRequest;
import com.villagecompute.wiretuner.publish.v1.GetPublishRequest;
import com.villagecompute.wiretuner.publish.v1.GetPublishResponse;
import com.villagecompute.wiretuner.publish.v1.ListPublishesRequest;
import com.villagecompute.wiretuner.publish.v1.ListPublishesResponse;
import com.villagecompute.wiretuner.publish.v1.Publish;
import com.villagecompute.wiretuner.publish.v1.PublishAccess;
import com.villagecompute.wiretuner.publish.v1.PublishFile;
import com.villagecompute.wiretuner.publish.v1.PublishManifest;
import com.villagecompute.wiretuner.publish.v1.PublishServiceGrpc;
import com.villagecompute.wiretuner.publish.v1.SetPublishAccessRequest;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * WEB-011/012: PublishService's role, manifest, idempotency, access and rate rules, the pub origin's
 * serving, headers and refusals, and a 200-file bundle served to 100 concurrent viewers.
 */
@QuarkusTest
class PublishServiceTest extends SyncTestSupport {

    static final int ORIGIN = 8092;

    @GrpcClient("publish")
    PublishServiceGrpc.PublishServiceBlockingStub publishes;

    @Inject
    BlobStore store;

    final HttpClient http = HttpClient.newHttpClient();

    PublishServiceGrpc.PublishServiceBlockingStub by(String user) {
        return TestUsers.as(publishes, user);
    }

    /** A blob in storage, referenced by the document; its sha256. */
    byte[] blob(UUID doc, String content, String type) {
        byte[] bytes = content.getBytes(StandardCharsets.UTF_8);
        byte[] sha = sha256(bytes);
        String hex = HexFormat.of().formatHex(sha);
        store.put(BlobStore.key(hex), bytes, type).await().atMost(WAIT);
        exec("INSERT INTO blob (sha256, size_bytes, media_type, storage_key) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING",
                hex, (long) bytes.length, type, BlobStore.key(hex));
        exec("INSERT INTO document_blob (document_id, sha256) VALUES (?, ?) ON CONFLICT DO NOTHING", doc, hex);
        return sha;
    }

    static byte[] sha256(byte[] bytes) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(bytes);
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    static PublishFile file(String path, byte[] sha, String type) {
        return PublishFile.newBuilder().setPath(path).setSha256(ByteString.copyFrom(sha)).setMediaType(type).build();
    }

    CreatePublishRequest.Builder request(UUID doc, PublishFile... files) {
        return CreatePublishRequest.newBuilder().setPublishId(uuid7().toString()).setDocumentId(doc.toString())
                .setServerSeq(3).setSettingName("Default").setManifest(PublishManifest.newBuilder().addAllFiles(List.of(files)));
    }

    Publish create(String user, CreatePublishRequest.Builder request) {
        return by(user).createPublish(request.build()).getPublish();
    }

    HttpResponse<String> get(String path, String... headers) throws Exception {
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create("http://localhost:" + ORIGIN + path));
        if (headers.length > 0) {
            request.headers(headers);
        }
        return http.send(request.build(), HttpResponse.BodyHandlers.ofString());
    }

    HttpResponse<String> method(String method, String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create("http://localhost:" + ORIGIN + path))
                .method(method, HttpRequest.BodyPublishers.noBody()).build(), HttpResponse.BodyHandlers.ofString());
    }

    static void assertSafeHeaders(HttpResponse<?> response) {
        assertThat(response.headers().firstValue("Content-Security-Policy")).contains(PubOrigin.CSP);
        assertThat(response.headers().firstValue("X-Content-Type-Options")).contains("nosniff");
        assertThat(response.headers().firstValue("Referrer-Policy")).contains("no-referrer");
        assertThat(response.headers().firstValue("Set-Cookie")).isEmpty();
    }

    // ---------------------------------------------------------------------------- the service

    @Test
    void anyoneWithTheLinkIsServedWithoutSigningIn() throws Exception {
        UUID doc = document(ALICE);
        share(doc, bob, "editor");
        share(doc, carol, "viewer");
        byte[] index = blob(doc, "<html>hello " + doc + "</html>", "text/html");
        byte[] page = blob(doc, "<svg/>" + doc, "image/svg+xml");
        Subscription carols = subscribe(CAROL, null, doc, replicaId(), 0);
        carols.next(FrameCase.PRESENCE);

        Publish made = create(BOB, request(doc, file("index.html", index, "text/html; charset=utf-8"),
                file("pages/page 1.svg", page, "image/svg+xml")).setAccess(PublishAccess.PUBLISH_ACCESS_ANYONE_WITH_LINK));
        assertThat(made.getCurrent()).isTrue();
        assertThat(made.getUrl()).isEqualTo("https://pub.wiretuner.app/d/" + doc + "/");
        assertThat(made.getFileCount()).isEqualTo(2);
        assertThat(made.getPublishedByAccountId()).isEqualTo(bob.toString());
        DocumentEvent changed = carols.next(FrameCase.EVENT).getEvent();
        while (!changed.hasPublishesChanged()) {
            changed = carols.next(FrameCase.EVENT).getEvent();
        }
        assertThat(changed.getPublishesChanged().getPublishId()).isEqualTo(made.getPublishId());
        carols.cancel();

        HttpResponse<String> root = get("/d/" + doc + "/");
        assertThat(root.statusCode()).isEqualTo(200);
        assertThat(root.body()).isEqualTo("<html>hello " + doc + "</html>");
        assertThat(root.headers().firstValue("Content-Type")).contains("text/html; charset=utf-8");
        assertThat(root.headers().firstValue("Cache-Control")).contains(PubOrigin.CACHE);
        String etag = "\"" + HexFormat.of().formatHex(index) + "\"";
        assertThat(root.headers().firstValue("ETag")).contains(etag);
        assertSafeHeaders(root);
        assertThat(get("/d/" + doc + "/pages/page%201.svg").body()).isEqualTo("<svg/>" + doc);
        assertThat(get("/d/" + doc + "/", "If-None-Match", etag).statusCode()).isEqualTo(304);
        HttpResponse<String> head = method("HEAD", "/d/" + doc + "/index.html");
        assertThat(head.statusCode()).isEqualTo(200);
        assertThat(head.headers().firstValue("Content-Length")).contains(Integer.toString(root.body().length()));
        HttpResponse<String> bare = get("/d/" + doc);
        assertThat(bare.statusCode()).isEqualTo(301);
        assertThat(bare.headers().firstValue("Location")).contains("/d/" + doc + "/");
        assertSafeHeaders(bare);

        assertThat(get("/d/" + doc + "/%2e%2e/secret").statusCode()).isEqualTo(400);
        assertThat(get("/d/" + doc + "/pages//x").statusCode()).isEqualTo(400);
        assertThat(get("/d/" + doc + "/missing.png").statusCode()).isEqualTo(404);
        assertThat(get("/d/" + UUID.randomUUID() + "/").statusCode()).isEqualTo(404);
        assertThat(get("/elsewhere").statusCode()).isEqualTo(404);
        HttpResponse<String> post = method("POST", "/d/" + doc + "/");
        assertThat(post.statusCode()).isEqualTo(405);
        assertSafeHeaders(post);

        // Members only is not served until its sign-in hand-off exists; unpublished and trashed are gone.
        by(BOB).setPublishAccess(SetPublishAccessRequest.newBuilder().setPublishId(made.getPublishId())
                .setAccess(PublishAccess.PUBLISH_ACCESS_MEMBERS).build());
        assertThat(get("/d/" + doc + "/").statusCode()).isEqualTo(403);
        Publish open = by(BOB).setPublishAccess(SetPublishAccessRequest.newBuilder().setPublishId(made.getPublishId())
                .setAccess(PublishAccess.PUBLISH_ACCESS_ANYONE_WITH_LINK).build()).getPublish();
        assertThat(open.getAccess()).isEqualTo(PublishAccess.PUBLISH_ACCESS_ANYONE_WITH_LINK);
        exec("UPDATE document SET trashed_at = now() WHERE id = ?", doc);
        assertThat(get("/d/" + doc + "/").statusCode()).isEqualTo(404);
        exec("UPDATE document SET trashed_at = NULL WHERE id = ?", doc);
        by(BOB).deletePublish(DeletePublishRequest.newBuilder().setPublishId(made.getPublishId()).build());
        assertThat(get("/d/" + doc + "/").statusCode()).isEqualTo(404);
        by(BOB).deletePublish(DeletePublishRequest.newBuilder().setPublishId(made.getPublishId()).build());
        assertFails(() -> by(BOB).getPublish(GetPublishRequest.newBuilder().setPublishId(made.getPublishId()).build()),
                Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
    }

    @Test
    void theManifestMustNameTheDocumentsBlobsWithinTheCap() {
        UUID doc = document(ALICE);
        UUID other = document(ALICE);
        byte[] mine = blob(doc, "mine " + doc, "text/plain");
        byte[] theirs = blob(other, "theirs " + other, "text/plain");
        byte[] nowhere = sha256(("nowhere " + doc).getBytes(StandardCharsets.UTF_8));
        assertFails(() -> create(ALICE, request(doc, file("index.html", nowhere, "text/html"))), Status.Code.NOT_FOUND,
                ErrorReasons.BLOB_NOT_FOUND);
        assertFails(() -> create(ALICE, request(doc, file("index.html", theirs, "text/html"))), Status.Code.NOT_FOUND,
                ErrorReasons.BLOB_NOT_FOUND);
        String huge = "cd".repeat(32);
        exec("INSERT INTO blob (sha256, size_bytes, media_type, storage_key) VALUES (?, ?, 'video/mp4', 'k')"
                + " ON CONFLICT DO NOTHING", huge, 600L * 1024 * 1024);
        exec("INSERT INTO document_blob (document_id, sha256) VALUES (?, ?)", doc, huge);
        assertFails(() -> create(ALICE, request(doc, file("index.html", mine, "text/html"),
                file("movie.mp4", HexFormat.of().parseHex(huge), "video/mp4"))), Status.Code.INVALID_ARGUMENT,
                ErrorReasons.VALIDATION_FAILED);
        assertFails(() -> create(ALICE, request(doc, file("../index.html", mine, "text/html"))),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        assertFails(() -> create(ALICE, request(doc, file("a.html", mine, "text/html"), file("a.html", mine, "text/html"))),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        share(doc, carol, "viewer");
        assertFails(() -> create(CAROL, request(doc, file("index.html", mine, "text/html"))),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
    }

    @Test
    void publishingIsIdempotentTheNewestIsCurrentAndAccessFollowsTheLinkPolicy() {
        UUID doc = document(ALICE);
        byte[] index = blob(doc, "index " + doc, "text/html");
        CreatePublishRequest.Builder first = request(doc, file("index.html", index, "text/html"));
        Publish made = create(ALICE, first);
        assertThat(made.getAccess()).isEqualTo(PublishAccess.PUBLISH_ACCESS_MEMBERS);
        assertThat(create(ALICE, first)).isEqualTo(made);
        UUID other = document(ALICE);
        assertFails(() -> create(ALICE, first.clone().setDocumentId(other.toString())), Status.Code.INVALID_ARGUMENT,
                ErrorReasons.VALIDATION_FAILED);

        exec("INSERT INTO share_link (id, document_id, token_hash, role, created_by) VALUES (?, ?, ?, 'viewer', ?)",
                UUID.randomUUID(), doc, "%064x".formatted(Math.abs(doc.getLeastSignificantBits())), alice);
        Publish second = create(ALICE, request(doc, file("index.html", index, "text/html")));
        assertThat(second.getAccess()).isEqualTo(PublishAccess.PUBLISH_ACCESS_ANYONE_WITH_LINK);
        ListPublishesResponse page = by(ALICE).listPublishes(ListPublishesRequest.newBuilder().setDocumentId(doc.toString())
                .setPageSize(1).build());
        assertThat(page.getPublishes(0).getPublishId()).isEqualTo(second.getPublishId());
        assertThat(page.getPublishes(0).getCurrent()).isTrue();
        ListPublishesResponse rest = by(ALICE).listPublishes(ListPublishesRequest.newBuilder()
                .setDocumentId(doc.toString()).setCursor(page.getNextCursor()).build());
        assertThat(rest.getPublishesList()).extracting(Publish::getPublishId).containsExactly(made.getPublishId());
        assertThat(rest.getPublishes(0).getCurrent()).isFalse();
        assertThat(rest.getNextCursor()).isEmpty();

        GetPublishResponse got = by(ALICE).getPublish(GetPublishRequest.newBuilder().setPublishId(second.getPublishId())
                .build());
        assertThat(got.getManifest().getFiles(0).getPath()).isEqualTo("index.html");
        assertThat(got.getManifest().getFiles(0).getSha256().toByteArray()).isEqualTo(index);
        assertThat(got.getManifest().getFiles(0).getSize()).isEqualTo(("index " + doc).length());
        exec("UPDATE publish SET published_by = NULL WHERE id = ?", UUID.fromString(second.getPublishId()));
        assertThat(by(ALICE).getPublish(GetPublishRequest.newBuilder().setPublishId(second.getPublishId()).build())
                .getPublish().getPublishedByAccountId()).isEmpty();
    }

    @Test
    void thirtyPublishesAnHourPerDocument() {
        UUID doc = document(ALICE);
        byte[] index = blob(doc, "rate " + doc, "text/html");
        for (int i = 0; i < 30; i++) {
            create(ALICE, request(doc, file("index.html", index, "text/html")));
        }
        assertFails(() -> create(ALICE, request(doc, file("index.html", index, "text/html"))),
                Status.Code.RESOURCE_EXHAUSTED, ErrorReasons.RATE_LIMITED);
    }

    @Test
    void aBlobMissingFromStorageIsAServerError() throws Exception {
        UUID doc = document(ALICE);
        String hex = "ef".repeat(32);
        exec("INSERT INTO blob (sha256, size_bytes, media_type, storage_key) VALUES (?, 3, 'text/html', ?)"
                + " ON CONFLICT DO NOTHING", hex, "blobs/ef/nothing-here");
        exec("INSERT INTO document_blob (document_id, sha256) VALUES (?, ?)", doc, hex);
        create(ALICE, request(doc, file("index.html", HexFormat.of().parseHex(hex), "text/html"))
                .setAccess(PublishAccess.PUBLISH_ACCESS_ANYONE_WITH_LINK));
        assertThat(get("/d/" + doc + "/").statusCode()).isEqualTo(500);
    }

    // ---------------------------------------------------------------------------------- load

    /** Every build: ten viewers at once each read the whole 200-file bundle, and every file is its own bytes. */
    @Test
    void aTwoHundredFileBundleServesConcurrentViewersTheirFiles() throws Exception {
        UUID doc = bundle();
        List<Long> latencies = view(doc, 10);
        assertThat(latencies).hasSize(10 * PAGES);
    }

    /** The perf run: 100 viewers, 200 requests each; the p95 is within 200 ms (WEB-012). */
    @PerfTest
    void aTwoHundredFileBundleServesAHundredViewersQuickly() throws Exception {
        UUID doc = bundle();
        List<Long> sorted = new ArrayList<>(view(doc, 100));
        Collections.sort(sorted);
        long p95 = sorted.get((int) (sorted.size() * 0.95));
        PerfReport.measured("Published 200-file bundle, 100 viewers, p95 (WEB-012)",
                String.format(Locale.ROOT, "%.1f ms over %d requests", p95 / 1e6, sorted.size()), "< 200 ms",
                p95 < P95_BUDGET_NANOS);
        assertThat(p95).isLessThan(P95_BUDGET_NANOS);
    }

    static final int PAGES = 200;
    static final long P95_BUDGET_NANOS = 200_000_000L;

    /** A document published to anyone with the link with {@link #PAGES} SVG files, one read already. */
    private UUID bundle() throws Exception {
        UUID doc = document(ALICE);
        List<PublishFile> files = new ArrayList<>();
        for (int i = 0; i < PAGES; i++) {
            files.add(file("pages/page-" + i + ".svg", blob(doc, page(doc, i), "image/svg+xml"), "image/svg+xml"));
        }
        create(ALICE, request(doc).setAccess(PublishAccess.PUBLISH_ACCESS_ANYONE_WITH_LINK)
                .setManifest(PublishManifest.newBuilder().addAllFiles(files)));
        get("/d/" + doc + "/pages/page-0.svg");
        return doc;
    }

    private static String page(UUID doc, int i) {
        return "<svg>" + i + " " + doc + "</svg>";
    }

    /**
     * {@code viewers} concurrent viewers each read every page once, starting at their own; each response is
     * the page's bytes. The result is every request's latency.
     */
    private List<Long> view(UUID doc, int viewers) throws Exception {
        List<Long> latencies = Collections.synchronizedList(new ArrayList<>());
        try (ExecutorService pool = Executors.newFixedThreadPool(viewers)) {
            List<Future<?>> running = new ArrayList<>();
            for (int v = 0; v < viewers; v++) {
                int viewer = v;
                running.add(pool.submit(() -> {
                    for (int i = 0; i < PAGES; i++) {
                        int page = (i + viewer) % PAGES;
                        long started = System.nanoTime();
                        HttpResponse<String> response = get("/d/" + doc + "/pages/page-" + page + ".svg");
                        latencies.add(System.nanoTime() - started);
                        assertThat(response.statusCode()).isEqualTo(200);
                        assertThat(response.body()).isEqualTo(page(doc, page));
                    }
                    return null;
                }));
            }
            for (Future<?> future : running) {
                future.get();
            }
        }
        return latencies;
    }
}
