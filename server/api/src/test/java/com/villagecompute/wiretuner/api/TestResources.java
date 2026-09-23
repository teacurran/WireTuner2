package com.villagecompute.wiretuner.api;

import io.quarkus.test.common.QuarkusTestResource;

/**
 * Registers the test resources every {@code @QuarkusTest} shares (one application, one set of
 * containers): MinIO for blobs and the DNS stub for workspace domains.
 */
@QuarkusTestResource(value = MinioResource.class, restrictToAnnotatedClass = false)
@QuarkusTestResource(value = DnsStub.class, restrictToAnnotatedClass = false)
public final class TestResources {

    private TestResources() {
    }
}
