package com.villagecompute.wiretuner.api;

import java.net.URI;
import java.util.Map;

import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;

import io.quarkus.test.common.QuarkusTestResourceLifecycleManager;

import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.http.nio.netty.NettyNioAsyncHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3AsyncClient;

/**
 * MinIO for every {@code @QuarkusTest} (docs/spec/testing.adoc, Server: Testcontainers for minio):
 * the compose image, one bucket created up front as compose's minio-init does, and
 * {@code wt.storage.endpoint} pointed at it.
 */
public class MinioResource implements QuarkusTestResourceLifecycleManager {

    static final String IMAGE = "quay.io/minio/minio:latest";
    static final String BUCKET = "wiretuner";

    private GenericContainer<?> minio;

    @Override
    @SuppressWarnings("resource")
    public Map<String, String> start() {
        minio = new GenericContainer<>(IMAGE)
                .withCommand("server", "/data")
                .withEnv("MINIO_ROOT_USER", "minioadmin")
                .withEnv("MINIO_ROOT_PASSWORD", "minioadmin")
                .withExposedPorts(9000)
                .waitingFor(Wait.forHttp("/minio/health/live").forPort(9000));
        minio.start();
        String endpoint = "http://" + minio.getHost() + ":" + minio.getMappedPort(9000);
        try (S3AsyncClient s3 = S3AsyncClient.builder()
                .endpointOverride(URI.create(endpoint))
                .region(Region.US_EAST_1)
                .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create("minioadmin", "minioadmin")))
                .forcePathStyle(true)
                .httpClient(NettyNioAsyncHttpClient.builder().build())
                .build()) {
            s3.createBucket(b -> b.bucket(BUCKET)).join();
        }
        return Map.of("wt.storage.endpoint", endpoint, "wt.storage.bucket", BUCKET);
    }

    @Override
    public void stop() {
        if (minio != null) {
            minio.stop();
        }
    }
}
