package com.villagecompute.wiretuner.api.data;

import java.net.URI;
import java.time.DateTimeException;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

import org.jboss.logging.Logger;

import com.google.protobuf.ByteString;
import com.google.protobuf.Message;
import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.Redaction;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.BlobRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentBlobRepository;
import com.villagecompute.wiretuner.data.v1.DeleteAllowedHostRequest;
import com.villagecompute.wiretuner.data.v1.DeleteAllowedHostResponse;
import com.villagecompute.wiretuner.data.v1.DeleteCredentialRequest;
import com.villagecompute.wiretuner.data.v1.DeleteCredentialResponse;
import com.villagecompute.wiretuner.data.v1.FetchAssetRequest;
import com.villagecompute.wiretuner.data.v1.FetchAssetResponse;
import com.villagecompute.wiretuner.data.v1.FetchRequest;
import com.villagecompute.wiretuner.data.v1.FetchResponse;
import com.villagecompute.wiretuner.data.v1.ListAllowedHostsRequest;
import com.villagecompute.wiretuner.data.v1.ListAllowedHostsResponse;
import com.villagecompute.wiretuner.data.v1.ListCredentialsRequest;
import com.villagecompute.wiretuner.data.v1.ListCredentialsResponse;
import com.villagecompute.wiretuner.data.v1.ListFetchAuditRequest;
import com.villagecompute.wiretuner.data.v1.ListFetchAuditResponse;
import com.villagecompute.wiretuner.data.v1.MutinyDataSourceServiceGrpc;
import com.villagecompute.wiretuner.data.v1.ProxyRequest;
import com.villagecompute.wiretuner.data.v1.ProxyResponse;
import com.villagecompute.wiretuner.data.v1.PutAllowedHostRequest;
import com.villagecompute.wiretuner.data.v1.PutAllowedHostResponse;
import com.villagecompute.wiretuner.data.v1.PutCredentialRequest;
import com.villagecompute.wiretuner.data.v1.PutCredentialResponse;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.data.v1.DataSourceService} (DATA-002, DATA-005..009; data-merge.adoc, Server state
 * and the data service): credentials, permitted hosts, the fetch proxy and its audit trail. Requests
 * are logged at DEBUG through {@link Redaction}, so a secret never reaches a log line.
 */
@GrpcService
public class DataSourceGrpcService extends MutinyDataSourceServiceGrpc.DataSourceServiceImplBase {

    private static final Logger LOG = Logger.getLogger(DataSourceGrpcService.class);

    static final long ASSET_CAP = 200L * 1024 * 1024;
    static final Duration ASSET_TIMEOUT = Duration.ofSeconds(120);
    static final long PROXY_CAP = 16L * 1024 * 1024;
    static final int DEFAULT_TIMEOUT_S = 30;
    static final String DEFAULT_MEDIA_TYPE = "application/octet-stream";

    @Inject
    Scopes scopes;

    @Inject
    MasterKeys keys;

    @Inject
    CredentialRepository credentials;

    @Inject
    AllowedHostRepository hosts;

    @Inject
    FetchAuditRepository audit;

    @Inject
    Outbound outbound;

    @Inject
    Fetches fetches;

    @Inject
    BlobStore blobStore;

    @Inject
    BlobRepository blobs;

    @Inject
    DocumentBlobRepository documentBlobs;

    // ------------------------------------------------------------------------------ credentials

    @Override
    public Uni<PutCredentialResponse> putCredential(PutCredentialRequest request) {
        log("PutCredential", request);
        return tx(() -> scopes.manage(request.getScope())).chain(caller -> {
            Envelope.Sealed sealed = keys.envelope().seal(Secret.of(request).encode(), caller.scope().aad(request.getName()));
            return credentials.put(caller.scope(), request.getName(), Secret.kindName(request.getKind()),
                    HostNames.normalize(request.getHost()), sealed, caller.accountId());
        }).map(row -> PutCredentialResponse.newBuilder().setCredential(DataMessages.credential(row)).build());
    }

    @Override
    public Uni<DeleteCredentialResponse> deleteCredential(DeleteCredentialRequest request) {
        log("DeleteCredential", request);
        return tx(() -> scopes.manage(request.getScope()))
                .chain(caller -> credentials.delete(caller.scope(), request.getName()))
                .map(deleted -> DeleteCredentialResponse.newBuilder().setDeleted(deleted).build());
    }

    @Override
    public Uni<ListCredentialsResponse> listCredentials(ListCredentialsRequest request) {
        log("ListCredentials", request);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return Uni.createFrom().deferred(() -> {
            String after = request.getCursor().isEmpty() ? null : Cursors.decode(request.getCursor(), 1)[0];
            return tx(request.hasScope() ? () -> scopes.read(request.getScope())
                    : () -> scopes.document(UUID.fromString(request.getDocumentId())))
                    .chain(caller -> credentials.list(caller.scope(), after, pageSize + 1));
        }).map(rows -> {
            ListCredentialsResponse.Builder response = ListCredentialsResponse.newBuilder();
            rows.stream().limit(pageSize).forEach(row -> response.addCredentials(DataMessages.credential(row)));
            if (rows.size() > pageSize) {
                response.setNextCursor(Cursors.encode(rows.get(pageSize - 1).name()));
            }
            return response.build();
        });
    }

    // ------------------------------------------------------------------------------------ hosts

    @Override
    public Uni<ListAllowedHostsResponse> listAllowedHosts(ListAllowedHostsRequest request) {
        log("ListAllowedHosts", request);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return Uni.createFrom().deferred(() -> {
            String after = request.getCursor().isEmpty() ? null : Cursors.decode(request.getCursor(), 1)[0];
            return tx(request.hasScope() ? () -> scopes.read(request.getScope())
                    : () -> scopes.document(UUID.fromString(request.getDocumentId())))
                    .chain(caller -> hosts.list(caller.scope(), after, pageSize + 1));
        }).map(rows -> {
            ListAllowedHostsResponse.Builder response = ListAllowedHostsResponse.newBuilder();
            rows.stream().limit(pageSize).forEach(row -> response.addHosts(DataMessages.host(row)));
            if (rows.size() > pageSize) {
                response.setNextCursor(Cursors.encode(rows.get(pageSize - 1).host()));
            }
            return response.build();
        });
    }

    @Override
    public Uni<PutAllowedHostResponse> putAllowedHost(PutAllowedHostRequest request) {
        log("PutAllowedHost", request);
        return tx(() -> scopes.manage(request.getScope()))
                .chain(caller -> hosts.put(caller.scope(), HostNames.normalize(request.getHost()), caller.accountId()))
                .map(entry -> PutAllowedHostResponse.newBuilder().setHost(DataMessages.host(entry)).build());
    }

    @Override
    public Uni<DeleteAllowedHostResponse> deleteAllowedHost(DeleteAllowedHostRequest request) {
        log("DeleteAllowedHost", request);
        return tx(() -> scopes.manage(request.getScope()))
                .chain(caller -> hosts.delete(caller.scope(), HostNames.normalize(request.getHost())))
                .map(deleted -> DeleteAllowedHostResponse.newBuilder().setDeleted(deleted).build());
    }

    // ------------------------------------------------------------------------------------ fetch

    @Override
    public Multi<FetchResponse> fetch(FetchRequest request) {
        log("Fetch", request);
        return fetches.fetch(request);
    }

    @Override
    public Uni<FetchAssetResponse> fetchAsset(FetchAssetRequest request) {
        log("FetchAsset", request);
        return Uni.createFrom().deferred(() -> {
            URI url = HostNames.parse(request.getUrl(), "url");
            UUID documentId = UUID.fromString(request.getDocumentId());
            return outbound.start(documentId, "asset").chain(run -> outbound.audited(run,
                    outbound.credential(run, request.getCredentialName())
                            .chain(() -> outbound.send(run, "GET", url, Map.of("accept", "*/*"), null, ASSET_TIMEOUT, ASSET_CAP))
                            .chain(reply -> store(documentId, reply))));
        });
    }

    /** Stores a fetched asset as a blob the document references (the bytes once per hash). */
    private Uni<FetchAssetResponse> store(UUID documentId, Egress.Reply reply) {
        if (reply.status() / 100 != 2) {
            return Uni.createFrom().failure(StatusExceptions.upstreamError(reply.status()));
        }
        byte[] body = reply.body();
        String sha = HexFormat.of().formatHex(Envelope.crypto("asset hash",
                () -> java.security.MessageDigest.getInstance("SHA-256").digest(body)));
        String mediaType = mediaType(reply.header("content-type"));
        String key = BlobStore.key(sha);
        return tx(() -> blobs.findById(sha))
                .chain(existing -> existing != null ? Uni.createFrom().voidItem() : blobStore.put(key, body, mediaType))
                .chain(() -> tx(() -> blobs.insertIfAbsent(sha, body.length, mediaType, key, "content")
                        .call(() -> documentBlobs.reference(documentId, sha))))
                .map(blob -> FetchAssetResponse.newBuilder()
                        .setBlobSha256(ByteString.copyFrom(HexFormat.of().parseHex(sha)))
                        .setMediaType(blob.mediaType)
                        .setSize(body.length)
                        .build());
    }

    /** A Content-Type without its parameters, lower case; octet-stream when there is none. */
    static String mediaType(String contentType) {
        return contentType == null ? DEFAULT_MEDIA_TYPE : contentType.split(";", 2)[0].strip().toLowerCase(Locale.ROOT);
    }

    @Override
    public Uni<ProxyResponse> proxy(ProxyRequest request) {
        log("Proxy", request);
        return Uni.createFrom().deferred(() -> {
            URI url = HostNames.parse(request.getUrl(), "url");
            UUID documentId = UUID.fromString(request.getDocumentId());
            Duration timeout = Duration.ofSeconds(request.getTimeoutS() == 0 ? DEFAULT_TIMEOUT_S : request.getTimeoutS());
            byte[] body = request.getBody().isEmpty() ? null : request.getBody().toByteArray();
            return outbound.start(documentId, "script").chain(run -> outbound.audited(run,
                    outbound.credential(run, request.getCredentialName())
                            .chain(() -> outbound.send(run, request.getMethod(), url,
                                    RequestHeaders.check(request.getHeadersMap(), run.credentialHeader(), "headers"), body, timeout,
                                    PROXY_CAP))
                            .map(DataSourceGrpcService::proxyResponse)));
        });
    }

    /** The upstream answer for a script: headers lower-cased and joined, cookies and connection headers dropped. */
    static ProxyResponse proxyResponse(Egress.Reply reply) {
        Map<String, String> headers = new LinkedHashMap<>();
        for (Map.Entry<String, String> header : reply.headers()) {
            String name = header.getKey();
            if (!name.startsWith("set-cookie") && !RequestHeaders.CONNECTION.contains(name)) {
                headers.merge(name, header.getValue(), (a, b) -> a + ", " + b);
            }
        }
        return ProxyResponse.newBuilder().setStatus(reply.status()).putAllHeaders(headers)
                .setBody(ByteString.copyFrom(reply.body())).build();
    }

    // ------------------------------------------------------------------------------------ audit

    @Override
    public Uni<ListFetchAuditResponse> listFetchAudit(ListFetchAuditRequest request) {
        log("ListFetchAudit", request);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return Uni.createFrom().deferred(() -> {
            Instant beforeAt = null;
            UUID beforeId = null;
            if (!request.getCursor().isEmpty()) {
                String[] parts = Cursors.decode(request.getCursor(), 2);
                beforeAt = instant(parts[0]);
                beforeId = Cursors.uuid(parts[1]);
            }
            Instant at = beforeAt;
            UUID id = beforeId;
            return tx(() -> scopes.manage(request.getScope())).chain(caller -> audit.list(new FetchAuditRepository.Query(
                    caller.scope(), optionalId(request.getDocumentId()),
                    request.getHost().isEmpty() ? null : HostNames.normalize(request.getHost()),
                    optionalId(request.getAccountId()), at, id, pageSize + 1)));
        }).map(rows -> {
            ListFetchAuditResponse.Builder response = ListFetchAuditResponse.newBuilder();
            rows.stream().limit(pageSize).forEach(row -> response.addEntries(DataMessages.audit(row)));
            if (rows.size() > pageSize) {
                FetchAuditRepository.Entry last = rows.get(pageSize - 1);
                response.setNextCursor(Cursors.encode(last.startedAt().toString(), last.id().toString()));
            }
            return response.build();
        });
    }

    static Instant instant(String part) {
        try {
            return Instant.parse(part);
        } catch (DateTimeException e) {
            throw Cursors.invalid();
        }
    }

    static UUID optionalId(String id) {
        return id.isEmpty() ? null : UUID.fromString(id);
    }

    // ---------------------------------------------------------------------------------- helpers

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }

    private static void log(String rpc, Message request) {
        LOG.debugf("%s %s", rpc, new Object() {
            @Override
            public String toString() {
                return Redaction.print(request);
            }
        });
    }
}
