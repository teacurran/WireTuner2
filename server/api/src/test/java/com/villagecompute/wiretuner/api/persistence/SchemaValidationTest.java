package com.villagecompute.wiretuner.api.persistence;

import static com.villagecompute.wiretuner.api.Reactive.tx;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.QuarkusTestProfile;
import io.quarkus.test.junit.TestProfile;

import jakarta.inject.Inject;

/**
 * The entity mappings agree with the Flyway migrations: the application boots with Hibernate's
 * schema validation on ({@code quarkus.hibernate-orm.schema-management.strategy=validate}), which
 * fails the start on a missing table or column or a column of another type -- the drift compose
 * showed on {@code access_request.granted_role} -- so a migration and its entity cannot diverge
 * unnoticed.
 */
@QuarkusTest
@TestProfile(SchemaValidationTest.Validate.class)
class SchemaValidationTest {

    /** Validation on at start. */
    public static class Validate implements QuarkusTestProfile {
        @Override
        public Map<String, String> getConfigOverrides() {
            return Map.of("quarkus.hibernate-orm.schema-management.strategy", "validate");
        }
    }

    @Inject
    AccessRequestRepository requests;

    @Test
    void entitiesMatchTheMigrations() {
        assertThat(tx(() -> requests.findById(UUID.randomUUID()))).isNull();
    }
}
