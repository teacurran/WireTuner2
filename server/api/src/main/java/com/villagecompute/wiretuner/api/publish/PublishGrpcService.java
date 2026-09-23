package com.villagecompute.wiretuner.api.publish;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.google.protobuf.ByteString;
import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.observability.RateLimiter;
import com.villagecompute.wiretuner.api.sync.DocumentEvents;
import com.villagecompute.wiretuner.publish.v1.CreatePublishRequest;
import com.villagecompute.wiretuner.publish.v1.CreatePublishResponse;
import com.villagecompute.wiretuner.publish.v1.DeletePublishRequest;
import com.villagecompute.wiretuner.publish.v1.DeletePublishResponse;
import com.villagecompute.wiretuner.publish.v1.GetPublishRequest;
import com.villagecompute.wiretuner.publish.v1.GetPublishResponse;
import com.villagecompute.wiretuner.publish.v1.ListPublishesRequest;
import com.villagecompute.wiretuner.publish.v1.ListPublishesResponse;
import com.villagecompute.wiretuner.publish.v1.MutinyPublishServiceGrpc;
import com.villagecompute.wiretuner.publish.v1.Publish;
import com.villagecompute.wiretuner.publish.v1.PublishAccess;
import com.villagecompute.wiretuner.publish.v1.PublishFile;
import com.villagecompute.wiretuner.publish.v1.PublishManifest;
import com.villagecompute.wiretuner.publish.v1.SetPublishAccessRequest;
import com.villagecompute.wiretuner.publish.v1.SetPublishAccessResponse;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.PublishesChanged;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.SqlConnection;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.publish.v1.PublishService} (WEB-012; publish-html.adoc, Server). A publish is a
 * {@code publish} row and its {@code publish_file} rows, each file a blob the document references;
 * creating one makes it the document's current publish, which {@link PubOrigin} serves. Creating,
 * changing access and deleting need editor; reading needs any role. Every change is told to the
 * document's sessions as {@code PublishesChanged} once committed. At most
 * {@code wt.publish.per-hour} (30) publishes per document per hour.
 */
@GrpcService
public class PublishGrpcService extends MutinyPublishServiceGrpc.PublishServiceImplBase {

    /** A bundle's size cap (publish-html.adoc, Server). */
    static final long MAX_BUNDLE_BYTES = 512L * 1024 * 1024;

    static final String MEMBERS = "members";
    static final String ANYONE = "anyone";

    static final String COLUMNS = """
            id, document_id, server_seq, setting_name, published_by,
            cast(extract(epoch FROM published_at) * 1000000 AS bigint), access, is_current, file_count, total_size
            """;

    static final String BY_ID = "SELECT " + COLUMNS + " FROM publish WHERE id = $1";

    static final String PAGE = "SELECT " + COLUMNS
            + " FROM publish WHERE document_id = $1 ORDER BY published_at DESC, id DESC OFFSET $2 LIMIT $3";

    static final String FILES = "SELECT f.path, f.sha256, f.media_type, b.size_bytes FROM publish_file f"
            + " JOIN blob b ON b.sha256 = f.sha256 WHERE f.publish_id = $1 ORDER BY f.path";

    /** The manifest's blobs that the document references, with their sizes. */
    static final String BLOBS = """
            SELECT b.sha256, b.size_bytes FROM blob b
            JOIN document_blob r ON r.sha256 = b.sha256 AND r.document_id = $1
            WHERE b.sha256 = ANY($2)
            """;

    /** The document's link policy: anyone with the link when it has a live share link. */
    static final String LINK_POLICY = """
            SELECT EXISTS (SELECT 1 FROM share_link WHERE document_id = $1 AND revoked_at IS NULL
                           AND (expires_at IS NULL OR expires_at > now()))
            """;

    static final String UNCURRENT = "UPDATE publish SET is_current = false WHERE document_id = $1 AND is_current";

    static final String INSERT = """
            INSERT INTO publish (id, document_id, server_seq, setting_name, published_by, access, is_current,
                                 file_count, total_size)
            VALUES ($1, $2, $3, $4, $5, $6, true, $7, $8)
            """;

    static final String INSERT_FILES = """
            INSERT INTO publish_file (publish_id, path, sha256, media_type)
            SELECT $1, f.path, f.sha256, f.media_type FROM unnest($2::text[], $3::text[], $4::text[]) AS f(path, sha256, media_type)
            """;

    static final String ACCESS = "UPDATE publish SET access = $2 WHERE id = $1";

    static final String DELETE = "DELETE FROM publish WHERE id = $1";

    /** ListPublishes' default page; the proto caps it at 100. */
    static final int PUBLISH_PAGE = 50;

    @ConfigProperty(name = "wt.publish.base-url", defaultValue = "https://pub.wiretuner.app")
    String baseUrl;

    @ConfigProperty(name = "wt.publish.per-hour", defaultValue = "30")
    int perHour;

    @Inject
    RoleGuard guard;

    @Inject
    Pool pool;

    @Inject
    DocumentEvents events;

    @Inject
    RateLimiter limits;

    /** A publish row. */
    record Stored(UUID id, UUID documentId, long serverSeq, String settingName, UUID publishedBy, long publishedAtMicros,
            String access, boolean current, int fileCount, long totalSize) {
    }

    @Override
    public Uni<CreatePublishResponse> createPublish(CreatePublishRequest request) {
        UUID id = UUID.fromString(request.getPublishId());
        UUID documentId = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(documentId, Role.EDITOR).flatMap(grant -> changed(grant.principal().accountId(), id)
                .map(event -> new Acting(grant.principal().accountId(), event))))
                .chain(acting -> pool.withTransaction(connection -> connection.preparedQuery(BY_ID).execute(Tuple.of(id))
                        .chain(rows -> rows.rowCount() > 0 ? existing(row(rows.iterator().next()), documentId)
                                : create(connection, request, id, documentId, acting.account())))
                        .call(created -> created.fresh() ? events.publish(documentId, acting.event())
                                : Uni.createFrom().voidItem()))
                .map(created -> CreatePublishResponse.newBuilder().setPublish(message(created.publish())).build());
    }

    /** A publish after CreatePublish, and whether this call made it. */
    record Created(Stored publish, boolean fresh) {
    }

    /** A retried CreatePublish: the publish made first, if it is this document's. */
    private static Uni<Created> existing(Stored found, UUID documentId) {
        return found.documentId().equals(documentId) ? Uni.createFrom().item(new Created(found, false))
                : Uni.createFrom().failure(StatusExceptions.validationFailed("publish_id names another document's publish",
                        Map.of("publish_id", "already used for another document")));
    }

    private Uni<Created> create(SqlConnection connection, CreatePublishRequest request, UUID id, UUID documentId,
            UUID account) {
        List<PublishFile> files = request.getManifest().getFilesList();
        List<String> hashes = files.stream().map(file -> HexFormat.of().formatHex(file.getSha256().toByteArray())).toList();
        return limits.takeExact(List.of(new RateLimiter.Bucket("rl:p:" + documentId, perHour / 3600.0, perHour)), 1)
                .chain(() -> connection.preparedQuery(BLOBS).execute(Tuple.of(documentId, hashes.toArray(String[]::new))))
                .chain(rows -> {
                    Map<String, Long> sizes = new HashMap<>();
                    rows.forEach(row -> sizes.put(row.getString(0), row.getLong(1)));
                    long total = 0;
                    for (String hash : hashes) {
                        Long size = sizes.get(hash);
                        if (size == null) {
                            return Uni.createFrom().failure(StatusExceptions.blobNotFound());
                        }
                        total += size;
                    }
                    if (total > MAX_BUNDLE_BYTES) {
                        return Uni.createFrom().failure(StatusExceptions.validationFailed("the bundle is " + total
                                + " bytes; the cap is " + MAX_BUNDLE_BYTES, Map.of("manifest", "over 512 MiB")));
                    }
                    long bytes = total;
                    return access(connection, documentId, request.getAccess())
                            .chain(access -> connection.preparedQuery(UNCURRENT).execute(Tuple.of(documentId))
                                    .chain(() -> connection.preparedQuery(INSERT).execute(Tuple.from(new Object[] {id,
                                            documentId, request.getServerSeq(), request.getSettingName(), account, access,
                                            files.size(), bytes})))
                                    .chain(() -> connection.preparedQuery(INSERT_FILES).execute(Tuple.of(id,
                                            files.stream().map(PublishFile::getPath).toArray(String[]::new),
                                            hashes.toArray(String[]::new),
                                            files.stream().map(PublishFile::getMediaType).toArray(String[]::new))))
                                    .chain(() -> connection.preparedQuery(BY_ID).execute(Tuple.of(id)))
                                    .map(created -> new Created(row(created.iterator().next()), true)));
                });
    }

    /** The access asked for, or the document's link policy when none was. */
    private static Uni<String> access(SqlConnection connection, UUID documentId, PublishAccess requested) {
        if (requested != PublishAccess.PUBLISH_ACCESS_UNSPECIFIED) {
            return Uni.createFrom().item(stored(requested));
        }
        return connection.preparedQuery(LINK_POLICY).execute(Tuple.of(documentId))
                .map(rows -> rows.iterator().next().getBoolean(0) ? ANYONE : MEMBERS);
    }

    @Override
    public Uni<GetPublishResponse> getPublish(GetPublishRequest request) {
        UUID id = UUID.fromString(request.getPublishId());
        return find(id).chain(found -> tx(() -> guard.require(found.documentId(), Role.VIEWER))
                .chain(() -> pool.preparedQuery(FILES).execute(Tuple.of(id)))
                .map(rows -> {
                    PublishManifest.Builder manifest = PublishManifest.newBuilder();
                    rows.forEach(row -> manifest.addFiles(PublishFile.newBuilder()
                            .setPath(row.getString(0))
                            .setSha256(ByteString.copyFrom(HexFormat.of().parseHex(row.getString(1))))
                            .setMediaType(row.getString(2))
                            .setSize(row.getLong(3))));
                    return GetPublishResponse.newBuilder().setPublish(message(found)).setManifest(manifest).build();
                }));
    }

    @Override
    public Uni<ListPublishesResponse> listPublishes(ListPublishesRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        int offset = request.getCursor().isEmpty() ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), PUBLISH_PAGE);
        return tx(() -> guard.require(documentId, Role.VIEWER))
                .chain(() -> pool.preparedQuery(PAGE).execute(Tuple.of(documentId, offset, pageSize + 1)))
                .map(rows -> {
                    List<Publish> found = new ArrayList<>();
                    rows.forEach(row -> found.add(message(row(row))));
                    ListPublishesResponse.Builder response = ListPublishesResponse.newBuilder();
                    if (found.size() > pageSize) {
                        response.setNextCursor(Cursors.encode(Integer.toString(offset + pageSize)));
                    }
                    return response.addAllPublishes(found.subList(0, Math.min(found.size(), pageSize))).build();
                });
    }

    @Override
    public Uni<SetPublishAccessResponse> setPublishAccess(SetPublishAccessRequest request) {
        UUID id = UUID.fromString(request.getPublishId());
        return find(id).chain(found -> editing(found)
                .call(() -> pool.preparedQuery(ACCESS).execute(Tuple.of(id, stored(request.getAccess()))))
                .call(event -> events.publish(found.documentId(), event))
                .chain(() -> find(id)))
                .map(updated -> SetPublishAccessResponse.newBuilder().setPublish(message(updated)).build());
    }

    @Override
    public Uni<DeletePublishResponse> deletePublish(DeletePublishRequest request) {
        UUID id = UUID.fromString(request.getPublishId());
        return pool.preparedQuery(BY_ID).execute(Tuple.of(id))
                .chain(rows -> rows.rowCount() == 0 ? Uni.createFrom().voidItem() : editing(row(rows.iterator().next()))
                        .call(() -> pool.preparedQuery(DELETE).execute(Tuple.of(id)))
                        .chain(event -> events.publish(row(rows.iterator().next()).documentId(), event)))
                .replaceWith(DeletePublishResponse.getDefaultInstance());
    }

    /** The publish; {@code NOT_FOUND / DOCUMENT_NOT_FOUND} when there is none. */
    private Uni<Stored> find(UUID id) {
        return pool.preparedQuery(BY_ID).execute(Tuple.of(id)).map(rows -> rows.rowCount() == 0 ? null
                : row(rows.iterator().next())).onItem().ifNull().failWith(StatusExceptions::documentNotFound);
    }

    /** Checks the caller is an editor of the publish's document; the event its change will send. */
    private Uni<DocumentEvent> editing(Stored found) {
        return tx(() -> guard.require(found.documentId(), Role.EDITOR)
                .flatMap(grant -> changed(grant.principal().accountId(), found.id())));
    }

    /** Who acts, and the event their change sends. */
    record Acting(UUID account, DocumentEvent event) {
    }

    private Uni<DocumentEvent> changed(UUID actor, UUID publishId) {
        return events.event(actor, participant -> DocumentEvent.newBuilder().setPublishesChanged(PublishesChanged
                .newBuilder().setPublishId(publishId.toString()).setActor(participant)).build());
    }

    static Stored row(io.vertx.mutiny.sqlclient.Row row) {
        return new Stored(row.getUUID(0), row.getUUID(1), row.getLong(2), row.getString(3), row.getUUID(4), row.getLong(5),
                row.getString(6), row.getBoolean(7), row.getInteger(8), row.getLong(9));
    }

    Publish message(Stored row) {
        long micros = row.publishedAtMicros();
        return Publish.newBuilder()
                .setPublishId(row.id().toString())
                .setDocumentId(row.documentId().toString())
                .setServerSeq(row.serverSeq())
                .setSettingName(row.settingName())
                .setPublishedByAccountId(row.publishedBy() == null ? "" : row.publishedBy().toString())
                .setPublishedAt(Timestamp.newBuilder().setSeconds(Math.floorDiv(micros, 1_000_000L))
                        .setNanos((int) Math.floorMod(micros, 1_000_000L) * 1000))
                .setAccess(ANYONE.equals(row.access()) ? PublishAccess.PUBLISH_ACCESS_ANYONE_WITH_LINK
                        : PublishAccess.PUBLISH_ACCESS_MEMBERS)
                .setUrl(url(row.documentId()))
                .setCurrent(row.current())
                .setFileCount(row.fileCount())
                .setTotalSize(row.totalSize())
                .build();
    }

    /** The document's web link. */
    String url(UUID documentId) {
        return baseUrl + "/d/" + documentId + "/";
    }

    static String stored(PublishAccess access) {
        return access == PublishAccess.PUBLISH_ACCESS_ANYONE_WITH_LINK ? ANYONE : MEMBERS;
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
