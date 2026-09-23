package com.villagecompute.wiretuner.api.blob;

import java.net.URI;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.function.Supplier;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.reactivestreams.FlowAdapters;

import com.villagecompute.wiretuner.api.grpc.CallerContext;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;

import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.async.AsyncRequestBody;
import software.amazon.awssdk.core.async.AsyncResponseTransformer;
import software.amazon.awssdk.core.checksums.RequestChecksumCalculation;
import software.amazon.awssdk.core.checksums.ResponseChecksumValidation;
import software.amazon.awssdk.http.nio.netty.NettyNioAsyncHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3AsyncClient;
import software.amazon.awssdk.services.s3.model.CompletedPart;

/**
 * Object storage for blobs (docs/spec/stack.adoc: R2 in production, MinIO locally) through the AWS
 * SDK v2 {@link S3AsyncClient}, configured as dissipate-server's R2 store is: path-style addressing,
 * checksums only when required, the Netty client. Blobs are content-addressed, so a key is written
 * once and never changes.
 *
 * <p>Every result is re-emitted on the caller's Vert.x context: the SDK completes on its own Netty
 * loop, and the reactive Hibernate session that the caller chains onto belongs to the context.
 */
@ApplicationScoped
public class BlobStore {

    @ConfigProperty(name = "wt.storage.endpoint")
    URI endpoint;

    @ConfigProperty(name = "wt.storage.region")
    String region;

    @ConfigProperty(name = "wt.storage.bucket")
    String bucket;

    @ConfigProperty(name = "wt.storage.access-key")
    String accessKey;

    @ConfigProperty(name = "wt.storage.secret-key")
    String secretKey;

    @ConfigProperty(name = "wt.storage.path-style-access")
    boolean pathStyle;

    S3AsyncClient s3;

    @PostConstruct
    void start() {
        s3 = S3AsyncClient.builder()
                .endpointOverride(endpoint)
                .region(Region.of(region))
                .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create(accessKey, secretKey)))
                .forcePathStyle(pathStyle)
                .requestChecksumCalculation(RequestChecksumCalculation.WHEN_REQUIRED)
                .responseChecksumValidation(ResponseChecksumValidation.WHEN_REQUIRED)
                .httpClient(NettyNioAsyncHttpClient.builder().build())
                .build();
    }

    @PreDestroy
    void stop() {
        s3.close();
    }

    /** Where a blob lives: fanned out by the first byte of its hash. */
    public static String key(String sha256Hex) {
        return "blobs/" + sha256Hex.substring(0, 2) + "/" + sha256Hex;
    }

    /** Writes a small object in one request. */
    public Uni<Void> put(String key, byte[] bytes, String mediaType) {
        return async(() -> s3.putObject(b -> b.bucket(bucket).key(key).contentType(mediaType).contentLength((long) bytes.length),
                AsyncRequestBody.fromBytes(bytes))).replaceWithVoid();
    }

    /** Starts a multipart upload; returns its id. */
    public Uni<String> startMultipart(String key, String mediaType) {
        return async(() -> s3.createMultipartUpload(b -> b.bucket(bucket).key(key).contentType(mediaType)))
                .map(r -> r.uploadId());
    }

    /** Uploads part {@code number} (1-based; at least 5 MiB except the last). */
    public Uni<CompletedPart> uploadPart(String key, String uploadId, int number, byte[] bytes) {
        return async(() -> s3.uploadPart(b -> b.bucket(bucket).key(key).uploadId(uploadId).partNumber(number)
                .contentLength((long) bytes.length), AsyncRequestBody.fromBytes(bytes)))
                .map(r -> CompletedPart.builder().partNumber(number).eTag(r.eTag()).build());
    }

    /** Makes the object visible under its key. */
    public Uni<Void> completeMultipart(String key, String uploadId, List<CompletedPart> parts) {
        return async(() -> s3.completeMultipartUpload(b -> b.bucket(bucket).key(key).uploadId(uploadId)
                .multipartUpload(m -> m.parts(parts)))).replaceWithVoid();
    }

    /** Discards an unfinished multipart upload; nothing becomes visible. */
    public Uni<Void> abortMultipart(String key, String uploadId) {
        return async(() -> s3.abortMultipartUpload(b -> b.bucket(bucket).key(key).uploadId(uploadId))).replaceWithVoid();
    }

    /** The object's bytes as the SDK delivers them, on the caller's context. */
    public Multi<ByteBuffer> get(String key) {
        Executor executor = CallerContext.executor();
        return async(() -> s3.getObject(b -> b.bucket(bucket).key(key), AsyncResponseTransformer.toPublisher()))
                .onItem().transformToMulti(publisher -> Multi.createFrom().publisher(FlowAdapters.toFlowPublisher(publisher)))
                .emitOn(executor);
    }

    /** The whole object in memory (snapshots and cold segments, which are bounded). */
    public Uni<byte[]> bytes(String key) {
        return async(() -> s3.getObject(b -> b.bucket(bucket).key(key), AsyncResponseTransformer.toBytes()))
                .map(response -> response.asByteArray());
    }

    /** Deletes the object; deleting a missing key succeeds. */
    public Uni<Void> delete(String key) {
        return async(() -> s3.deleteObject(b -> b.bucket(bucket).key(key))).replaceWithVoid();
    }

    private <T> Uni<T> async(Supplier<CompletableFuture<T>> call) {
        return Uni.createFrom().completionStage(call).emitOn(CallerContext.executor());
    }
}
