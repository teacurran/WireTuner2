package com.villagecompute.wiretuner.api;

import io.quarkus.test.common.QuarkusTestResource;

/**
 * Registers the test resources every {@code @QuarkusTest} shares (one application, one set of
 * containers): MinIO for blobs, the DNS stub for workspace domains and upstream hosts, and the
 * HTTPS stub that plays the data service's upstream APIs.
 */
@QuarkusTestResource(value = MinioResource.class, restrictToAnnotatedClass = false)
@QuarkusTestResource(value = DnsStub.class, restrictToAnnotatedClass = false)
@QuarkusTestResource(value = EgressStub.class, restrictToAnnotatedClass = false)
public final class TestResources {

    private TestResources() {
    }
}
